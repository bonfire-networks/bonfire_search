# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Meili do
  #  NOTE: deprecated in favour of MeiliLib adapter
  @moduledoc false
  import Untangle
  use Bonfire.Common.Utils
  alias Bonfire.Search.Indexer

  @behaviour Bonfire.Search.Adapter

  def search_by_type(tag_search, facets \\ nil) do
    facets = search_facets(facets)
    debug(facets, "search: #{inspect(tag_search)} with facets")
    search = search(tag_search, %{}, false, facets)

    # IO.inspect(searched: search)

    e(search, :hits, [])
    |> Enums.filter_empty([])

    # |> IO.inspect(label: "search results")
  end

  defp search_facets(facets) when is_list(facets) or is_binary(facets) do
    %{
      "index_type" => List.wrap(facets) |> Enum.map(&Types.module_to_str/1)
      # |> search_prefix()
    }
  end

  defp search_facets(facet) when is_atom(facet) and not is_nil(facet) do
    search_facets([facet])
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
      opts
      |> Enum.into(%{
        filter: List.flatten(filter_facets)
      })

    search_maybe_with_facets(string, opts, calculate_facets)
  end

  def search(string, opts, calculate_facets, _) do
    search_maybe_with_facets(string, opts, calculate_facets)
  end

  def search(string, index) when is_binary(string) and (is_binary(index) or is_atom(index)) do
    # deprecate
    object = %{
      q: string
    }

    search(object, index)
  end

  def search(string, %{index: index} = opts)
      when is_binary(string) and (is_binary(index) or is_atom(index)) do
    Map.drop(opts, [:current_user, :context, :index])
    |> Enum.into(%{
      q: string
    })
    |> search(index, opts)
  end

  def search(string, opts) when is_binary(string) and (is_map(opts) or is_list(opts)) do
    Enums.fun(opts, :drop, [[:current_user, :context, :index]])
    |> Enum.into(%{
      q: string
    })
    |> search(opts[:index], opts)
  end

  def search(object, index) when is_map(object) and is_binary(index) do
    search_execute(object, index, [])
  end

  def search(object, opts) when is_map(object) do
    search(object, opts[:index], opts)
  end

  def search(object, index, opts) when is_map(object) and (is_binary(index) or is_atom(index)) do
    search_execute(object, index, opts)
  end

  defp search_maybe_with_facets(string, opts, calculate_facets)
       when not is_nil(calculate_facets) do
    # opts = Map.merge(%{
    #   facetDistribution: ["*"]
    # }, opts)

    search(string, opts)
  end

  defp search_maybe_with_facets(string, opts, _) do
    search(string, opts)
  end

  def facet_from_map({key, values}) when is_list(values) do
    Enum.map(values, &facet_from_map({key, &1}))
  end

  def facet_from_map({key, value}) when is_binary(value) or is_atom(value) do
    "#{key} = #{value}"
  end

  defp search_execute(%{} = params, index, opts) do
    # IO.inspect(search_params: params)
    opts = to_options(opts)

    with {:ok, %{body: %{"hits" => hits} = result}} when is_list(hits) and hits != [] <-
           api(:post, params, Indexer.index_name(index || :public) <> "/search") do
      result =
        result
        |> debug("did_meili")
        |> Map.drop(["hits"])
        |> input_to_atoms(to_snake: true)

      hits
      # return object-like results
      |> Enum.map(fn hit ->
        object =
          hit
          |> input_to_atoms()
          |> maybe_to_structs()

        id = id(object)

        %Needle.Pointer{
          id: id,
          activity:
            object
            |> Map.merge(%{object: object, object_id: id})
            |> maybe_to_struct(Bonfire.Data.Social.Activity)
        }
      end)
      |> debug("did_structs")
      |> Bonfire.Social.Activities.activity_preloads(
        [
          # :with_object_posts, 
          # :with_subject, 
          :with_reply_to
          # :tags
        ],
        opts
      )
      |> Map.put(result, :hits, ...)
    else
      {:ok, %{body: result}} ->
        debug("no hits")

        result
        |> input_to_atoms(to_snake: true)

      e ->
        error(e, "Could not search Meili")
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

  def list_facets(index \\ nil) do
    get(nil, Indexer.index_name(index || :public) <> "/settings/filterable-attributes")
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

  def put_documents(object, index_name \\ "") do
    put(object, index_name <> "/documents")
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
    if is_binary(object) do
      api(:delete, nil, "#{index_path}/documents/#{object}", fail_silently)
      # api(:delete, %{id: object}, index_path, fail_silently)
    else
      if object == :all do
        api(:delete, nil, "#{index_path}/documents", fail_silently)
      else
        api(:delete, object, index_path, fail_silently)
      end
    end
  end

  def settings(object, index) do
    patch(object, index <> "/settings")
  end

  def api(http_method, object, index_path, fail_silently \\ false) do
    url =
      "/indexes/#{index_path}"
      |> debug()

    do_api(http_method, object, url, fail_silently)
  end

  defp do_api(http_method, object, url, fail_silently \\ false) do
    search_instance = Bonfire.Common.Config.get_ext!(:bonfire_search, :instance)
    api_key = Bonfire.Common.Config.get_ext!(:bonfire_search, :api_key)
    url = "#{search_instance}#{url}"

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

  def wait_for_task(taskUid, backoff \\ 500)

  def wait_for_task(%{body: %{"taskUid" => taskUid}}, backoff),
    do: wait_for_task(taskUid, backoff)

  def wait_for_task(taskUid, backoff) do
    case do_api(:get, nil, "/tasks/#{taskUid}") do
      {:error, error} ->
        {:error, error}

      {:ok, %{body: %{"status" => "succeeded"} = task}} ->
        {:ok, task}

      {:ok, %{body: %{"status" => "failed"} = task}} ->
        error("Meilisearch task failed", task)

      {:ok, %{body: %{"status" => "canceled"} = task}} ->
        error("Meilisearch task was canceled", task)

      {:ok, task} ->
        debug(task, "Wait for Meili")
        Process.sleep(backoff)
        wait_for_task(taskUid, backoff * 2)
    end
  end
end
