defmodule Bonfire.Search.GroupIndexTest do
  @moduledoc "Groups in the search index under the Category type: found by name, summary and handle, gone once archived, and added by a reindex."
  use Bonfire.Search.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Search

  @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)
  @category_type "Bonfire.Classify.Category"

  setup do
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)
    prev = prepare_indexes_for_tests(@adapter)

    on_exit(fn ->
      reset_indexes_after_tests(@adapter, prev)
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    :ok
  end

  # searches the Category type only, which is the bucket (Sonic) or facet (Meili) that group autocomplete and the Groups tab read. Raw, so it sees what the index holds: Sonic's loaded hits go through their pointers, which leave an archived group out even while the index still holds it
  defp in_category_index?(term, group) do
    hits =
      Search.search(term, %{index: "public", raw: true}, [], %{"index_type" => @category_type})
      |> e(:hits, [])

    Enum.any?(List.wrap(hits), &(Enums.id(&1) == Enums.id(group)))
  end

  defp public_group!(user, attrs) do
    Bonfire.Classify.Simulate.fake_group!(
      user,
      Map.merge(
        %{membership: "open", visibility: "global", participation: "anyone"},
        attrs
      )
    )
  end

  test "a group is found by its name, summary and handle under the Category type, and not once archived" do
    user = fake_user!()

    group =
      public_group!(user, %{
        name: "Zebrafinch makers",
        summary: "We build nestboxes for songbirds",
        username: "finchwrights"
      })

    assert in_category_index?("zebrafinch", group)
    assert in_category_index?("nestboxes", group)
    assert in_category_index?("finchwrights", group)

    assert {:ok, _} = Bonfire.Classify.Categories.soft_delete(group, user)

    refute in_category_index?("zebrafinch", group)
  end

  # every type that is indexed has its own bucket, so a delete must reach each of them, not only a hand-kept few
  test "a deleted article no longer shows in an Article-type search" do
    user = fake_user!()
    article_type = "Bonfire.Articles.Article"

    {:ok, article} =
      Bonfire.Articles.publish(
        current_user: user,
        boundary: "public",
        post_attrs: %{
          post_content: %{name: "Godwit migrations", html_body: "Godwit tracking notes"}
        }
      )

    in_article_index? = fn ->
      Search.search("godwit", %{index: "public", raw: true}, [], %{"index_type" => article_type})
      |> e(:hits, [])
      |> List.wrap()
      |> Enum.any?(&(Enums.id(&1) == Enums.id(article)))
    end

    assert in_article_index?.()

    assert {:ok, _} = Bonfire.Articles.delete(article, current_user: user)

    refute in_article_index?.()
  end

  describe "Categories.search_groups/2" do
    test "returns the groups and topics the viewer may see, in the index's order, without labels, archived groups or other people's hidden groups" do
      me = fake_user!()
      other = fake_user!()

      mine = public_group!(me, %{name: "Shrike makers"})
      theirs = public_group!(other, %{name: "Shrike watchers"})

      topic =
        Bonfire.Classify.Simulate.fake_category!(me, mine, %{name: "Shrike care", type: :topic})

      label =
        Bonfire.Classify.Simulate.fake_category!(me, nil, %{name: "Shrike label", type: :label})

      hidden =
        Bonfire.Classify.Simulate.fake_group!(other, %{
          name: "Shrike secrets",
          membership: "invite_only",
          visibility: "members:private",
          participation: "group_members"
        })

      archived = public_group!(me, %{name: "Shrike archive"})
      assert {:ok, _} = Bonfire.Classify.Categories.soft_delete(archived, me)

      # a page that holds every hit, since the test page size is 2 and the label (and on Sonic, the archived group's stale copy in the Category bucket, see the archive test above) take places that are then dropped
      assert %{edges: found} =
               Bonfire.Classify.Categories.search_groups("shrike", current_user: me, limit: 10)

      found_ids = Enums.ids(found)

      for expected <- [mine, theirs, topic], do: assert(Enums.id(expected) in found_ids)
      for unwanted <- [label, hidden, archived], do: refute(Enums.id(unwanted) in found_ids)

      index_order =
        Search.search("shrike", %{index: "public", raw: true, limit: 10}, [], %{
          "index_type" => @category_type
        })
        |> e(:hits, [])
        |> Enums.ids()
        |> Enum.filter(&(&1 in found_ids))

      assert found_ids == index_order
    end

    test "with joined: true it returns only the groups the viewer is a member of" do
      me = fake_user!()
      mine = public_group!(me, %{name: "Bunting makers"})
      _theirs = public_group!(fake_user!(), %{name: "Bunting watchers"})

      assert %{edges: found} =
               Bonfire.Classify.Categories.search_groups("bunting", current_user: me, joined: true)

      assert Enums.ids(found) == [Enums.id(mine)]
    end

    test "with origin: :remote it returns mirrored groups only" do
      me = fake_user!()
      _local = public_group!(me, %{name: "Dipper locals"})
      mirror = public_group!(fake_user!(), %{name: "Dipper mirror"})

      assert {:ok, _} =
               Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(
                 mirror,
                 "https://elsewhere.local/c/dipper_mirror"
               )

      assert %{edges: found} =
               Bonfire.Classify.Categories.search_groups("dipper",
                 current_user: me,
                 origin: :remote
               )

      assert Enums.ids(found) == [Enums.id(mirror)]
    end

    test "pages through the hits with limit and offset" do
      me = fake_user!()
      for name <- ["Wren first", "Wren second", "Wren third"], do: public_group!(me, %{name: name})

      assert %{edges: first, page_info: %{has_next_page: true, end_cursor: cursor}} =
               Bonfire.Classify.Categories.search_groups("wren", current_user: me, limit: 2)

      assert length(first) == 2

      assert %{edges: next} =
               Bonfire.Classify.Categories.search_groups("wren",
                 current_user: me,
                 limit: 2,
                 offset: String.to_integer(cursor)
               )

      assert length(next) == 1
      assert MapSet.disjoint?(MapSet.new(Enums.ids(first)), MapSet.new(Enums.ids(next)))
    end
  end

  test "a group made before indexing was on is found after a reindex" do
    user = fake_user!()

    # `ProcessTree` treats a stored nil as unset, so `false` stands for "no adapter"
    Process.put([:bonfire_search, :adapter], false)
    refute Bonfire.Search.adapter()

    group = public_group!(user, %{name: "Kestrelwatch society"})

    Process.delete([:bonfire_search, :adapter])
    assert Bonfire.Search.adapter()

    refute in_category_index?("kestrelwatch", group), "control: it was made with no index"

    assert :ok =
             Bonfire.Search.Indexer.reindex_from_db(
               only: Bonfire.Classify.Reindex,
               async: false
             )

    assert in_category_index?("kestrelwatch", group)
  end
end
