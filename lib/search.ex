# check that this extension is configured
Bonfire.Common.Config.require_extension_config!(:bonfire_search)

# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search do
  require Logger

  @adapter Bonfire.Common.Config.get_ext!(:bonfire_search, :adapter)

  def public_index(), do: Bonfire.Common.Config.get_ext(:bonfire_search, :public_index, "public")

  def search(string, opts, calculate_facets, filter_facets) when is_map(filter_facets) do
    search(
      string,
      opts,
      calculate_facets,
      filter_facets
      |> Enum.map(&facet_from_map/1)
    )
  end

  def search(string, opts, calculate_facets, filter_facets) when is_list(filter_facets) do
    opts = Map.merge(%{
      facetFilters: List.flatten(filter_facets)
    }, opts)

    search(string, opts, calculate_facets)
  end

  def search(string, opts, calculate_facets, _) do
    search(string, opts, calculate_facets)
  end

  def search(string, opts, calculate_facets) when not is_nil(calculate_facets) do
    opts = Map.merge(%{
      q: string,
      facetsDistribution: ["*"]
    }, opts)

    search(string, opts)
  end

  def search(params, opts, _) do
    search(params, opts)
  end


  def search(params, opts \\ nil)

  def search(string, index) when is_binary(string) and is_binary(index) do
    # deprecate
    object = %{
      q: string
    }

    search(object, index)
  end

  def search(string, opts) when is_binary(string) and is_map(opts) do
    Map.merge(%{
      q: string
    }, opts)
    |>
    search(Map.get(opts, :index, public_index()))
  end

  def search(object, index) when is_map(object) and is_binary(index) do
    @adapter.search(object, index)
  end

  def search(params, _) do
    search(params, public_index())
  end


  def facet_from_map({key, values}) when is_list(values) do
    values
    |> Enum.map(&facet_from_map({key, &1}))
  end

  def facet_from_map({key, value}) when is_binary(value) do
    "#{key}:#{value}"
  end
end
