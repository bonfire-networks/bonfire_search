# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_search)

# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  import Untangle
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @doc """
  Returns the configured search adapter module.
  Defaults to DB Adapter if no adapter configured or if adapter is disabled.
  """
  def adapter do
    case Bonfire.Common.Config.get_ext(:bonfire_search, :adapter) do
      nil ->
        Bonfire.Search.DB

      adapter when not is_nil(adapter) ->
        if module_enabled?(adapter), do: adapter, else: Bonfire.Search.DB
    end
    |> debug()
  end

  @doc """
  Main search function supporting facets and filtering
  """
  def search(string, opts \\ %{}, calculate_facets, filter_facets) do
    adapter = adapter()
    debug(adapter, "search using")

    adapter.search(string, to_options(opts), calculate_facets, filter_facets)
  end

  @doc """
  Search with simplified options
  """
  def search(string, opts \\ [])

  def search(string, opts) when is_list(opts) or is_map(opts) do
    adapter = adapter()
    debug(adapter, "search using")

    adapter.search(string, opts)
  end

  def search(string, index) when is_binary(index) or is_atom(index) do
    adapter = adapter()
    debug(adapter, "search using")

    adapter.search(string, index)
  end

  @doc """
  Type-specific search with optional facets
  """
  def search_by_type(tag_search, facets \\ nil, opts \\ []) do
    if Bonfire.Common.Config.get_ext(:bonfire_search, :disable_for_autocompletes) do
      debug("Search disabled for autocompletes, using DB adapter")
      Bonfire.Search.DB.search_by_type(tag_search, facets)
    else
      adapter().search_by_type(tag_search, facets)
    end
  end
end
