defmodule Bonfire.Search.UnindexOnDeleteTest do
  @moduledoc "Whatever is deleted, by whichever path, is gone from the search index and not only hidden once its pointer fails to load."
  use Bonfire.Search.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Search

  @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)

  setup do
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)
    prev = prepare_indexes_for_tests(@adapter)

    on_exit(fn ->
      reset_indexes_after_tests(@adapter, prev)
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    :ok
  end

  # raw, so it sees what the index holds: loaded hits go through their pointers, which leave out a deleted object even while the index still holds it
  defp in_index?(term, object) do
    Search.search(term, %{index: "public", raw: true}, [], %{})
    |> e(:hits, [])
    |> List.wrap()
    |> Enum.any?(&(Enums.id(&1) == Enums.id(object)))
  end

  defp publish_post!(user, attrs) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: user,
        boundary: "public",
        post_attrs: attrs
      )

    post
  end

  test "a deleted post is gone from the index" do
    user = fake_user!()
    post = publish_post!(user, %{post_content: %{html_body: "Lapwing roost notes"}})
    assert in_index?("lapwing", post)

    assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: user)

    refute in_index?("lapwing", post)
  end

  test "a post deleted by id is gone from the index" do
    user = fake_user!()
    post = publish_post!(user, %{post_content: %{html_body: "Curlew roost notes"}})
    assert in_index?("curlew", post)

    assert {:ok, _} = Bonfire.Social.Objects.delete(Enums.id(post), current_user: user)

    refute in_index?("curlew", post)
  end

  test "a deleted comment is gone from the index" do
    user = fake_user!()
    post = publish_post!(user, %{post_content: %{html_body: "Thread root"}})

    comment =
      publish_post!(user, %{
        reply_to_id: Enums.id(post),
        post_content: %{html_body: "Dunlin reply text"}
      })

    assert in_index?("dunlin", comment)

    assert {:ok, _} = Bonfire.Social.Objects.delete(comment, current_user: user)

    refute in_index?("dunlin", comment)
  end

  test "a deleted group is gone from the index" do
    user = fake_user!()

    group =
      Bonfire.Classify.Simulate.fake_group!(user, %{
        name: "Sanderling society",
        membership: "open",
        visibility: "global",
        participation: "anyone"
      })

    assert in_index?("sanderling", group)

    assert {:ok, _} = Bonfire.Classify.Categories.hard_delete(group, current_user: user)

    refute in_index?("sanderling", group)
  end

  test "a deleted user is gone from the index" do
    # users are indexed only when the Indexer module is enabled
    Bonfire.Common.Config.put([Bonfire.Search.Indexer, :modularity], true, :bonfire_search)

    on_exit(fn ->
      Bonfire.Common.Config.put([Bonfire.Search.Indexer, :modularity], false, :bonfire_search)
    end)

    user = Bonfire.Common.Repo.maybe_preload(fake_user!(), [:character])
    username = user.character.username
    assert in_index?(username, user)

    Bonfire.Me.Users.delete(user, [])

    refute in_index?(username, user)
  end
end
