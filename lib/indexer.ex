# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Indexer do
  import Where
  import Bonfire.Search, only: [adapter: 0]

  @public_index "public"
  # TODO: put in config
  @public_facets ["index_type", "index_instance", "tags"]
  @public_searcheable_fields ["character.username", "profile.name", "post_content.name", "post_content.summary", "tags", "post_content.html_body"]

  use Bonfire.Common.Utils, only: [maybe_get: 2, maybe_get: 3, ulid: 1]

  def maybe_index_object(object) do
    indexable_object = maybe_indexable_object(object)

    if !is_nil(indexable_object) do
      index_public_object(indexable_object)
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
  def maybe_indexable_object(%{activity: %{object: %{created: %{creator: %{id: _} = creator}}}} = object) do
    maybe_indexable_and_discoverable(creator, object)
  end
  def maybe_indexable_object(%{object: %{created: %{creator: %{id: _} = creator}}} = object) do
    maybe_indexable_and_discoverable(creator, object)
  end

  def maybe_indexable_object(%Pointers.Pointer{} = pointer) do
    Bonfire.Common.Pointers.get(pointer)
    |> maybe_indexable_object()
  end

  def maybe_indexable_object(%{__struct__: _} = object) do
    warn("Could not identify creator to determine if they allow discoverability. Indexing by default...")
    do_indexable_object(object)
  end

  def maybe_indexable_object(obj) do
    warn(obj, "Could not index object (not pre-formated for indexing or not a struct)")
    nil
  end

  def maybe_indexable_and_discoverable(creator, object) do
    if Bonfire.Me.Settings.get([Bonfire.Me.Users, :discoverable], true, current_user: creator), do: do_indexable_object(object)
  end

  defp do_indexable_object(%{__struct__: object_type} = object) do
    Bonfire.Common.ContextModules.maybe_apply(
      object_type,
      :indexing_object_format,
      object
    )
  end

  # add to general instance search index
  def index_public_object(object) do
    # IO.inspect(search_indexing: objects)
    index_objects(object, @public_index, true)
  end

  # index several things in an existing index
  def index_objects(objects, index_name, init_index_first \\ true)

  def index_objects(objects, index_name, init_index_first) when is_list(objects) do
    # IO.inspect(objects)
    disabled = Bonfire.Common.Config.get_ext(:bonfire_search, :disable_indexing)
    if disabled != "true" and disabled != true do
      # FIXME - should create the index only once
      if init_index_first, do: init_index(index_name, true)

      adapter().put(objects, index_name <> "/documents")
    end
  end

  # index something in an existing index
  def index_objects(object, index_name, init_index_first) do
    # IO.inspect(object)
    index_objects([object], index_name, init_index_first)
  end

  # create a new index
  def init_index(index_name \\ "public", fail_silently \\ false)

  def init_index("public" = index_name, fail_silently) do
    adapter().create_index(index_name, fail_silently)

    # define facets to be used for filtering main search index
    adapter().set_facets(index_name, @public_facets)
    adapter().set_searchable_fields(index_name, @public_searcheable_fields)
  end

  def init_index(index_name, fail_silently) do
    adapter().create_index(index_name, fail_silently)
  end

  def maybe_delete_object(object, index_name \\ "public") do
    delete_object(ulid(object), index_name)
    :ok
  end

  defp delete_object(nil, _) do
    warn("Couldn't get object ID in order to delete")
  end

  defp delete_object(object_id, index_name) do
    adapter().delete(object_id, index_name)
  end

  def host(url) when is_binary(url) do
    URI.parse(url).host
  end

  def host(_) do
    ""
  end


end
