# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Meili do
  import Untangle
  use Bonfire.Common.Utils

  def public_index(),
    do: Bonfire.Common.Config.get_ext(:bonfire_search, :public_index, "public")

  def search_by_type(tag_search, facets \\ nil) do
    facets = search_facets(facets)
    debug("search: #{inspect(tag_search)} with facets #{inspect(facets)}")
    search = search(tag_search, %{}, false, facets)

    # IO.inspect(searched: search)

    if(is_map(search) and Map.has_key?(search, "hits") and length(search["hits"])) do
      search["hits"]
      |> Enums.filter_empty([])

      # |> IO.inspect(label: "search results")
    end
  end

  defp search_facets(facets) when is_list(facets) or is_binary(facets) do
    %{
      "index_type" => List.wrap(facets)
      # |> search_prefix()
    }
  end

  defp search_facets(facet) when is_atom(facet) and not is_nil(facet) do
    search_facets(Types.module_to_str(facet))
  end

  defp search_facets(nil) do
    nil
  end

  def search(string, opts, calculate_facets, filter_facets)
      when is_map(filter_facets) do
    search(
      string,
      opts,
      calculate_facets,
      Enum.map(filter_facets, &facet_from_map/1)
    )
  end

  def search(string, opts, calculate_facets, filter_facets)
      when is_list(filter_facets) do
    opts =
      Map.merge(opts, %{
        filter: List.flatten(filter_facets)
      })

    do_search(string, opts, calculate_facets)
  end

  def search(string, opts, calculate_facets, _) do
    do_search(string, opts, calculate_facets)
  end

  defp do_search(string, opts, calculate_facets)
       when not is_nil(calculate_facets) do
    # opts = Map.merge(%{
    #   facetDistribution: ["*"]
    # }, opts)

    search(string, opts)
  end

  defp do_search(string, opts, _) do
    search(string, opts)
  end

  def search(string, index) when is_binary(string) and is_binary(index) do
    # deprecate
    object = %{
      q: string
    }

    search(object, index)
  end

  def search(string, %{index: index} = opts)
      when is_binary(string) and is_map(opts) do
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
    search_execute(object, index)
  end

  def search(object, _) when is_map(object) do
    search(object, public_index())
  end

  def facet_from_map({key, values}) when is_list(values) do
    Enum.map(values, &facet_from_map({key, &1}))
  end

  def facet_from_map({key, value}) when is_binary(value) or is_atom(value) do
    "#{key} = #{value}"
  end

  def search_execute(%{} = params, index) when is_binary(index) do
    # IO.inspect(search_params: params)

    with {:ok, %{body: results}} <- api(:post, params, index <> "/search") do
      results
    else
      e ->
        warn("Could not search Meili")
        debug(inspect(e))
        nil
    end
  end

  def index_exists(index_name) do
    with {:ok, _index} <- get(nil, index_name) do
      true
    else
      _e ->
        false
    end
  end

  def create_index(index_name, fail_silently \\ false) do
    post(%{uid: index_name}, "", fail_silently)
  end

  def list_facets(index_name \\ "public") do
    get(nil, index_name <> "/settings/filterable-attributes")
  end

  def set_facets(index_name, facets) when is_list(facets) do
    settings(
      %{"filterableAttributes" => facets},
      index_name
    )
  end

  def set_facets(index_name, facet) do
    set_facets(index_name, [facet])
  end

  def set_searchable_fields(index_name, fields) do
    settings(
      %{"searchableAttributes" => fields},
      index_name
    )
  end

  def get(object) do
    get(object, "")
  end

  def get(object, index_path, fail_silently \\ false) do
    api(:get, object, index_path, fail_silently)
  end

  def post(object, index_path \\ "", fail_silently \\ false) do
    api(:post, object, index_path, fail_silently)
  end

  def put(object, index_path \\ "", fail_silently \\ false) do
    # |> IO.inspect
    api(:put, object, index_path, fail_silently)
  end

  def patch(object, index_path \\ "", fail_silently \\ false) do
    # |> IO.inspect
    api(:patch, object, index_path, fail_silently)
  end

  def delete(object, index_path \\ "", fail_silently \\ false) do
    # |> IO.inspect
    api(:delete, object, index_path, fail_silently)
  end

  def settings(object, index) do
    patch(object, index <> "/settings")
  end

  def api(http_method, object, index_path, fail_silently \\ false) do
    search_instance = Bonfire.Common.Config.get_ext!(:bonfire_search, :instance)
    api_key = Bonfire.Common.Config.get_ext!(:bonfire_search, :api_key)

    url = "#{search_instance}/indexes/" <> index_path

    # if api_key do
    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-type", "application/json"}
    ]

    debug(object, "object to #{http_method}")

    with {:ok, %{status: code} = ret}
         when code == 200 or code == 201 or code == 202 <-
           Bonfire.Search.HTTP.http_request(http_method, url, headers, object) do
      # IO.inspect(ret)
      # debug("Search - api OK")
      {:ok, %{ret | body: Jason.decode!(Map.get(ret, :body))}}
    else
      {_, %{body: body, status: code}} ->
        case Jason.decode(body) do
          {:ok, body} ->
            Bonfire.Search.HTTP.http_error(
              fail_silently,
              http_method,
              %{code: code, body: body},
              object,
              url
            )

          _e ->
            Bonfire.Search.HTTP.http_error(
              fail_silently,
              http_method,
              %{code: code, body: body},
              object,
              url
            )
        end

      {_, message} ->
        Bonfire.Search.HTTP.http_error(
          fail_silently,
          http_method,
          message,
          object,
          url
        )

      other ->
        Bonfire.Search.HTTP.http_error(
          fail_silently,
          http_method,
          other,
          object,
          url
        )
    end
  end
end
