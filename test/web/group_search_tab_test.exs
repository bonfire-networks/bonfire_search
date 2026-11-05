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
    |> assert_has("[data-role=search_group_hit] [data-role=group_preview]",
      text: "Plover keepers"
    )
    |> assert_has("[data-role=search_group_hit] [data-role=group_preview]",
      text: "Plover nesting"
    )
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

  # `traced_calls/2` and `count_index_searches/3` are in `Bonfire.Search.DataHelpers`
  test "the All tab shows the people strip, a groups strip from the all hits and content, with no user twice and three index searches",
       %{conn: conn, me: me} do
    # a page that holds the user, the group and the post of the `all` search (the test page size is 2)
    Process.put([:bonfire, :default_pagination_limit], 10)

    public_group!(me, "Pipit keepers")
    _fan = fake_user!("Pipit Fan")

    {:ok, _} =
      Bonfire.Posts.publish(
        current_user: me,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "pipit song at dawn"}}
      )

    searches =
      count_index_searches(@adapter, "pipit", fn ->
        conn
        |> visit("/search?s=pipit")
        |> wait_async()
        |> assert_has("[data-role=search_people_strip] [data-role=character]",
          text: "Pipit Fan",
          count: 1
        )
        |> assert_has("#the_search_results [data-id=profile_name]", text: "Pipit Fan", count: 1)
        |> assert_has("[data-role=search_groups_strip] [data-role=search_group_hit]",
          text: "Pipit keepers"
        )
        |> assert_has("[data-role=search_groups_strip] a", text: "More groups")
        |> assert_has("#the_search_results .activity_wrapper", text: "pipit song at dawn")
      end)

    # the people strip's typed query on the User bucket, one search on `all` for groups and content, and one on the Hashtag bucket for the hashtag chips
    assert searches == 3
  end

  # a user is in the User bucket and in `all`, so both of All's searches find them: their hits are merged by id before anything is loaded
  test "a user found by both of the All tab's searches shows once and is loaded once",
       %{conn: conn} do
    Process.put([:bonfire, :default_pagination_limit], 10)

    fan = fake_user!("Wagtail Fan")

    loads =
      traced_calls({Bonfire.Boundaries, :load_pointers}, fn ->
        conn
        |> visit("/search?s=wagtail")
        |> wait_async()
        |> assert_has("#the_search_results [data-id=profile_name]", text: "Wagtail Fan", count: 1)
      end)

    loads_of_fan = Enum.filter(loads, fn [ids | _] -> Enums.id(fan) in List.wrap(ids) end)

    assert length(loads_of_fan) == 1, "loaded in #{length(loads_of_fan)} queries"
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
