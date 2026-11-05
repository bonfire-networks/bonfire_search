defmodule Bonfire.Search.Web.GroupDirectorySearchTest do
  @moduledoc "The /groups search asks the search index when there is one, so it finds every matching group, not only the loaded page, and pages through the hits; the view, origin and joining policy still apply."
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

    Process.put(:federating, false)

    account = fake_account!()
    me = fake_user!(account)

    {:ok, conn: conn(user: me, account: account), me: me}
  end

  defp public_group!(user, name, membership \\ "open") do
    Simulate.fake_group!(user, %{
      name: name,
      membership: membership,
      visibility: "global",
      participation: "anyone"
    })
  end

  defp card(group), do: "#group-preview-#{Enums.id(group)}"

  # the test page size is 2, and the directory lists the newest first, so the first group made is beyond the first page
  test "/groups search finds a group beyond the first loaded page", %{conn: conn} do
    owner = fake_user!()
    oldest = public_group!(owner, "Zebrafinch makers")
    public_group!(owner, "Garden circle")
    public_group!(owner, "Pottery circle")

    conn
    |> visit("/groups")
    |> refute_has(card(oldest))
    |> fill_in("Search groups", with: "zebrafinch")
    |> assert_has(card(oldest), text: "Zebrafinch makers")
  end

  test "Load more under a search shows the next page of hits", %{conn: conn} do
    owner = fake_user!()

    groups =
      for name <- ["Avocet one", "Avocet two", "Avocet three"], do: public_group!(owner, name)

    session =
      conn
      |> visit("/groups")
      |> fill_in("Search groups", with: "avocet")
      |> assert_has("#group-discovery-grid article", count: 2)

    session
    |> click_button("[data-id=load_more]", "Load more")
    |> assert_has("#group-discovery-grid article", count: 3)
    |> then(fn session -> Enum.reduce(groups, session, &assert_has(&2, card(&1))) end)
  end

  # the joining policy's menu gives way to the public/private switch while a term is typed (the test below), so it doesn't apply to a search
  test "the view and origin still apply", %{conn: conn, me: me} do
    # a page of hits that holds the groups (the test page size is 2), as this is about the filters, not paging
    Process.put([:bonfire, :default_pagination_limit], 10)
    owner = fake_user!()
    joined = public_group!(owner, "Plover joined")
    {:ok, _} = Bonfire.Classify.Categories.join_group(me, joined)
    not_joined = public_group!(owner, "Plover elsewhere")
    reviewed = public_group!(owner, "Plover reviewed", "on_request")
    mirror = public_group!(owner, "Plover mirror")

    assert {:ok, _} =
             Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(
               mirror,
               "https://elsewhere.local/c/plover_mirror"
             )

    conn
    |> visit("/groups/discover")
    |> fill_in("Search groups", with: "plover")
    |> assert_has(card(not_joined))
    # every joining policy, since its menu isn't there to filter on
    |> assert_has(card(reviewed))
    |> choose("This instance")
    |> assert_has(card(not_joined))
    |> refute_has(card(mirror))
    |> choose("Joined")
    |> assert_has(card(joined))
    |> refute_has(card(not_joined))
  end

  # each search pages one index: a members-only group is in the closed index only, which is checked for the viewer
  test "while a term is typed, the joining-policy menu gives way to a public/private switch", %{
    conn: conn,
    me: me
  } do
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
    |> visit("/groups/discover")
    |> assert_has("#group-policy-filters")
    |> refute_has("#group-index-filters")
    |> fill_in("Search groups", with: "dunlin")
    |> refute_has("#group-policy-filters")
    |> assert_has("#group-index-filters")
    |> refute_has(card(group))
    |> choose("Private only")
    |> assert_has(card(group), text: "Dunlin ringers")
    |> choose("Public only")
    |> refute_has(card(group))
    |> fill_in("Search groups", with: "")
    |> assert_has("#group-policy-filters")
    |> refute_has("#group-index-filters")
  end

  # Joined lists the viewer's own groups, public and members-only, which are in different indexes, so its search filters them as with no index, and shows no switch
  test "a search on Joined finds every joined group, public and members-only, with no switch", %{
    conn: conn,
    me: me
  } do
    owner = fake_user!()
    public = public_group!(owner, "Marsh walkers")
    {:ok, _} = Bonfire.Classify.Categories.join_group(me, public)

    members_only =
      Simulate.fake_group!(owner, %{
        name: "Marsh ringers",
        membership: "invite_only",
        visibility: "members:private",
        participation: "group_members"
      })

    {:ok, _} =
      Bonfire.Classify.Categories.add_member(owner, members_only, me.id,
        skip_boundary_check: true
      )

    conn
    |> visit("/groups/joined")
    |> fill_in("Search groups", with: "marsh")
    |> assert_has(card(public), text: "Marsh walkers")
    |> assert_has(card(members_only), text: "Marsh ringers")
    |> refute_has("#group-index-filters")
    |> assert_has("#group-policy-filters")
  end

  test "a topic's name finds its group", %{conn: conn} do
    owner = fake_user!()
    group = public_group!(owner, "Hedge society")
    Simulate.fake_category!(owner, group, %{name: "Zebrafinch care", type: :topic})
    # newer groups, so the one with the topic is beyond the first page
    public_group!(owner, "Garden circle")
    public_group!(owner, "Pottery circle")

    conn
    |> visit("/groups")
    |> refute_has(card(group))
    |> fill_in("Search groups", with: "zebrafinch")
    |> assert_has(card(group), text: "Hedge society")
  end
end
