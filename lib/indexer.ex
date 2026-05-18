# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Indexer do
  import Untangle
  import Bonfire.Search, only: [adapter: 0]
  use Bonfire.Common.Utils
  use Bonfire.Common.Localise
  use Bonfire.Common.Config

  @main_indexes [:public, :closed]
  @main_indexes_aliases [:public, :closed, "public", "closed", nil]

  def main_facets,
    do:
      Bonfire.Common.Config.get(
        [__MODULE__, :main_facets],
        ["index_type", "index_instance", "tags", "character.is_remote"],
        name: l("Search indexing"),
        description: l("Facets")
      )

  def main_searcheable_fields,
    do:
      Bonfire.Common.Config.get(
        [__MODULE__, :main_searcheable_fields],
        [
          #  NOTE: does this mean we can avoid using the URL db-based lookup in LiveHandler
          "character.username",
          "character.url",
          "profile.name",
          "profile.summary",
          "profile.website",
          "profile.location",
          "post_content.name",
          "post_content.summary",
          "post_content.html_body",
          "tags"
        ],
        name: l("Search indexing"),
        description: l("Default searchable fields")
      )


  def index_name(name), do: "#{Config.env()}_#{name}"

  @doc """
  Main entry point for indexing. Either queues the document for batched indexing
  (if the adapter opts in via `batch_indexing?/0`) or indexes synchronously.
  Pass `wait_for_indexing: true` in config to force the synchronous path (useful in tests).
  """
  def maybe_queue_or_index(object, index \\ nil, adapter \\ adapter()) do

    if !adapter do
      error("No adapter configured for indexing")
    else
      wait? = Bonfire.Common.Config.get([:bonfire_search, :wait_for_indexing]) == true
      batched? = !wait? and batch_indexing?(adapter)

      if batched? do
        case prepare_indexable_object(object) do
          doc when is_map(doc) ->
            with {:ok, _job} <- Bonfire.Search.Workers.IndexWorker.enqueue(index, doc) do
              {:ok, :queued}
            end

          _ ->
            error(object, "Search: nothing indexable to enqueue, skipping")
        end
      else
        maybe_index_object(object, index, adapter)
      end
    end
  end

  defp batch_indexing?(adapter \\ adapter()) do
    function_exported?(adapter, :batch_indexing?, 0) and adapter.batch_indexing?()
  end

  def maybe_index_object(nil, _, _), do: error("object is nil, skipping indexing")
  def maybe_index_object(nil), do: error("object is nil, skipping indexing")

  def maybe_index_object(object, index \\ nil, adapter \\ adapter()) do

    indexable_object =
      prepare_indexable_object(object)
      |> filter_empty(nil)
      |> debug("prepared")

    if indexable_object do
      index = index || :public
      debug(index, "attempt indexing in")
      do_index_object(indexable_object, index, adapter)
    else
      error(
        object,
        "prepare_indexable_object didn't return an object for this input, skipping indexing"
      )
    end
  end

  @doc """
  Format an object (or list) into the map(s) sent to the search index.

  Public so the batched indexer (`Bonfire.Search.Workers.IndexWorker`) can put
  the *final* indexable map in the Oban job. Already-formatted maps (those
  carrying `"id"` or `"index_type"`) pass through unchanged, so re-feeding a
  buffered doc through `maybe_index_object/2` in the worker is a safe no-op.
  """
  def prepare_indexable_object(%{"index_type" => index_type} = object)
      when not is_nil(index_type) do
    # already formatted indexable object
    object
  end

  def prepare_indexable_object(%{"id" => id} = object)
      when not is_nil(id) do
    # hopefully already formatted indexable object
    object
  end

  def prepare_indexable_object(%{__struct__: object_type} = object) do
    Bonfire.Common.ContextModule.maybe_apply(
      object_type,
      :indexing_object_format,
      object
    )
  end

  def prepare_indexable_object(objects) when is_list(objects) do
    Enum.map(objects, &prepare_indexable_object/1)
  end

  def prepare_indexable_object(_) do
    nil
  end

  # add to general instance search index
  def init_indexes_on_startup do
    if adapter = adapter() do
      Task.start(fn -> await_and_init(adapter, 1_000) end)
    end
  end

  defp await_and_init(adapter, backoff) do
    if adapter.healthy?() do
      info("Initializing search indexes")

      for index <- @main_indexes do
        init_index(index)
      end

      # fail loud if the queue isn't configured: otherwise index jobs are
      # inserted but never processed, and nothing gets indexed — silently.
      # (No explicit drain needed: Oban durably persists jobs and resumes any
      # scheduled/available ones automatically after a restart.)
      unless Bonfire.Search.Workers.IndexWorker.queue_configured?() do
        error(
          "Bonfire.Search: the `search_index` Oban queue is NOT configured — index jobs will never be processed. Add `search_index: <n>` to `config :bonfire, Oban, queues`."
        )
      end
    else
      warn("Search service not ready, retrying in #{backoff}ms")
      Process.sleep(backoff)
      await_and_init(adapter, min(backoff * 2, 30_000))
    end
  end

  defp do_index_object(object, index, adapter) do
    with {:ok, task} <-
           index_objects(object, index, index_name(index), adapter)
           |> debug("queued?") do
      if Bonfire.Common.Config.get([:bonfire_search, :wait_for_indexing])
         |> debug("wait_for_indexing?") do
        adapter.wait_for_task(task) |> debug("indexed?")
      else
        {:ok, task}
      end
    end
  end

  defp index_objects(objects, index, index_name, adapter \\ adapter())

  # index several things in an index
  defp index_objects(objects, index, index_name, adapter)
       when is_list(objects) do
    if adapter do
      # FIXME: should check if enabled for creator? or we already doing that in indexable_object?
      if module_enabled?(__MODULE__) do
        maybe_init_index(index, index_name, adapter)

        objects
        # |> debug("filtered")
        |> adapter.put_documents(index_name)
        # |> adapter.put(index_name <> "/documents")
        |> debug("result of PUT")
      else
        error(adapter, "Adapter not enabled for indexing")
      end
    else
      error("No adapter configured for indexing")
    end
  end

  # index a thing in an index
  defp index_objects(object, index, index_name, adapter) do
    index_objects([object], index, index_name, adapter)
  end

  # Init custom indexes on first use; standard ones are initialized once at startup
  defp maybe_init_index(index, index_name, adapter)
       when index not in @main_indexes_aliases,
       do: init_index(index, index_name, true, adapter)

  defp maybe_init_index(_index, _index_name, _adapter), do: :skip

  # create a new index
  def init_index(index \\ nil, index_name \\ nil, fail_silently \\ false, adapter \\ adapter())

  def init_index(index, index_name, fail_silently, adapter)
      when index in @main_indexes_aliases do
    if adapter do
      index_name = index_name || index_name(index) || index_name(:public)

      adapter.create_index(index_name, fail_silently)

      desired_facets = main_facets()

      facet_task =
        case adapter.list_facets(index_name) do
          {:ok, current} when is_list(current) ->
            if Enum.sort(current) == Enum.sort(desired_facets) do
              debug(index_name, "facets unchanged, skipping update")
              nil
            else
              adapter.set_facets(index_name, desired_facets)
            end

          other ->
            # fail safe: a settings *read* error/unexpected shape must NOT
            # cause an unconditional set, which would force a full reindex
            warn(
              other,
              "Could not read current facets for #{index_name}; skipping set to avoid an unintended full reindex"
            )

            nil
        end

      desired_searchable = main_searcheable_fields()

      searchable_task =
        case adapter.list_searchable_fields(index_name) do
          {:ok, current} when is_list(current) ->
            if Enum.sort(current) == Enum.sort(desired_searchable) do
              debug(index_name, "searchable fields unchanged, skipping update")
              nil
            else
              adapter.set_searchable_fields(index_name, desired_searchable)
            end

          other ->
            # fail safe: see note above — never set on a read error/odd shape
            warn(
              other,
              "Could not read current searchable fields for #{index_name}; skipping set to avoid an unintended full reindex"
            )

            nil
        end

      [facet_task, searchable_task]
      |> Enum.reject(&is_nil/1)
    end
  end

  def init_index(index, index_name, fail_silently, adapter) do
    if adapter do
      adapter.create_index(index_name || index_name(index), fail_silently)
    end
  end

  def maybe_delete_object(object, index \\ nil, adapter \\ adapter())

  def maybe_delete_object(object, nil, adapter) do
    Bonfire.Common.Enums.all_oks_or_error(maybe_delete_object_all_indexes(object, adapter))
  end

  def maybe_delete_object(object, index, adapter) do
    delete_object(uid(object), index_name(index || :public), adapter)
  end

  def maybe_delete_object_all_indexes(object, adapter \\ adapter()) do
    object = uid(object)
    [delete_object(object, index_name(:closed), adapter), delete_object(object, index_name(:public), adapter)]
  end

  defp delete_object(nil, _, _) do
    warn("Couldn't get object ID in order to delete")
  end

  defp delete_object(object_id, index_name, adapter) do
    if adapter do
      with {:ok, task} <- adapter.delete(object_id, index_name) do
      if Bonfire.Common.Config.get([:bonfire_search, :wait_for_indexing])
           |> debug("wait_for_indexing?") do
          adapter.wait_for_task(task)
        else
          {:ok, task}
        end
      end
    else
      error("No adapter configured for deleting")
    end
  end

  def host(url) when is_binary(url) do
    URI.parse(url).host
  end

  def host(_) do
    ""
  end
end
