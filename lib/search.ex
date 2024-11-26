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
    debug(opts, "opts")

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
end
