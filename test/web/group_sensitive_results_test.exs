defmodule Bonfire.Search.Web.GroupSensitiveResultsTest do
  @moduledoc "A group or topic marked sensitive in search results: its card has a badge and hides its description until shown. The description stays indexed, so a word in it still finds the group."
  use Bonfire.Search.ConnCase, async: false
  @moduletag :ui

  alias Bonfire.Classify.Simulate
  alias Bonfire.Social.Objects

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

  defp group!(name, summary, marked?) do
    group =
      Simulate.fake_group!(fake_user!(), %{
        name: name,
        summary: summary,
        membership: "open",
        visibility: "global",
        participation: "anyone"
      })

    if marked? do
      assert {:ok, group} = Objects.set_sensitivity(group, true)
      # reindexed as a moderator's edit would
      Bonfire.Search.maybe_index(group, nil, nil)
    end

    group
  end

  test "a group not marked sensitive has no badge and shows its description", %{conn: conn} do
    group!("Bittern listeners", "Recordings of booming bitterns.", false)

    conn
    |> visit("/search?s=bittern&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", text: "Bittern listeners")
    |> refute_has("[data-role=search_group_hit] [data-role=sensitive_badge]")
    |> assert_has("[data-role=search_group_hit] [data-role=group-card-summary]",
      text: "Recordings of booming bitterns."
    )
    |> refute_has("[data-role=search_group_hit] [data-role=group-card-summary].hidden")
  end

  test "a group marked sensitive has a badge, and its description is hidden until shown", %{
    conn: conn
  } do
    group!("Life drawing", "Nude figure studies from life.", true)

    conn
    # a word only in its description, which stays indexed
    |> visit("/search?s=figure&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", text: "Life drawing")
    |> assert_has("[data-role=search_group_hit] [data-role=sensitive_badge]")
    |> assert_has("[data-role=search_group_hit] [data-role=group-card-summary].hidden",
      text: "Nude figure studies from life."
    )
  end

  test "so does a topic marked sensitive", %{conn: conn, me: me} do
    topic = Simulate.fake_category!(me, nil, %{name: "Shearwater counts", type: :topic})
    assert {:ok, topic} = Objects.set_sensitivity(topic, true)
    Bonfire.Search.maybe_index(topic, nil, nil)

    conn
    |> visit("/search?s=shearwater&facet[index_type]=Bonfire.Classify.Category")
    |> wait_async()
    |> assert_has("[data-role=search_group_hit]", text: "Shearwater counts")
    |> assert_has("[data-role=search_group_hit] [data-role=sensitive_badge]")
  end
end
