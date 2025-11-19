defmodule Bonfire.Search.DB do
  @moduledoc """
  Database-based search adapter implementation.
  Uses Ecto queries to search across tables directly in the database.
  """
  @behaviour Bonfire.Search.Adapter

  import Ecto.Query
  import Untangle
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

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
  Type-specific search implementation
  """
  @impl true
  def search_by_type(tag_search, facets, opts \\ []) do
    run_search_db(tag_search, facets, opts)
  end

  # Private functions moved from Bonfire.Search

  def run_search_db(search, types, opts) do
    # limit = opts[:limit] || 20

    do_search_db(opts[:query] || base_query(), search, types, opts ++ [skip_boundary_check: true])
    # |> Bonfire.Tag.search_hashtagged_query(search, opts) # TODO: use do_search_db like other types
    |> where([p], is_nil(p.deleted_at))
    # |> limit(^limit)
    |> debug("core query")
    |> paginate_and_boundarise_deferred_query(search, List.wrap(types), opts)
    |> repo().many()

    # |> Bonfire.Social.many(true, opts)
  end

  defp paginate_and_boundarise_deferred_query(initial_query, search, types, opts) do
    # speeds up queries by applying filters (incl. pagination) in a deferred join before boundarising and extra joins/preloads

    subquery =
      initial_query
      |> select([:id])
      # to avoid 'cannot preload in subquery' error
      |> maybe_order_override(search, length(types))
      |> Bonfire.Social.many(true, return: :query, multiply_limit: 2)
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
    Bonfire.Common.Needles.Pointers.Queries.query()
    # Bonfire.Common.Needles.Pointers.Queries.query_incl_deleted()
  end

  defp do_search_db(query, search, types, opts) when is_list(types) do
    types
    |> Enum.reduce(query, fn type, query ->
      do_search_db(query, search, type, opts)
    end)
  end

  defp do_search_db(query, search, type, opts) when is_binary(type) do
    case Types.maybe_to_module(type) do
      nil ->
        debug(type, "not a module")
        query

      mod ->
        do_search_db(query, search, mod, opts)
    end
  end

  defp do_search_db(query, search, type, opts) do
    if is_atom(type) do
      debug(type, "try searching in DB ")

      # Bonfire.Common.QueryModule.maybe_query_module(type) ||
      (Bonfire.Common.ContextModule.maybe_context_module(type) ||
         type)
      |> maybe_apply(
        [:search_query, :search],
        [search, Keyword.put(opts, :query, query)],
        &none/2
      ) || query
    else
      debug("no module, so skip searching ")
      query
    end
  end

  def default_types(opts \\ []) do
    # TODO: make default types generated/configurable
    [Bonfire.Data.Identity.User, Bonfire.Data.Social.Post, Bonfire.Tag.Tagged]
  end

  defp none(e, _) do
    debug(e)
    nil
  end
end
