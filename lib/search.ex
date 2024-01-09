# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_search)

# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search do
  import Untangle
  use Bonfire.Common.Utils

  def adapter, do: Bonfire.Common.Config.get_ext(:bonfire_search, :adapter)

  def search_by_type(tag_search, facets \\ nil, opts \\ []) do
    adapter = adapter()

    if is_nil(adapter) or !module_enabled?(adapter) or
         Bonfire.Common.Config.get_ext(:bonfire_search, :disable_for_autocompletes) do
      do_search_db(tag_search, facets, to_options(opts))
    else
      adapter.search_by_type(tag_search, facets)
    end
  end

  defp none(e, _) do
    debug(e)
    []
  end

  defp do_search_db(search, types, opts) when is_list(types) do
    types
    |> Enum.flat_map(fn type ->
      do_search_db(search, type, opts)
    end)
  end

  defp do_search_db(search, type, opts) when is_binary(type) do
    case Types.maybe_to_module(type) do
      nil ->
        debug(type, "not a module")
        []

      mod ->
        do_search_db(search, mod, opts)
    end
  end

  defp do_search_db(search, type, opts) do
    if is_atom(type) do
      debug(" try searching in DB ")

      # Bonfire.Common.QueryModule.maybe_query_module(type) || 
      (Bonfire.Common.ContextModule.maybe_context_module(type) ||
         type)
      |> maybe_apply([:search_db, :search], [search, opts], &none/2)
    else
      debug("no module, so skip searching ")
      []
    end
  end

  def search(string, opts \\ %{}, calculate_facets, filter_facets) do
    adapter = adapter()

    if is_nil(adapter) or !module_enabled?(adapter) do
      opts = to_options(opts)
      do_search_db(string, e(filter_facets, nil) || default_types(opts), opts)
    else
      maybe_apply(adapter, :search, [string, opts, calculate_facets, filter_facets])
    end
  end

  def search(string, opts_or_index \\ nil) do
    adapter = adapter()

    if is_nil(adapter) or !module_enabled?(adapter) do
      opts = to_options(opts_or_index)
      do_search_db(string, default_types(opts), opts)
    else
      maybe_apply(adapter, :search, [string, opts_or_index])
    end
  end

  def default_types(_opts) do
    # TODO: make default types generated/configurable
    [Bonfire.Data.Identity.User, Bonfire.Data.Social.Post]
  end
end
