defmodule Bonfire.Search.DB do
  @moduledoc """
  Database-based search adapter implementation.
  Uses Ecto queries to search across tables directly in the database.
  """
  use Bonfire.Search.Adapter

  import Ecto.Query
  import Untangle
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @impl true
  def healthy?, do: true

  def batch_indexing?, do: false

  @doc """
  Main search implementation using database queries
  """
  @impl true
  def search(string, opts, calculate_facets, filter_facets) when is_map(filter_facets) do
    search_results =
      run_search_db(
        string,
        e(filter_facets, nil) || default_types(opts),
        to_options(opts)
      )

    %{
      hits: search_results,
      # TODO
      processed_in_ms: nil,
      # "facet_distribution" => calculate_facets && %{},
      total: length(search_results)
    }
  end

  @impl true
  def search(string, opts) when is_list(opts) do
    search_results = run_search_db(string, default_types(opts), to_options(opts))

    %{
      hits: search_results,
      total: length(search_results)
    }
  end

  @impl true
  def search(string, index) when is_binary(index) or is_atom(index) do
    search_results = run_search_db(string, default_types(), [])

    %{
      hits: search_results,
      total: length(search_results)
    }
  end

  @doc """
  Type-specific search implementation.

  Returns nil unless every requested type has a `search_query/2`, so callers run their own lookup rather than get partial or unfiltered results.
  """
  @impl true
  def search_by_type(tag_search, facets, opts \\ []) do
    types = List.wrap(facets)

    if types != [] and Enum.all?(types, &search_query_module/1) do
      run_search_db(tag_search, types, opts)
    else
      warn(facets, "not all types can be searched in the DB")
      nil
    end
  end

  # Private functions moved from Bonfire.Search

  def run_search_db(search, types, opts) do
    # limit = opts[:limit] || 20

    do_search_db(opts[:query] || base_query(), search, types, opts ++ [skip_boundary_check: true])
    # |> Bonfire.Tag.search_hashtagged_query(search, opts) # TODO: use do_search_db like other types
    # re-apply (AND-composed) the deleted + future-ULID filters that base_query omits
    |> where([p], is_nil(p.deleted_at))
    |> repo().maybe_filter_out_future_ulids()
    # |> limit(^limit)
    |> debug("core query")
    |> paginate_and_boundarise_deferred_query(search, List.wrap(types), opts)
    |> repo().many()

    # |> repo().many_maybe_paginated(true, opts)
  end

  defp paginate_and_boundarise_deferred_query(initial_query, search, types, opts) do
    # speeds up queries by applying filters (incl. pagination) in a deferred join before boundarising and extra joins/preloads

    subquery =
      initial_query
      |> select([:id])
      # to avoid 'cannot preload in subquery' error
      |> maybe_order_override(search, length(types))
      |> repo().many_maybe_paginated(true, return: :query, multiply_limit: 2)
      |> repo().make_subquery()
      |> debug("deferred subquery")

    initial_query
    |> Ecto.Query.exclude(:preload)
    |> Ecto.Query.exclude(:where)
    |> Ecto.Query.exclude(:order_by)
    # (opts[:query] || base_query())
    |> join(:inner, [fp], ^subquery, on: [id: fp.id])
    |> Bonfire.Common.Needles.pointer_query(
      opts ++ [preload: [:with_content, :with_creator, :profile_info]]
    )
    # |> Bonfire.Social.Objects.as_permitted_for(opts)
    |> debug("query with deferred join")
  end

  defp maybe_order_override(query, _, 1), do: query

  defp maybe_order_override(query, text, _several) do
    query
    |> Ecto.Query.exclude(:order_by)
    |> order_by([named: n, post_content: pc, profile: p, character: c], [
      {:desc,
       fragment(
         "(? <% ?)::int + (? <% ?)::int + (? <% ?)::int + (? <% ?)::int + (? <% ?)::int + (? <% ?)::int",
         ^text,
         n.name,
         ^text,
         pc.name,
         ^text,
         pc.summary,
         ^text,
         c.username,
         ^text,
         p.name,
         ^text,
         p.summary
       )}
    ])
  end

  def base_query do
    # must stay `where`-free: type-specific conditions are added with `or_where`, so any
    # base condition would get OR'ed in and match almost everything. run_search_db re-adds
    # the deleted/future filters with AND afterwards.
    Bonfire.Common.Needles.Pointers.Queries.query_incl_deleted()
  end

  defp do_search_db(query, search, types, opts) when is_list(types) do
    types
    |> Enum.reduce(query, fn type, query ->
      do_search_db(query, search, type, opts)
    end)
  end

  defp do_search_db(query, search, type, opts) do
    case search_query_module(type) do
      nil ->
        debug(type, "no search_query/2 for this type, so skip searching")
        query

      mod ->
        mod.search_query(search, Keyword.put(opts, :query, query)) || query
    end
  end

  # Only `search_query/2` qualifies: a context's `search/2` may itself call `Bonfire.Search.search_by_type`, which would loop back here.
  defp search_query_module(type) when is_binary(type),
    do: search_query_module(Types.maybe_to_module(type))

  defp search_query_module(type) when is_atom(type) and not is_nil(type) do
    mod = Bonfire.Common.ContextModule.maybe_context_module(type) || type
    if Code.ensure_loaded?(mod) and function_exported?(mod, :search_query, 2), do: mod
  end

  defp search_query_module(_), do: nil

  def default_types(opts \\ []) do
    # TODO: make default types generated/configurable
    [Bonfire.Data.Identity.User, Bonfire.Data.Social.Post, Bonfire.Tag.Tagged]
  end
end
