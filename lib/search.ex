# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_search)

# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  import Untangle
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  use Bonfire.Common.Config

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

  @doc """
  Type-specific search with optional facets
  """
  def search_by_type(tag_search, facets \\ nil, opts \\ []) do
    adapter = adapter()

    if Bonfire.Common.Config.get_ext(:bonfire_search, :disable_for_autocompletes) || !adapter do
      debug("Search disabled for autocompletes, using DB adapter")
      Bonfire.Search.DB.search_by_type(tag_search, facets)
    else
      adapter.search_by_type(tag_search, facets)
    end
  end

  def prepare_hits(hits, index, opts) do
    # used for displaying federated objects 
    index = normalise_index(index)

    hits
    |> List.wrap()
    |> maybe_boundarise(index, opts)
    |> Enum.map(fn hit ->
      if opts[:data_input_type] == :struct do
        hit
      else
        id = id(hit)

        # Create a proper structure that activity_preloads can handle
        case hit do
          %{__struct__: Bonfire.Data.Social.Activity} = activity ->
            activity

          %{__struct__: _, activity: %{__struct__: Bonfire.Data.Social.Activity} = activity} =
              struct_hit ->
            struct_hit
            |> Map.drop([:created, :subject, :replied])
            |> Map.put(
              :activity,
              activity
              |> Map.merge(%{
                object: struct_hit,
                # subject:
                #   e(struct_hit, :created, :creator, nil) || e(activity, :subject, nil) ||
                #     e(struct_hit, :caretaker, nil) || %Ecto.Association.NotLoaded{},
                #  set a default if not sensitive
                sensitive: e(hit, :sensitive, nil),
                replied:
                  e(struct_hit, :replied, nil) || e(activity, :replied, nil) ||
                    %Ecto.Association.NotLoaded{}
              })
            )

          # %Needle.Pointer{
          #   id: id,
          #   activity: %Bonfire.Data.Social.Activity{
          #     object: struct_hit,
          #     object_id: id,
          #     id: id
          #   }
          # }

          _ ->
            # For non-Activity hits, create a simpler structure

            hit =
              hit
              |> input_to_atoms()
              |> maybe_to_structs()
              |> debug("turned hit to structs")

            %Needle.Pointer{
              id: id,
              activity:
                hit
                |> Map.merge(%{
                  object: hit,
                  object_id: id,
                  id: id
                  # replied: %Ecto.Association.NotLoaded{}
                })
                |> maybe_to_struct(Bonfire.Data.Social.Activity)
                #  set a default if not sensitive
                |> Map.put(:sensitive, e(hit, :sensitive, nil))
            }
            |> debug("transformed object struct")
        end
      end
    end)
    |> debug("converted results to structs")
    |> hits_preloads(opts)
  end

  defp hits_preloads(objects, opts) do
    objects
    |> Bonfire.Social.Activities.activity_preloads(
      [:with_reply_to, :with_media, :with_creator],
      skip_follow_reply_to: true,
      current_user: current_user(opts)
    )
  end

  def maybe_boundarise(hits, :public, _) do
    debug("skip boundarising for public index")
    hits
  end

  def maybe_boundarise(hits, _closed, opts) do
    opts = to_options(opts)

    if Bonfire.Boundaries.Queries.skip_boundary_check?(opts) do
      hits
    else
      # WIP: filter by boundaries for closed index
      list_of_ids =
        Enums.ids(hits)
        |> debug()

      my_visible_ids =
        if current_user = current_user(opts),
          do:
            Bonfire.Boundaries.load_pointers(list_of_ids,
              current_user: current_user,
              verbs: e(opts, :verbs, [:see, :read]),
              ids_only: true
            )
            |> Enums.ids(),
          else: []

      Enum.filter(hits, &(Enums.id(&1) in my_visible_ids))
    end
  end

  def normalise_index("public"), do: :public
  def normalise_index(["public"]), do: :public
  def normalise_index(true), do: :public
  def normalise_index("closed"), do: :closed
  def normalise_index(["closed"]), do: :closed
  def normalise_index(false), do: :closed
  def normalise_index(index), do: index

  def maybe_index(object, "public", opts), do: maybe_index(object, :public, opts)
  def maybe_index(object, ["public"], opts), do: maybe_index(object, :public, opts)
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

  def maybe_index(object, boundary, opts) when is_binary(boundary),
    do: maybe_index(object, :closed, opts)

  def maybe_index(object, boundaries, opts) when is_list(boundaries) do
    if "public" in boundaries do
      maybe_index(object, :public, opts)
    else
      debug(boundaries, "`public` was not in list of boundaries, so indexing as closed")
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
      |> module.maybe_index_object(index)
    else
      # TODO: should we index in closed index in this case?
      error(assumed_caretaker, "Search indexing is disabled for this user")
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
