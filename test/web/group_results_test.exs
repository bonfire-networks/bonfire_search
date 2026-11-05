defmodule Bonfire.Search.Web.GroupResultsTest do
  @moduledoc "Groups in the main search's results today (with no Groups tab): listed apart from people and posts, once, and found in the closed index by those who may see them."
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

  # a group is rendered through `ActivityLive` like every hit, whose dispatch ends at the group card, without the header and actions that belong to a post. The card is on the Groups tab; All shows its groups as a strip (`group_search_tab_test.exs`)
  test "a group hit renders as the group's card, without a post's header or actions", %{
    conn: conn
  } do
    # someone else's, so the card offers to join it
    Simulate.fake_group!(fake_user!(), %{
      name: "Bittern listeners",
      membership: "open",
      visibility: "global",
      participation: "anyone"
    })

    conn
    |> visit("/search?s=bittern&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit] [data-role=group_preview]", text: "Bittern listeners")
    # the card's own join button, and not a second one (or a follow button) from the activity's actions
    |> assert_has("[data-role=search_group_hit] [id^=join_btn_]", count: 1)
    |> refute_has("[data-role=search_group_hit] button", text: "Follow")
    |> refute_has("[data-role=search_group_hit] [data-id=activity_actions]")
    |> refute_has("[data-role=search_group_hit] [data-id=subject_name]")
  end

  test "a topic hit renders with the same card as a group", %{conn: conn, me: me} do
    Simulate.fake_category!(me, nil, %{name: "Shearwater counts", type: :topic})

    conn
    |> visit("/search?s=shearwater&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit] [data-role=group_preview]", text: "Shearwater counts")
    |> refute_has("[data-role=search_group_hit] [data-id=activity_actions]")
  end

  # its handle starts the lookup and its username is in the index, so before the fix the same group came back twice: as an activity from the index, and as a person from the lookup
  test "a group found by its handle and by its name shows once, among the groups", %{
    conn: conn,
    me: me
  } do
    Simulate.fake_group!(me, %{
      name: "Finchwrights guild",
      username: "finchwrights",
      membership: "open",
      visibility: "global",
      participation: "anyone"
    })

    conn
    |> visit("/search?s=" <> URI.encode_www_form("&finchwrights"))
    |> wait_async()
    |> assert_has("#the_search_results", text: "Finchwrights guild")
    |> refute_has("[data-role=search_people_strip]", text: "Finchwrights guild")
    |> assert_has("[data-role=search_group_hit]", text: "Finchwrights guild", count: 1)
  end

  # a members-only group is only in the closed index, which the All tab can reach only through the visibility switch
  test "a member finds their members-only group on the All tab once private contents are included",
       %{conn: conn, me: me} do
    owner = fake_user!()

    group =
      Simulate.fake_group!(owner, %{
        name: "Nightjar ringers",
        membership: "invite_only",
        visibility: "members:private",
        participation: "group_members"
      })

    {:ok, _} =
      Bonfire.Classify.Categories.add_member(owner, group, me.id, skip_boundary_check: true)

    conn
    |> visit("/search?s=nightjar")
    |> wait_async()
    |> refute_has("#the_search_results", text: "Nightjar ringers")
    |> click_button("#search_boundary button", "Private only")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", text: "Nightjar ringers")
  end

  # the private side searches the closed index only, so it must not read as "everything, private too"
  test "the visibility switch says that private results leave out public ones", %{conn: conn} do
    conn
    |> visit("/search?s=nightjar&facet[index_type]=Bonfire.Data.Social.Post")
    |> wait_async()
    |> click_button("#search_boundary button", "Private only")
    |> wait_async()
    |> assert_has("#search_boundary", text: "Private only")
    |> refute_has("#search_boundary", text: "Private included")
    |> assert_has("[data-role=search_boundary_hint]", text: "Public only")
  end
end
