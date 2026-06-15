# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_search)

# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  @search_preloads [
    :with_object_more,
    :with_object_peered,
    :with_creator,
    :with_subject,
    :with_media,
    :with_reply_to,
    :quote_tags
  ]

  import Untangle
  use Application
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  use Bonfire.Common.Config

  def start(_, _) do
    :telemetry.attach(
      "bonfire_search_index_init",
      [:settings, :load_config, :stop],
      fn _event, _measurements, _meta, _config ->
        :telemetry.detach("bonfire_search_index_init")
        Bonfire.Search.Indexer.init_indexes_on_startup()
      end,
      nil
    )

    children =
      case Bonfire.Common.Config.get_ext(:bonfire_search, :adapter) do
        nil ->
          []

        adapter ->
          if function_exported?(adapter, :child_specs, 0), do: adapter.child_specs(), else: []
      end

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  @doc """
  Returns the configured search adapter module.
  Defaults to DB Adapter if no adapter configured or if adapter is disabled.
  """
  def adapter() do
    # fallback = Bonfire.Search.DB
    fallback = nil

    case Bonfire.Common.Config.get_ext(:bonfire_search, :adapter) do
      nil ->
        fallback

      adapter when not is_nil(adapter) ->
        if module_enabled?(adapter), do: adapter, else: fallback
    end
    |> debug()
  end

  @doc """
  Main search function supporting facets and filtering
  """
  def search(string, opts \\ %{}, calculate_facets, filter_facets) do
    adapter = adapter()
    debug(adapter, "search using")
    # debug(opts, "opts")

    if adapter, do: adapter.search(string, to_options(opts), calculate_facets, filter_facets)
  end

  @doc """
  Search with simplified options
  """
  def search(string, opts \\ [])

  def search(string, index_or_opts) do
    adapter = adapter()
    debug(adapter, "search using")
    debug(index_or_opts, "opts")

    if adapter, do: adapter.search(string, index_or_opts)
  end

  # only identity facets merge index hits with a DB query (see `search_by_type/3`)
  @identity_search_types [Bonfire.Data.Identity.User, Bonfire.Data.Identity.Character]

  @doc """
  Type-specific search with optional facets.

  For identity facets, index hits are merged with a direct DB query (see
  `merge_with_db_results/4`). Pass `db_merge: false` to skip it, `raw: true` for
  untransformed index hits.
  """
  def search_by_type(tag_search, facets \\ nil, opts \\ []) do
    adapter = adapter()
    opts = to_options(opts)

    # Whether to merge a DB query into index results (so e.g. users appear without being reindexed).
    # Disabled by default; enable via the `:merge_db_results` config or per-call `db_merge: true`.
    merge_db_results? =
      case opts[:db_merge] do
        nil -> Bonfire.Common.Config.get_ext(:bonfire_search, :merge_db_results, false)
        db_merge -> db_merge
      end

    cond do
      Bonfire.Common.Config.get_ext(:bonfire_search, :disable_for_autocompletes) || !adapter ->
        debug("Search disabled for autocompletes, using DB adapter")
        Bonfire.Search.DB.search_by_type(tag_search, facets, opts)

      adapter == Bonfire.Search.DB || !merge_db_results? || opts[:raw] ||
          not identity_facet?(facets) ->
        adapter.search_by_type(tag_search, facets, opts)

      true ->
        adapter.search_by_type(tag_search, facets, opts)
        |> merge_with_db_results(tag_search, facets, opts)
    end
  end

  defp identity_facet?(facets) do
    facets
    |> List.wrap()
    |> Enum.any?(fn facet ->
      mod = if is_atom(facet), do: facet, else: Types.maybe_to_module(facet)
      mod in @identity_search_types
    end)
  end

  @doc """
  Merges search-index hits with a direct DB query, DB matches first, deduped by ID.

  Returns loaded pointer structs only: index-only IDs (which can be bare maps from
  eg. Meilisearch) are loaded by ID, so the caller can safely preload the result
  and stale index IDs drop out.
  """
  def merge_with_db_results(index_hits, tag_search, facets, opts \\ []) do
    opts = to_options(opts)

    db_results = search_by_type_in_db(tag_search, facets, opts)
    db_ids = Enums.ids(db_results)

    # load index-only IDs as structs so we never return a mix of structs and bare maps
    index_only_ids = Enums.ids(List.wrap(index_hits)) -- db_ids

    index_only =
      if index_only_ids != [],
        do: Bonfire.Boundaries.load_pointers(index_only_ids, skip_boundary_check: true),
        else: []

    (db_results ++ index_only)
    |> Enum.take(opts[:limit] || 20)
  end

  defp search_by_type_in_db(tag_search, facets, opts) do
    List.wrap(Bonfire.Search.DB.search_by_type(tag_search, facets, opts))
  rescue
    e ->
      # a broken type-specific search query shouldn't take down index-based search
      error(e, "Could not query the DB to merge with search index hits")
      []
  end

  @doc """
  Search and load results in one step, returning categorised activities and users.

  For typed adapters (e.g. Meilisearch): uses `search_ids` + `load_activities_for_search`
  + `Users.by_ids` — the efficient path since type info is already in the hits.

  For Sonic (ID-only hits, no type info): skips raw mode and uses `prepare_hits` so
  results are loaded from DB before categorisation. User hits are identified by their
  subject_id equalling object_id (set in `prepare_hits` for standalone objects).
  """
  def search_and_load(string, calculate_facets \\ [], filter_facets \\ %{}, opts \\ []) do
    opts = to_options(opts)
    sonic? = adapter() == Bonfire.Search.Sonic

    search_result = search_categorised(string, calculate_facets, filter_facets, not sonic?, opts)

    if sonic? do
      # Hits are typed structs — apply appropriate preloads per category
      activities =
        search_result.activity_hits
        |> Bonfire.Social.Activities.activity_preloads(@search_preloads,
          current_user: current_user(opts)
        )
        |> Enum.map(&backfill_subject_id/1)
        |> Bonfire.Social.Activities.prepare_subject_and_creator(opts)

      debug(search_result.user_hits, "search_and_load: user_hits before preload")

      users =
        search_result.user_hits
        |> repo().maybe_preload([profile: [:icon], character: []], opts)
        |> debug("search_and_load: user_hits after preload")

      debug(activities, "search_and_load: activity_hits after preload")

      Map.merge(search_result, %{activities: activities, users: users})
    else
      # Meilisearch — activity_hits/user_hits are IDs, load from DB
      activities = load_activities_for_search(search_result.activity_hits, opts)

      users =
        if search_result.user_hits != [],
          do: Bonfire.Me.Users.by_ids(search_result.user_hits, skip_boundary_check: true),
          else: []

      Map.merge(search_result, %{activities: activities, users: users})
    end
  end

  @doc """
  Search and return just IDs + metadata (no struct transformation).
  Categorizes results into post IDs and user IDs for separate loading.
  """
  def search_categorised(
        string,
        calculate_facets \\ [],
        filter_facets \\ %{},
        raw \\ adapter() != Bonfire.Search.Sonic,
        opts \\ []
      ) do
    raw_opts = opts |> Enum.into(%{raw: raw})
    result = search(string, raw_opts, calculate_facets, filter_facets)
    hits = e(result, :hits, [])

    %{activity_hits: activity_hits, user_hits: user_hits, typed: typed} = categorize_hits(hits)

    total_hits =
      e(result, :estimatedTotalHits, nil) || e(result, :totalHits, nil) || length(hits)

    limit = e(result, :limit, nil) || e(result, :hitsPerPage, nil) || opts[:limit] || 20
    offset = e(result, :offset, 0) || opts[:offset] || 0

    # If the adapter doesn't report a total (e.g. Sonic), assume there's more when we got a full page
    has_more = total_hits > offset + limit or length(hits) == limit

    %{
      activity_hits: activity_hits,
      user_hits: user_hits,
      typed: typed,
      facets: if(!filter_facets, do: e(result, :facetDistribution, nil)),
      total_hits: total_hits,
      page_info: %{
        has_next_page: has_more,
        end_cursor: if(has_more, do: to_string(offset + limit))
      }
    }
  end

  @user_index_types ["Bonfire.Data.Identity.User", "Bonfire.Data.Identity.Character"]

  defp categorize_hits(hits) do
    # use prepend + reverse to avoid O(n²) from ++
    # For typed structs (Sonic), store the hit itself; for raw maps (Meili), store just the ID
    result =
      Enum.reduce(
        hits,
        %{activity_hits: [], user_hits: [], typed: false},
        fn hit, acc ->
          type = hit_index_type(hit)
          item = if is_struct(hit), do: hit, else: Enums.id(hit)

          if item do
            if type in @user_index_types do
              %{acc | user_hits: [item | acc.user_hits], typed: true}
            else
              %{
                acc
                | activity_hits: [item | acc.activity_hits],
                  typed: acc.typed || not is_nil(type)
              }
            end
          else
            acc
          end
        end
      )

    %{
      activity_hits: Enum.reverse(result.activity_hits),
      user_hits: if(result.typed, do: Enum.reverse(result.user_hits), else: []),
      typed: result.typed
    }
  end

  defp hit_index_type(%{index_type: type}) when is_binary(type), do: type
  defp hit_index_type(%{"index_type" => type}) when is_binary(type), do: type

  defp hit_index_type(%{__struct__: module} = hit) when module != Needle.Pointer do
    Types.module_to_str(module)
  end

  defp hit_index_type(%{__struct__: _} = hit) do
    # For Needle.Pointer or other pointer-like structs, check the nested object
    hit = e(hit, :activity, :object, nil) || e(hit, :object, nil) || hit

    type = Types.object_type(hit)

    case type do
      t when is_atom(t) and not is_nil(t) -> Types.module_to_str(t)
      _ -> nil
    end
  end

  defp hit_index_type(_), do: nil

  @doc """
  Load activities by object IDs using the standard feed pipeline.
  Preserves the order of input IDs (Meilisearch relevance order).
  """
  def load_activities_for_search(object_ids, opts)
      when is_list(object_ids) and object_ids != [] do
    opts = Keyword.put(opts, :preload, @search_preloads)

    Bonfire.Social.FeedLoader.query_object_extras_boundarised(
      nil,
      %{objects: object_ids},
      opts
    )
    |> repo().many()
    |> Bonfire.Social.Activities.prepare_subject_and_creator(opts)
    |> reorder_by_ids(object_ids)
  end

  def load_activities_for_search(_, _), do: []

  defp reorder_by_ids(loaded_items, ordered_ids) do
    id_map =
      Map.new(loaded_items, fn item ->
        obj_id = e(item, :activity, :object_id, nil) || Enums.id(item)
        {obj_id, item}
      end)

    Enum.flat_map(ordered_ids, fn id ->
      case Map.get(id_map, id) do
        nil -> []
        item -> [item]
      end
    end)
  end

  # Exclude hits whose id ULID encodes a future timestamp (scheduled content), so search mirrors
  # the DB adapter's query-level `maybe_filter_out_future_ulids`. Skipped when `include_scheduled`.
  # Works for both bare index maps (%{"id" => id}) and loaded structs via `id/1`.
  defp filter_out_future_hits(hits, opts) do
    if opts[:include_scheduled] do
      hits
    else
      now = Needle.ULID.generate(System.system_time(:millisecond))

      Enum.filter(hits, fn hit ->
        case id(hit) do
          id when is_binary(id) -> id <= now
          _ -> true
        end
      end)
    end
  end

  def prepare_hits(hits, index, opts) do
    # used for displaying federated objects
    index = normalise_index(index)

    hits
    |> List.wrap()
    |> filter_out_future_hits(opts)
    |> maybe_boundarise(index, opts)
    |> Enum.map(fn hit ->
      if opts[:data_input_type] == :struct do
        hit
      else
        id = id(hit)

        # Create a proper structure that activity_preloads can handle
        case {hit, Types.object_type(hit)} do
          {user, type}
          when type in [Bonfire.Data.Identity.User, Bonfire.Data.Identity.Character] ->
            # Users are categorized separately and loaded via Users.by_ids — no activity wrapping needed
            user

          {%{__struct__: Bonfire.Data.Social.Activity} = activity, _} ->
            activity

          {%{__struct__: _, activity: %{__struct__: Bonfire.Data.Social.Activity} = activity} =
               struct_hit, _} ->
            struct_hit
            |> Map.drop([:created, :subject, :replied])
            |> Map.put(
              :activity,
              activity
              |> Map.merge(%{
                object: struct_hit,
                sensitive: e(hit, :sensitive, nil),
                replied:
                  e(struct_hit, :replied, nil) || e(activity, :replied, nil) ||
                    %Ecto.Association.NotLoaded{}
              })
            )
            |> debug("transformed activity struct")

          {%{__struct__: _} = object, _} ->
            # Already a typed DB struct (e.g. from load_pointers) — use directly as object
            # without mangling it through input_to_atoms/maybe_to_structs
            debug(object, "prepare_hits: typed struct case")

            %Needle.Pointer{
              id: id,
              activity:
                %{id: id, object: object, object_id: id}
                |> maybe_to_struct(Bonfire.Data.Social.Activity)
            }
            |> debug("transformed typed struct")

          _ ->
            # For raw map hits (e.g. Meilisearch), create a structure from the map

            hit =
              hit
              |> input_to_atoms()
              |> maybe_to_structs()
              |> debug("turned hit to structs")

            object =
              hit
              |> Map.merge(%{
                id: id,
                # NOTE: because replied gets preloaded on activity
                replied: %Ecto.Association.NotLoaded{}
              })

            %Needle.Pointer{
              id: id,
              activity:
                hit
                |> Map.merge(%{
                  subject_id: e(object, :created, :creator_id, nil) || id,
                  object: object,
                  object_id: id,
                  # NOTE: because created gets preloaded on object
                  created: %Ecto.Association.NotLoaded{}
                })
                |> maybe_to_struct(Bonfire.Data.Social.Activity)
                #  set a default if not sensitive
                |> Map.put(
                  :sensitive,
                  %{is_sensitive: e(hit, :sensitive, nil)}
                  |> maybe_to_struct(Bonfire.Data.Social.Sensitive)
                )
            }
            |> debug("transformed object struct")
        end
      end
    end)
    # |> debug("converted results to structs")
    |> hits_preloads(opts)
    |> Enum.map(&backfill_subject_id/1)
    |> Bonfire.Social.Activities.prepare_subject_and_creator(opts)
    |> debug("preloaded structs")
  end

  defp backfill_subject_id(%{activity: %{subject_id: sid} = activity} = hit)
       when is_nil(sid) or sid == "" do
    creator_id =
      e(activity, :object, :created, :creator_id, nil) ||
        e(activity, :object, :caretaker_id, nil)

    if creator_id,
      do: put_in(hit, [Access.key(:activity), Access.key(:subject_id)], creator_id),
      else: hit
  end

  defp backfill_subject_id(hit), do: hit

  defp hits_preloads(objects, opts) do
    objects
    |> Bonfire.Social.Activities.activity_preloads(
      [:quote_tags, :with_reply_to, :with_media, :with_creator],
      skip_follow_reply_to: true,
      current_user: current_user(opts)
    )
  end

  def maybe_boundarise(hits, :public, _opts) do
    if adapter() == Bonfire.Search.Sonic do
      info("loading for public index")
      ids = Enums.ids(hits)

      if ids != [],
        do: Bonfire.Boundaries.load_pointers(ids, skip_boundary_check: true),
        else: hits
    else
      debug("skip loading for public index")
      hits
    end
  end

  def maybe_boundarise(hits, _closed, opts) do
    opts = to_options(opts)

    if Bonfire.Boundaries.Queries.skip_boundary_check?(opts) do
      maybe_boundarise(hits, :public, opts)
    else
      # WIP: filter by boundaries for closed index
      list_of_ids =
        Enums.ids(hits)
        |> debug()

      sonic? = adapter() == Bonfire.Search.Sonic

      if current_user = current_user(opts) do
        visible =
          Bonfire.Boundaries.load_pointers(list_of_ids,
            current_user: current_user,
            verbs: e(opts, :verbs, [:see, :read]),
            ids_only: not sonic?
          )
          |> debug("maybe_boundarise: closed load_pointers result")

        if sonic?,
          do: visible,
          else: Enum.filter(hits, &(Enums.id(&1) in Enums.ids(visible)))
      else
        warn("maybe_boundarise: no current_user, returning []")
        []
      end
    end
  end

  def normalise_index("public"), do: :public
  def normalise_index(["public"]), do: :public
  def normalise_index(true), do: :public
  def normalise_index("closed"), do: :closed
  def normalise_index(["closed"]), do: :closed
  def normalise_index(false), do: :closed
  def normalise_index(index), do: index

  # Boundary names (as set when publishing) that mean "anyone can see this", so
  # the object belongs in the `:public` search index. `"public_remote"` is the
  # boundary assigned to incoming *federated* public content (see
  # `Bonfire.Federate.ActivityPub.AdapterUtils.recipients_boundary_circles/4`),
  # which maps to the same "public" access preset — without this it would wrongly
  # land in the `:closed` index via the generic `is_binary/1` clause below.
  @public_boundary_names ["public", "public_remote"]

  @doc """
  Returns true if a boundary (a name, or a list of names) grants public read
  access, meaning matching objects should go in the `:public` search index.

  ## Examples

      iex> Bonfire.Search.public_boundary_name?("public")
      true

      iex> Bonfire.Search.public_boundary_name?("public_remote")
      true

      iex> Bonfire.Search.public_boundary_name?("mentions")
      false

      iex> Bonfire.Search.public_boundary_name?(["local", "public_remote"])
      true

      iex> Bonfire.Search.public_boundary_name?(["mentions"])
      false

      iex> Bonfire.Search.public_boundary_name?(nil)
      false
  """
  def public_boundary_name?(boundary) when is_binary(boundary),
    do: boundary in @public_boundary_names

  def public_boundary_name?(boundaries) when is_list(boundaries),
    do: Enum.any?(@public_boundary_names, &(&1 in boundaries))

  def public_boundary_name?(_), do: false

  def maybe_index(object, true, opts), do: maybe_index(object, :public, opts)
  def maybe_index(object, false, opts), do: maybe_index(object, :closed, opts)

  def maybe_index(object, nil, opts) do
    if maybe_apply(Bonfire.Boundaries, :object_public?, [object], fallback_return: false) do
      maybe_index(object, :public, opts)
    else
      debug("object_public? didn't return true, so indexing as closed")
      maybe_index(object, :closed, opts)
    end
  end

  def maybe_index(object, boundary, opts) when is_binary(boundary) do
    if public_boundary_name?(boundary),
      do: maybe_index(object, :public, opts),
      else: maybe_index(object, :closed, opts)
  end

  def maybe_index(object, boundaries, opts) when is_list(boundaries) do
    if public_boundary_name?(boundaries) do
      maybe_index(object, :public, opts)
    else
      debug(boundaries, "no `public`/`public_remote` boundary in list, so indexing as closed")
      maybe_index(object, :closed, opts)
    end
  end

  def maybe_index(object, index, opts) when is_atom(index) do
    assumed_caretaker =
      repo().maybe_preload(
        e(object, :created, :creator, nil) || e(object, :activity, :created, :creator, nil) ||
          e(object, :activity, :object, :created, :creator, nil) ||
          e(object, :creator, nil) ||
          e(object, :caretaker, :caretaker, nil) ||
          e(object, :caretaker, nil) || e(object, :activity, :subject, nil) || current_user(opts),
        :settings
      )

    # check it here again in case creator is only available after the preloads in prepare_object
    if module =
         Bonfire.Common.Extend.maybe_module(
           Bonfire.Search.Indexer,
           assumed_caretaker
         ) do
      object
      # FIXME: should be done in a Social act
      |> Bonfire.Social.Activities.activity_under_object()
      |> module.maybe_queue_or_index(index)
    else
      # TODO: should we index in closed index in this case?
      info(assumed_caretaker, "Search indexing is disabled for this user")
      {:error, :search_index_disabled}
    end
  end

  def maybe_unindex(object) do
    creator =
      repo().maybe_preload(
        e(object, :created, :creator, nil) || e(object, :activity, :created, :creator, nil) ||
          e(object, :creator, nil) || e(object, :created, :creator_id, nil) ||
          e(object, :activity, :created, :creator_id, nil) || e(object, :creator_id, nil) ||
          object,
        :settings
      )

    index =
      if maybe_apply(Bonfire.Boundaries, :object_public?, [object], fallback_return: false) do
        :public
      else
        :closed
      end

    if module = Bonfire.Common.Extend.maybe_module(Bonfire.Search.Indexer, creator) do
      module.maybe_delete_object(object, index)
    else
      :ok
    end
  end
end
