# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Meili do
  import Untangle

  def search(%{} = params, index) when is_binary(index) do
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
      %{"searchableAttributes"=> fields},
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
    api(:put, object, index_path, fail_silently) #|> IO.inspect
  end

  def patch(object, index_path \\ "", fail_silently \\ false) do
    api(:patch, object, index_path, fail_silently) #|> IO.inspect
  end

  def delete(object, index_path \\ "", fail_silently \\ false) do
    api(:delete, object, index_path, fail_silently) #|> IO.inspect
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

    with {:ok, %{status: code} = ret} when code == 200 or code == 201 or code == 202 <-
           Bonfire.Search.HTTP.http_request(http_method, url, headers, object) do
      # IO.inspect(ret)
      # debug("Search - api OK")
      {:ok, %{ret | body: Jason.decode!(Map.get(ret, :body))}}
    else
      {_, %{body: body, status: code}} ->
        case Jason.decode(body) do
          {:ok, body} ->
            Bonfire.Search.HTTP.http_error(fail_silently, http_method, %{code: code, body: body}, object, url)
          _e ->
            Bonfire.Search.HTTP.http_error(fail_silently, http_method, %{code: code, body: body}, object, url)
        end
      {_, message} ->
        Bonfire.Search.HTTP.http_error(fail_silently, http_method, message, object, url)
      other ->
        Bonfire.Search.HTTP.http_error(fail_silently, http_method, other, object, url)
    end
  end
end
