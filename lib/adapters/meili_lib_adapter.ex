# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.MeiliLib do
  import Untangle
  use Bonfire.Common.Utils
  alias Bonfire.Search.Indexer

  alias Meilisearch.{Client, Document, Index, Settings}
  alias Meilisearch.Settings.{Faceting, FilterableAttributes, SearchableAttributes}

  @behaviour Bonfire.Search.Adapter

  def search_by_type(tag_search, facets \\ nil) do
    facets = search_type_facets(facets)
    debug("search: #{inspect(tag_search)} with facets #{inspect(facets)}")

    search = search(tag_search, %{}, false, facets)

    e(search, :hits, [])
    |> Enums.filter_empty([])
  end

  defp search_type_facets(facets) when is_list(facets) or is_binary(facets) do
    %{
      "index_type" => List.wrap(facets) |> Enum.map(&Types.module_to_str/1)
    }
  end

  defp search_type_facets(facet) when is_atom(facet) and not is_nil(facet) do
    search_type_facets([facet])
  end

  defp search_type_facets(nil), do: nil

  def search(string, opts, calculate_facets, filter_facets)
      when is_map(filter_facets) do
    search(
      string,
      opts,
      calculate_facets,
      Enum.map(filter_facets, &facet_from_map/1)
      |> Enum.reject(&is_nil/1)
      |> debug("filter_facets")
    )
  end

  def search(string, opts, calculate_facets, filter_facets)
      when is_list(filter_facets) do
    search_maybe_with_facets(
      string,
      opts
      |> Enum.into(%{
        filter: List.flatten(filter_facets)
      })
      |> debug("opts_with_filter"),
      calculate_facets
    )
  end

  def search(string, opts, calculate_facets, _) do
    search_maybe_with_facets(string, opts, calculate_facets)
  end

  def search(string, index) when is_binary(string) and (is_binary(index) or is_atom(index)) do
    search(%{q: string}, index)
  end

  def search(string, %{index: index} = opts)
      when is_binary(string) and (is_binary(index) or is_atom(index)) do
    # FIXME: use an allow-list instead
    search_params =
      Map.drop(opts, [:current_user, :context, :index, :skip_boundary_check])
      |> Enum.into(%{q: string})

    search(search_params, index, opts)
  end

  def search(string, opts) when is_binary(string) and (is_map(opts) or is_list(opts)) do
    # FIXME: use an allow-list instead
    search_params =
      Enums.fun(opts, :drop, [[:current_user, :context, :index, :skip_boundary_check]])
      |> Enum.into(%{q: string})

    search(search_params, opts[:index], opts)
  end

  def search(object, index) when is_map(object) and (is_binary(index) or is_atom(index)) do
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
    # TODO?
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
    |> Enum.reject(&is_nil/1)
  end

  def facet_from_map({_key, ""}) do
    nil
  end

  def facet_from_map({key, value}) when is_binary(value) or is_atom(value) do
    "#{key} = #{value}"
  end

  defp search_execute(params, index, opts) do
    opts = to_options(opts)
    client = get_client()
    index = index || :public
    index_name = Indexer.index_name(index)

    case Meilisearch.Search.search(client, index_name, Keyword.new(params) |> debug("params")) do
      {:ok, %{hits: hits} = result} when is_list(hits) and hits != [] ->
        result =
          result
          |> debug("searched meili in #{index}")
          |> Map.drop([:hits])

        # |> input_to_atoms(to_snake: true)          

        Map.put(result, :hits, Bonfire.Search.prepare_hits(hits, index, opts))

      {:ok, result} ->
        debug(result, "no hits in `#{index_name}` index")
        result

      {:error,
       %Meilisearch.Error{
         message: msg,
         code: :index_not_found
       } = error} ->
        warn(error, msg)
        %{hits: []}

      {:error,
       %Meilisearch.Error{
         message: msg,
         code: code
       } = error} ->
        error(error, msg)

      error ->
        error(error, "There was an unexpected error when searching")
    end
  end

  def index_exists(index_name) do
    client = get_client()

    case Index.get(client, index_name) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def create_index(index_name, _fail_silently \\ false) do
    client = get_client()
    Index.create(client, %{uid: index_name})
  end

  def list_facets(index \\ nil) do
    client = get_client()
    index_name = Indexer.index_name(index || :public)
    FilterableAttributes.get(client, index_name)
  end

  def set_facets(index_name, facets) when is_list(facets) do
    client = get_client()
    FilterableAttributes.update(client, index_name, facets)
  end

  def set_facets(index_name, facet) do
    set_facets(index_name, [facet])
  end

  def set_searchable_fields(index_name, fields) do
    client = get_client()
    SearchableAttributes.update(client, index_name, fields)
  end

  def put_documents(object, index_name \\ "") do
    client = get_client()
    Document.create_or_update(client, index_name, object)
  end

  def delete(object, index_name \\ "") do
    client = get_client()

    cond do
      is_binary(object) ->
        Document.delete_one(client, index_name, object)

      object == :all ->
        Document.delete_all(client, index_name)

      true ->
        case Enums.id(object) do
          nil -> error(object, "Dunno what to delete")
          object -> Document.delete_one(client, index_name, object)
        end
    end
  end

  def settings(object, index) do
    client = get_client()
    Settings.update(client, index, object)
  end

  def get_client do
    search_instance = Bonfire.Common.Config.get_ext!(:bonfire_search, :instance)
    api_key = Bonfire.Common.Config.get_ext!(:bonfire_search, :api_key)

    Client.new(endpoint: search_instance, key: api_key, finch: Bonfire.Finch)
  end

  def wait_for_task(client \\ nil, taskUid, backoff \\ 500)

  def wait_for_task(client, tasks, backoff) when is_list(tasks) do
    Enum.map(tasks, &wait_for_task(client, &1, backoff))
  end

  def wait_for_task(client, {:ok, task}, backoff) do
    wait_for_task(client, task, backoff)
  end

  def wait_for_task(_client, %{status: :succeeded} = task, _backoff), do: {:ok, task}

  def wait_for_task(client, %{taskUid: taskUid}, backoff),
    do: wait_for_task(client, taskUid, backoff)

  def wait_for_task(client, taskUid, backoff) when is_number(taskUid) do
    case Meilisearch.Task.get(client || get_client(), taskUid) do
      {:error, error} ->
        {:error, error}

      {:ok, %Meilisearch.Task{status: :succeeded} = task} ->
        {:ok, task}

      {:ok, %Meilisearch.Task{status: :failed} = task} ->
        error(task, "Meilisearch task failed")

      {:ok, %Meilisearch.Task{status: :canceled} = task} ->
        error(task, "Meilisearch task was canceled")

      {:ok, _task} ->
        Process.sleep(backoff)
        wait_for_task(client, taskUid, backoff * 2)
    end
  end
end
