# events are `bonfire_gatherings`'s, so these run only where it is installed
if Bonfire.Common.Extend.extension_enabled?(:bonfire_gatherings) do
  defmodule Bonfire.Search.Web.EventsSearchTest do
    @moduledoc "The /events search asks the search index, within the upcoming list it is typed into; with no index, or on the past list, there is no search."
    use Bonfire.Search.ConnCase, async: false
    @moduletag :ui

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

    defp event!(user, name) do
      {:ok, event} =
        Bonfire.Gatherings.Events.create(
          current_user: user,
          boundary: "public",
          event_attrs: %{
            post_content: %{name: name},
            time_span: %{
              has_beginning: ~U[2030-06-01 18:00:00Z],
              has_end: ~U[2030-06-01 21:00:00Z]
            }
          }
        )

      event
    end

    test "typing a word lists the upcoming events it matches, and keeps it in the URL", %{
      conn: conn,
      me: me
    } do
      event!(me, "Marmalade Workshop")
      event!(me, "Pear Picnic")

      conn
      |> visit("/events")
      # control: both are listed before searching
      |> assert_has("[data-id=event_preview]", text: "Pear Picnic")
      |> within("[data-id=events_search]", &fill_in(&1, "Search events", with: "Marmalade"))
      |> assert_has("[data-id=event_preview]", text: "Marmalade Workshop")
      |> refute_has("[data-id=event_preview]", text: "Pear Picnic")
      |> assert_path("/events", query_params: %{"search" => "Marmalade"})
    end

    test "a search with no match stays on the upcoming list and says nothing matches, with no move to past events",
         %{conn: conn, me: me} do
      event!(me, "Marmalade Workshop")

      conn
      |> visit("/events?search=Zucchini")
      |> assert_path("/events", query_params: %{"search" => "Zucchini"})
      |> assert_has("[data-id=events_empty]")
      |> refute_has("[data-id=flash_info]", text: "There are no upcoming events")
    end

    test "there is no search on the past list, nor anywhere without a search index", %{
      conn: conn,
      me: me
    } do
      event!(me, "Marmalade Workshop")

      conn
      |> visit("/events")
      # control: with an index, the upcoming list has it
      |> assert_has("[data-id=events_search]")

      conn
      |> visit("/events/past")
      |> refute_has("[data-id=events_search]")

      Process.put([:bonfire_search, :adapter], false)

      conn
      |> visit("/events")
      |> refute_has("[data-id=events_search]")
    end
  end
end
