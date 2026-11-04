defmodule Bonfire.Search.Web.GroupSearchTabTest do
  @moduledoc "The search page's Groups tab: groups and topics, with the group card, paged, and following the same visibility switch as the other tabs."
  use Bonfire.Search.ConnCase, async: false
  @moduletag :ui

  alias Bonfire.Classify.Simulate

  @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)

  setup do
    Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)
    prev = prepare_indexes_for_tests(@adapter)

    on_exit(fn ->
      reset_indexes_after_tests(@adapter, prev)
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
    end)

    account = fake_account!()
    me = fake_user!(account)

    {:ok, conn: conn(user: me, account: account), me: me}
  end

  defp public_group!(user, name) do
    Simulate.fake_group!(user, %{
      name: name,
      membership: "open",
      visibility: "global",
      participation: "anyone"
    })
  end

  # the test page size is 2, so one group and one topic fill the page
  test "the Groups tab lists matching groups and topics with the group card, and no people or content",
       %{conn: conn, me: me} do
    public_group!(fake_user!(), "Plover keepers")
    Simulate.fake_category!(me, nil, %{name: "Plover nesting", type: :topic})
    _fan = fake_user!("Plover Fan")

    {:ok, _} =
      Bonfire.Posts.publish(
        current_user: me,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "plover sighting by the shore"}}
      )

    conn
    |> visit("/search?s=plover")
    |> wait_async()
    |> click_link(".tabs a", "Groups")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit] [data-role=group_preview]", text: "Plover keepers")
    |> assert_has("[data-role=search_group_hit] [data-role=group_preview]", text: "Plover nesting")
    |> refute_has("#the_search_results", text: "Plover Fan")
    |> refute_has("#the_search_results", text: "plover sighting")
  end

  # labels share the Category type in the index, and are dropped when the hits are loaded
  test "the Groups tab leaves labels out", %{conn: conn, me: me} do
    public_group!(me, "Lapwing keepers")
    Simulate.fake_category!(me, nil, %{name: "Lapwing label", type: :label})

    conn
    |> visit("/search?s=lapwing&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", text: "Lapwing keepers")
    |> refute_has("#the_search_results", text: "Lapwing label")
  end

  # the test page size is 2
  test "a third group shows after Load more", %{conn: conn, me: me} do
    for name <- ["Avocet first", "Avocet second", "Avocet third"], do: public_group!(me, name)

    session =
      conn
      |> visit("/search?s=avocet&facet[index_type]=Bonfire.Classify.Category")
      |> wait_async()
      |> assert_has("[data-role=search_group_hit]", count: 2)

    session
    |> click_button("Load more")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", count: 3)
  end

  test "Private only finds a members-only group for its member", %{conn: conn, me: me} do
    owner = fake_user!()

    group =
      Simulate.fake_group!(owner, %{
        name: "Dunlin ringers",
        membership: "invite_only",
        visibility: "members:private",
        participation: "group_members"
      })

    {:ok, _} =
      Bonfire.Classify.Categories.add_member(owner, group, me.id, skip_boundary_check: true)

    conn
    |> visit("/search?s=dunlin&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> refute_has("#the_search_results", text: "Dunlin ringers")
    |> click_button("#search_boundary button", "Private only")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", text: "Dunlin ringers")
  end

  test "the Users tab lists no group", %{conn: conn, me: me} do
    public_group!(me, "Sanderling club")
    _user = fake_user!("Sanderling Watcher")

    conn
    |> visit("/search?s=sanderling&facet[index_type]=Bonfire.Data.Identity.User")
    |> wait_async()
    |> assert_has("#the_search_results", text: "Sanderling Watcher")
    |> refute_has("#the_search_results", text: "Sanderling club")
  end
end
