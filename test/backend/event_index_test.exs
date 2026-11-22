# events are `bonfire_gatherings`'s, so these run only where it is installed
if Bonfire.Common.Extend.extension_enabled?(:bonfire_gatherings) do
  defmodule Bonfire.Search.EventIndexTest do
    @moduledoc "Events in the search index under their own type: found by their name, summary and place, in the index their boundary decides, by their new name once renamed, and gone once deleted."
    use Bonfire.Search.DataCase, async: false
    @moduletag :backend

    alias Bonfire.Gatherings.Events
    alias Bonfire.Search

    @adapter Bonfire.Common.Config.get(:adapter, Bonfire.Search.MeiliLib, :bonfire_search)
    @event_type "Bonfire.Gatherings.Event"

    setup do
      Bonfire.Common.Config.put(:wait_for_indexing, true, :bonfire_search)
      prev = prepare_indexes_for_tests(@adapter)

      on_exit(fn ->
        reset_indexes_after_tests(@adapter, prev)
        Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
      end)

      :ok
    end

    # raw, so it sees what the index holds under the Event type
    defp in_event_index?(term, event, index \\ "public") do
      Search.search(term, %{index: index, raw: true}, [], %{"index_type" => @event_type})
      |> e(:hits, [])
      |> List.wrap()
      |> Enum.any?(&(Enums.id(&1) == event.id))
    end

    defp event!(user, attrs, boundary \\ "public") do
      {:ok, event} =
        Events.create(
          current_user: user,
          boundary: boundary,
          event_attrs:
            Map.merge(
              %{
                post_content: %{name: "Marmalade Workshop", summary: "Bring your own jars"},
                time_span: %{
                  has_beginning: ~U[2030-06-01 18:00:00Z],
                  has_end: ~U[2030-06-01 21:00:00Z]
                },
                place: "Quillfeather Hall"
              },
              attrs
            )
        )

      event
    end

    test "an event is found by a word of its name, its summary and its place" do
      event = event!(fake_user!(), %{})

      assert in_event_index?("Marmalade", event)
      assert in_event_index?("jars", event)
      assert in_event_index?("Quillfeather", event)
    end

    test "an event only some may see goes to the closed index, not the public one" do
      user = fake_user!()
      public = event!(user, %{post_content: %{name: "Open Gooseberry Fair"}})
      local = event!(user, %{post_content: %{name: "Local Gooseberry Fair"}}, "local")

      # control: the public one is in the public index
      assert in_event_index?("Gooseberry", public)
      refute in_event_index?("Gooseberry", local)
      assert in_event_index?("Gooseberry", local, "closed")
    end

    test "a renamed event is found by its new name" do
      user = fake_user!()
      event = event!(user, %{})

      {:ok, _} = Events.update(user, event, %{post_content: %{name: "Damson Workshop"}})

      assert in_event_index?("Damson", event)
    end

    test "an event made while nothing indexed is found after a reindex" do
      # no adapter while it is made, as before events were indexed
      Process.put([:bonfire_search, :adapter], false)
      event = event!(fake_user!(), %{post_content: %{name: "Quince Supper"}})
      Process.delete([:bonfire_search, :adapter])
      refute in_event_index?("Quince", event)

      Bonfire.Gatherings.Reindex.reindex()

      assert in_event_index?("Quince", event)
    end

    defp listed_ids(user, ids, extra \\ []) do
      Events.list_upcoming([current_user: user, ids: ids] ++ extra)
      |> e(:edges, [])
      |> Enum.map(&Enums.id/1)
    end

    test "a search narrows the upcoming list to the events it matches, which leaves out those that have ended" do
      user = fake_user!()
      match = event!(user, %{})
      other = event!(user, %{post_content: %{name: "Pear Picnic"}})

      ended =
        event!(user, %{
          post_content: %{name: "Marmalade Swap"},
          time_span: %{has_beginning: ~U[2020-06-01 18:00:00Z], has_end: ~U[2020-06-01 21:00:00Z]}
        })

      # a post with the same word, which the Event type leaves out of the hits
      post =
        Bonfire.Posts.Fake.fake_post!(user, "public", %{
          post_content: %{name: "Marmalade recipe", html_body: "<p>Marmalade</p>"}
        })

      ids = Events.search("Marmalade", current_user: user)
      # control: the index finds the ended one too, so the list is what leaves it out
      assert ended.id in ids
      refute post.id in ids

      listed = listed_ids(user, ids)
      assert match.id in listed
      refute other.id in listed
      refute ended.id in listed
    end

    test "a search within a category keeps only that category's matches" do
      user = fake_user!()

      topic =
        Bonfire.Classify.Simulate.fake_category!(user, nil, %{type: :topic, name: "Preserves"})

      in_topic = event!(user, %{tags: [topic]})
      outside = event!(user, %{post_content: %{name: "Marmalade Tasting"}})

      listed = listed_ids(user, Events.search("Marmalade", current_user: user), tags: [topic])

      assert in_topic.id in listed
      refute outside.id in listed
    end

    test "a stranger's search doesn't list another user's event they may not see" do
      owner = fake_user!()
      # with no one mentioned, only its creator may see it
      private = event!(owner, %{post_content: %{name: "Private Medlar Evening"}}, "mentions")
      # control: its owner finds it
      assert private.id in listed_ids(owner, Events.search("Medlar", current_user: owner))

      stranger = fake_user!()
      refute private.id in listed_ids(stranger, Events.search("Medlar", current_user: stranger))
    end

    test "without a search index, a search returns nil, so the page lists as without one" do
      Process.put([:bonfire_search, :adapter], false)
      refute Events.search("Marmalade", current_user: fake_user!())
    end

    test "the daily job takes out of the index the events that ended longer ago than the setting, and leaves those that ended since" do
      user = fake_user!()
      now = DateTime.utc_now()
      ago = fn days -> DateTime.add(now, -days * 86_400, :second) end

      # 30 days by default (`[Bonfire.Gatherings.Events, :unindex_ended_after]`)
      long_ended =
        event!(user, %{
          post_content: %{name: "Old Elderflower Fair"},
          time_span: %{has_beginning: ago.(33), has_end: ago.(32)}
        })

      recently_ended =
        event!(user, %{
          post_content: %{name: "Recent Elderflower Fair"},
          time_span: %{has_beginning: ago.(6), has_end: ago.(5)}
        })

      # control: both are indexed before the job
      assert in_event_index?("Elderflower", long_ended)
      assert in_event_index?("Elderflower", recently_ended)

      :ok = Bonfire.Gatherings.Workers.UnindexEnded.perform(%Oban.Job{args: %{}})

      refute in_event_index?("Elderflower", long_ended)
      assert in_event_index?("Elderflower", recently_ended)
    end

    test "a deleted event is gone from the index" do
      user = fake_user!()
      event = event!(user, %{})
      # control: indexed before
      assert in_event_index?("Marmalade", event)

      {:ok, _} = Bonfire.Social.Objects.delete(event, current_user: user)

      refute in_event_index?("Marmalade", event)
    end
  end
end
