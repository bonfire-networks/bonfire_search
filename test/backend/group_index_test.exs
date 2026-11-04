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
