defmodule Bonfire.Search.HashtagIndexTest do
  @moduledoc "Hashtags in the search index: in their own bucket only, so they don't rank among posts in the mixed one, and added by a reindex."
  use Bonfire.Search.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Search

  @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)
  @hashtag_type "Bonfire.Tag.Hashtag"

  setup do
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)
    prev = prepare_indexes_for_tests(@adapter)

    on_exit(fn ->
      reset_indexes_after_tests(@adapter, prev)
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    :ok
  end

  # raw, so it reads what the index holds
  defp in_index?(term, object, filter_facets) do
    Search.search(term, %{index: "public", raw: true}, [], filter_facets)
    |> e(:hits, [])
    |> List.wrap()
    |> Enum.any?(&(Enums.id(&1) == Enums.id(object)))
  end

  test "a created hashtag is in the Hashtag bucket and not in the mixed one" do
    assert {:ok, hashtag} = Bonfire.Tag.get_or_create_hashtag("zebrafinch")

    assert in_index?("zebrafinch", hashtag, %{"index_type" => @hashtag_type})
    refute in_index?("zebrafinch", hashtag, nil)
  end

  # a delete has to reach the bucket of every type, including those only in their own bucket
  test "a hashtag taken out of the index leaves its bucket" do
    assert {:ok, hashtag} = Bonfire.Tag.get_or_create_hashtag("godwitwatch")
    assert in_index?("godwitwatch", hashtag, %{"index_type" => @hashtag_type})

    Bonfire.Search.maybe_unindex(hashtag)

    refute in_index?("godwitwatch", hashtag, %{"index_type" => @hashtag_type})
  end

  test "a hashtag made before indexing was on is found after a reindex" do
    # `ProcessTree` treats a stored nil as unset, so `false` stands for "no adapter"
    Process.put([:bonfire_search, :adapter], false)
    refute Bonfire.Search.adapter()

    assert {:ok, hashtag} = Bonfire.Tag.get_or_create_hashtag("kestrelwatch")

    Process.delete([:bonfire_search, :adapter])
    assert Bonfire.Search.adapter()

    refute in_index?("kestrelwatch", hashtag, %{"index_type" => @hashtag_type}),
           "control: it was made with no index"

    assert :ok = Bonfire.Search.Indexer.reindex_from_db(only: Bonfire.Tag.Reindex, async: false)

    assert in_index?("kestrelwatch", hashtag, %{"index_type" => @hashtag_type})
  end
end
