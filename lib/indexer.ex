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

  def maybe_index_object(object, index \\ nil) do
    indexable_object =
      maybe_indexable_object(object)
      |> filter_empty(nil)
      |> debug("filtered")

    if not is_nil(indexable_object) do
      if index do
        do_index_object(indexable_object, index)
      else
        do_index_object(indexable_object, :public)
      end
    end
  end

  def maybe_indexable_object(nil) do
    nil
  end

  def maybe_indexable_object(%{"index_type" => index_type} = object)
      when not is_nil(index_type) do
    # already formatted indexable object
    object
  end

  def maybe_indexable_object(%{"id" => id} = object)
      when not is_nil(id) do
    # hopefully already formatted indexable object
    object
  end

  def maybe_indexable_object(%Bonfire.Data.Identity.User{} = object) do
    maybe_indexable_and_discoverable(object, object)
  end

  def maybe_indexable_object(%{subject: %{id: _} = creator} = object) do
    maybe_indexable_and_discoverable(creator, object)
  end

  def maybe_indexable_object(%{subject: %{character: %{id: _} = creator}} = object) do
    maybe_indexable_and_discoverable(creator, object)
  end

  def maybe_indexable_object(%{creator: %{id: _} = creator} = object) do
    maybe_indexable_and_discoverable(creator, object)
  end

  def maybe_indexable_object(%{created: %{creator: %{id: _} = creator}} = object) do
    maybe_indexable_and_discoverable(creator, object)
  end

  def maybe_indexable_object(%{activity: %{created: %{creator: %{id: _} = creator}}} = object) do
    maybe_indexable_and_discoverable(creator, object)
  end

  def maybe_indexable_object(
        %{activity: %{object: %{created: %{creator: %{id: _} = creator}}}} = object
      ) do
    maybe_indexable_and_discoverable(creator, object)
  end

  def maybe_indexable_object(%{object: %{created: %{creator: %{id: _} = creator}}} = object) do
    maybe_indexable_and_discoverable(creator, object)
  end

  def maybe_indexable_object(%Needle.Pointer{} = pointer) do
    Bonfire.Common.Needles.get(pointer)
    |> maybe_indexable_object()
  end

  def maybe_indexable_object(%{__struct__: _} = object) do
    warn(
      "Could not identify creator to determine if they allow discoverability. Indexing by default..."
    )

    do_indexable_object(object)
  end

  def maybe_indexable_object(objects) when is_list(objects) do
    Enum.map(objects, &maybe_indexable_object/1)
  end

  def maybe_indexable_object(obj) do
    warn(
      obj,
      "Could not index object (not pre-formated for indexing or not a struct)"
    )

    nil
  end

  def maybe_indexable_and_discoverable(creator, object) do
    if Bonfire.Common.Extend.module_enabled?(
         Bonfire.Search.Indexer,
         creator
       ),
       do: do_indexable_object(object)

    # !Bonfire.Common.Settings.get([Bonfire.Me.Users, :undiscoverable], false,
    #      current_user: creator
    #    ),
  end

  defp do_indexable_object(%{__struct__: object_type} = object) do
    Bonfire.Common.ContextModule.maybe_apply(
      object_type,
      :indexing_object_format,
      object
    )
  end

  # add to general instance search index
  defp do_index_object(object, index) do
    # IO.inspect(search_indexing: objects)
    # FIXME - should create the index only once
    index_objects(object, index, index_name(index), true)
  end

  # index several things in an existing index
  defp index_objects(objects, index, index_name, init_index_first \\ false)

  defp index_objects(objects, index, index_name, init_index_first)
       when is_list(objects) do
    adapter = adapter()

    # FIXME: should check if enabled for creator
    if module_enabled?(__MODULE__) and module_enabled?(adapter) do
      if init_index_first, do: init_index(index, index_name, true, adapter)

      objects
      # |> debug("filtered")
      |> adapter.put(index_name <> "/documents")
      |> debug("result of PUT")
    end
  end

  # index something in an existing index
  defp index_objects(object, index, index_name, init_index_first) do
    adapter = adapter()

    if init_index_first, do: init_index(index, index_name, true, adapter)

    index_objects([object], index, index_name, false)
  end

  # create a new index
  def init_index(index \\ nil, index_name \\ nil, fail_silently \\ false, adapter \\ adapter())

  def init_index(index, index_name, fail_silently, adapter)
      when index in [:public, :private, "public", "private", nil] do
    if adapter do
      index_name = index_name || index_name(index) || index_name(:public)

      adapter.create_index(index_name, fail_silently)

      # define facets to be used for filtering main search index
      adapter.set_facets(index_name, @main_facets)
      adapter.set_searchable_fields(index_name, @main_searcheable_fields)
    end
  end

  def init_index(index, index_name, fail_silently, adapter) do
    if adapter do
      adapter.create_index(index_name || index_name(index), fail_silently)
    end
  end

  def maybe_delete_object(object, index \\ nil)

  def maybe_delete_object(object, nil) do
    object = uid(object)
    delete_object(object, index_name(:private))
    delete_object(object, index_name(:public))
  end

  def maybe_delete_object(object, index) do
    delete_object(uid(object), index_name(index || :public))
  end

  defp delete_object(nil, _) do
    warn("Couldn't get object ID in order to delete")
  end

  defp delete_object(object_id, index_name) do
    adapter().delete(object_id, index_name)
    |> debug()
  end

  def host(url) when is_binary(url) do
    URI.parse(url).host
  end

  def host(_) do
    ""
  end
end
