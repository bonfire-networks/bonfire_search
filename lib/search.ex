# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_search)

# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  import Untangle
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  def adapter, do: Bonfire.Common.Config.get_ext(:bonfire_search, :adapter)

  def search_by_type(tag_search, facets \\ nil, opts \\ []) do
    adapter = adapter()

    if is_nil(adapter) or !module_enabled?(adapter) or
         Bonfire.Common.Config.get_ext(:bonfire_search, :disable_for_autocompletes) do
      run_search_db(tag_search, facets, to_options(opts))
    else
      adapter.search_by_type(tag_search, facets)
    end
  end

  defp none(e, _) do
    debug(e)
    nil
  end

  def run_search_db(search, types, opts) do
    # limit = opts[:limit] || 20

    do_search_db(opts[:query] || base_query(), search, types, opts ++ [skip_boundary_check: true])
    |> debug()
    # |> Bonfire.Tag.search_hashtagged_query(search, opts) # TODO: use do_search_db like other types
    |> where([p], is_nil(p.deleted_at))
    # |> limit(^limit)
    |> debug()
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

  def search(string, opts \\ %{}, calculate_facets, filter_facets) do
    adapter = adapter()

    if is_nil(adapter) or !module_enabled?(adapter) do
      opts = to_options(opts)
      run_search_db(string, e(filter_facets, nil) || default_types(opts), opts)
    else
      maybe_apply(adapter, :search, [string, opts, calculate_facets, filter_facets])
    end
  end

  def search(string, opts_or_index \\ nil) do
    adapter = adapter()

    if is_nil(adapter) or !module_enabled?(adapter) do
      opts = to_options(opts_or_index)
      run_search_db(string, default_types(opts), opts)
    else
      maybe_apply(adapter, :search, [string, opts_or_index])
    end
  end

  def default_types(_opts) do
    # TODO: make default types generated/configurable
    [Bonfire.Data.Identity.User, Bonfire.Data.Social.Post, Bonfire.Tag.Tagged]
  end
end
