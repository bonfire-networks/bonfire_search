# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Indexer do
  import Untangle
  import Bonfire.Search, only: [adapter: 0]

  # TODO: put in config
  @main_facets ["index_type", "index_instance", "tags"]
  @main_searcheable_fields [
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
  ]

  use Bonfire.Common.Utils

  def index_name(name), do: "#{Config.env()}_#{name}"

  def maybe_index_object(nil) do
    error("object is nil, skipping indexing")
  end

  def maybe_index_object(object, index \\ nil) do
    indexable_object =
      prepare_indexable_object(object)
      |> filter_empty(nil)
      |> debug("prepared")

    if indexable_object do
      if index do
        debug(index, "attempt indexing in")
        do_index_object(indexable_object, index)
      else
        debug("attempt indexing in :public index")
        do_index_object(indexable_object, :public)
      end
    else
      error(
        object,
        "prepare_indexable_object didn't return an object for this input, skipping indexing"
      )
    end
  end

  defp prepare_indexable_object(%{"index_type" => index_type} = object)
       when not is_nil(index_type) do
    # already formatted indexable object
    object
  end

  defp prepare_indexable_object(%{"id" => id} = object)
       when not is_nil(id) do
    # hopefully already formatted indexable object
    object
  end

  defp prepare_indexable_object(%{__struct__: object_type} = object) do
    Bonfire.Common.ContextModule.maybe_apply(
      object_type,
      :indexing_object_format,
      object
    )
  end

  defp prepare_indexable_object(objects) when is_list(objects) do
    Enum.map(objects, &prepare_indexable_object/1)
  end

  defp prepare_indexable_object(_) do
    nil
  end

  # add to general instance search index
  defp do_index_object(object, index) do
    # IO.inspect(search_indexing: objects)
    # FIXME - should create the index only once
    if adapter = adapter() do
      with {:ok, task} <-
             index_objects(object, index, index_name(index), true, adapter) |> debug("queued?") do
        if Bonfire.Common.Config.get_ext(:bonfire_search, :wait_for_indexing)
           |> debug("wait_for_indexing?") do
          adapter.wait_for_task(task) |> debug("indexed?")
        else
          {:ok, task}
        end
      end
    else
      error("No adapter configured for indexing")
    end
  end

  # index several things in an existing index
  defp index_objects(objects, index, index_name, init_index_first \\ false, adapter \\ nil)

  defp index_objects(objects, index, index_name, init_index_first, adapter)
       when is_list(objects) do
    if adapter = adapter || adapter() do
      # FIXME: should check if enabled for creator? or we already doing that in indexable_object?
      if module_enabled?(__MODULE__) do
        if init_index_first, do: init_index(index, index_name, true, adapter)

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

  # index something in an existing index
  defp index_objects(object, index, index_name, init_index_first, adapter) do
    if adapter = adapter || adapter() do
      if init_index_first, do: init_index(index, index_name, true, adapter)

      index_objects([object], index, index_name, false)
    end
  end

  # create a new index
  def init_index(index \\ nil, index_name \\ nil, fail_silently \\ false, adapter \\ nil)

  def init_index(index, index_name, fail_silently, adapter)
      when index in [:public, :closed, "public", "closed", nil] do
    if adapter = adapter || adapter() do
      index_name = index_name || index_name(index) || index_name(:public)

      adapter.create_index(index_name, fail_silently)

      # define facets to be used for filtering main search index
      adapter.set_facets(index_name, @main_facets)
      adapter.set_searchable_fields(index_name, @main_searcheable_fields)
    end
  end

  def init_index(index, index_name, fail_silently, adapter) do
    if adapter = adapter || adapter() do
      adapter.create_index(index_name || index_name(index), fail_silently)
    end
  end

  def maybe_delete_object(object, index \\ nil)

  def maybe_delete_object(object, nil) do
    Bonfire.Common.Enums.all_oks_or_error(maybe_delete_object_all_indexes(object))
  end

  def maybe_delete_object(object, index) do
    delete_object(uid(object), index_name(index || :public))
  end

  def maybe_delete_object_all_indexes(object) do
    object = uid(object)
    [delete_object(object, index_name(:closed)), delete_object(object, index_name(:public))]
  end

  defp delete_object(nil, _) do
    warn("Couldn't get object ID in order to delete")
  end

  defp delete_object(object_id, index_name) do
    if adapter = adapter() do
      with {:ok, task} <- adapter.delete(object_id, index_name) do
        if Bonfire.Common.Config.get_ext(:bonfire_search, :wait_for_indexing)
           |> debug("wait_for_indexing?") do
          adapter.wait_for_task(task)
        else
          {:ok, task}
        end
      end
    end
  end

  def host(url) when is_binary(url) do
    URI.parse(url).host
  end

  def host(_) do
    ""
  end
end
