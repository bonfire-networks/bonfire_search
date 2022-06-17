# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_search)

# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search do
  import Where
  alias Bonfire.Common.Utils

  def adapter, do: Bonfire.Common.Config.get_ext!(:bonfire_search, :adapter)

  def public_index(), do: Bonfire.Common.Config.get_ext(:bonfire_search, :public_index, "public")

  def search_by_type(tag_search, facets \\ nil) do
    facets = search_facets(facets)
    debug("search: #{inspect tag_search} with facets #{inspect facets}")
    search = search(tag_search, false, facets)
    # IO.inspect(searched: search)

    if(is_map(search) and Map.has_key?(search, "hits") and length(search["hits"])) do
      search["hits"]
      |> Utils.filter_empty([])
      # |> IO.inspect(label: "search results")
    end
  end

  defp search_facets(nil) do
    nil
  end
  defp search_facets(facets) do
    %{"index_type" => facets
      #|> search_prefix()
    }
  end

  def search(string, opts \\ %{}, calculate_facets, filter_facets)

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
    opts = Map.merge(opts, %{
      filter: List.flatten(filter_facets)
    })

    do_search(string, opts, calculate_facets)
  end

  def search(string, opts, calculate_facets, _) do
    do_search(string, opts, calculate_facets)
  end


  defp do_search(string, opts, calculate_facets) when not is_nil(calculate_facets) do
    opts = Map.merge(%{
      facetsDistribution: ["*"]
    }, opts)

    search(string, opts)
  end

  defp do_search(string, opts, _) do
    search(string, opts)
  end


  def search(string, opts_or_index \\ nil)

  def search(string, index) when is_binary(string) and is_binary(index) do
    # deprecate
    object = %{
      q: string
    }
    search(object, index)
  end

  def search(string, %{index: index} = opts) when is_binary(string) and is_map(opts) do
    %{
      q: string
    }
    |> Map.merge(opts)
    |> Map.drop([:index])
    |> search(index)
  end

  def search(string, opts) when is_binary(string) and is_map(opts) do
    %{
      q: string
    }
    |> Map.merge(opts)
    |> search(public_index())
  end

  def search(object, index) when is_map(object) and is_binary(index) do
    adapter().search(object, index)
  end

  def search(object, _) when is_map(object) do
    search(object, public_index())
  end


  def facet_from_map({key, values}) when is_list(values) do
    values
    |> Enum.map(&facet_from_map({key, &1}))
  end

  def facet_from_map({key, value}) when is_binary(value) do
    "#{key} = #{value}"
  end
end
