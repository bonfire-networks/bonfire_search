defmodule Bonfire.Search.BatchedIndexingTest do
  @moduledoc """
  Covers the batched-indexing path: documents are buffered in
  `Bonfire.Search.IndexQueue` and flushed to Meilisearch in one per-index batch
  by `Bonfire.Search.Workers.FlushWorker`, instead of one Meili task per doc.
  """
  use Bonfire.Search.DataCase, async: false
  use Bonfire.Common.Settings
  use Oban.Testing, repo: Bonfire.Common.Repo

  alias Bonfire.Search
  alias Bonfire.Search.IndexQueue
  alias Bonfire.Search.Workers.FlushWorker
  alias Bonfire.Posts

  defp flush(index) do
    FlushWorker.perform(%Oban.Job{args: %{"index" => to_string(index)}})
  end

  # Assert a document reached Meilisearch, at the index layer — bypassing
  # Bonfire's high-level hit rendering (which needs real subject/creator data
  # our synthetic bare-map fixtures don't have). The point of these tests is
  # that batching delivers the docs, not how hits are rendered.
  defp assert_in_index(index, id) do
    client = Bonfire.Search.MeiliLib.get_client()
    index_name = Bonfire.Search.Indexer.index_name(index)
    assert {:ok, %{"id" => ^id}} = Meilisearch.Document.get(client, index_name, id)
  end

  defp doc(id, title) do
    %{
      "id" => id,
      "index_type" => "Bonfire.Data.Social.Post",
      "post_content" => %{
        "index_type" => "Bonfire.Data.Social.PostContent",
        "name" => title,
        "summary" => "summary #{title}",
        "html_body" => "body of #{title}"
      }
    }
  end

  describe "IndexQueue buffer (no Meili, no Oban)" do
    test "enqueue / claim_batch / count / delete_ids / pending_indexes" do
      assert {:ok, _} = IndexQueue.enqueue(:public, doc(uid(Post), "Alpha"))
      assert {:ok, _} = IndexQueue.enqueue(:public, doc(uid(Post), "Beta"))
      assert {:ok, _} = IndexQueue.enqueue(:closed, doc(uid(Post), "Gamma"))

      assert IndexQueue.count(:public) == 2
      assert IndexQueue.count(:closed) == 1
      assert Enum.sort(IndexQueue.pending_indexes()) == [:closed, :public]

      rows = IndexQueue.claim_batch(:public, 10)
      assert length(rows) == 2
      # oldest first
      assert hd(rows).document["post_content"]["name"] == "Alpha"

      assert {2, _} = IndexQueue.delete_ids(Enum.map(rows, & &1.id))
      assert IndexQueue.count(:public) == 0
      assert IndexQueue.count(:closed) == 1
    end

    test "index_atom never trusts arbitrary strings" do
      assert IndexQueue.index_atom("public") == :public
      assert IndexQueue.index_atom("closed") == :closed
      assert IndexQueue.index_atom("anything_else") == nil
    end
  end

  describe "batched path via Bonfire.Search.maybe_index (Meili)" do
    setup do: batched_meili_setup()

    test "buffers instead of indexing inline, then flush makes it searchable" do
      user = fake_user!()
      # creating a user indexes its profile too — drain that side-effect so the
      # buffer starts from a known-empty state for the assertions below
      flush(:public)
      assert IndexQueue.count(:public) == 0

      post = doc(uid(Post), "Buffered Title")

      # the batched branch returns :queued rather than a Meili task
      assert {:ok, :queued} = Search.maybe_index(post, "public", current_user: user)
      assert IndexQueue.count(:public) == 1

      # flush the buffer (called directly so the test is independent of Oban mode)
      assert :ok = flush(:public)
      assert IndexQueue.count(:public) == 0

      assert_in_index(:public, post["id"])
    end

    test "a burst of documents is drained as one batch" do
      user = fake_user!()
      # drain the user-profile indexing side-effect first
      flush(:public)
      assert IndexQueue.count(:public) == 0

      posts = for n <- 1..5, do: doc(uid(Post), "Burst #{n}")

      for p <- posts do
        assert {:ok, :queued} = Search.maybe_index(p, "public", current_user: user)
      end

      assert IndexQueue.count(:public) == 5

      # a single flush invocation indexes the whole batch
      assert :ok = flush(:public)
      assert IndexQueue.count(:public) == 0

      for p <- posts do
        assert_in_index(:public, p["id"])
      end
    end
  end

  describe "fallback to synchronous indexing" do
    setup do: batched_meili_setup(wait: true)

    test "wait_for_indexing bypasses the buffer and indexes synchronously" do
      user = fake_user!()
      post = doc(uid(Post), "Synchronous Title")

      result = Search.maybe_index(post, "public", current_user: user)
      # sync path returns the Meili task tuple, never the :queued marker
      refute match?({:ok, :queued}, result)

      # nothing was buffered
      assert IndexQueue.count(:public) == 0

      # and it reached the index immediately, without any flush
      assert_in_index(:public, post["id"])
    end
  end

  # shared setup for the batched (async-indexing) describes below
  defp batched_meili_setup(opts \\ []) do
    Bonfire.Common.Config.put(:wait_for_indexing, opts[:wait] || false, :bonfire_search)

    Bonfire.Common.Config.put(
      :batched_indexing,
      Keyword.get(opts, :batched, true),
      :bonfire_search
    )

    {meili_adapter, tesla_adapter} = prepare_meili_for_tests()

    on_exit(fn ->
      reset_meili_after_tests(meili_adapter, tesla_adapter)
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
      Bonfire.Common.Config.put(:batched_indexing, true, :bonfire_search)
      Bonfire.Common.Config.put(:index_batch_max, 1000, :bonfire_search)
    end)

    :ok
  end

  # drop fixture-creation side-effects (a new user indexes its own profile)
  defp drain_fixtures do
    flush(:public)
    flush(:closed)
  end

  describe "P0: production path via Posts.publish" do
    setup do: batched_meili_setup()

    test "publishing a real post routes through the buffer, then flush indexes it" do
      user = fake_user!()
      drain_fixtures()
      assert IndexQueue.count(:public) == 0

      assert {:ok, post} =
               Posts.publish(
                 current_user: user,
                 post_attrs: %{
                   post_content: %{
                     name: "Published Via Epic",
                     summary: "real publish flow",
                     html_body: "this went through the :publish epic and Search.Acts.Queue"
                   }
                 },
                 boundary: "public"
               )

      # the real epic/act path buffered it instead of indexing inline
      assert IndexQueue.count(:public) == 1

      assert :ok = flush(:public)
      assert IndexQueue.count(:public) == 0

      # the phrase is unique to this test's post, so a hit proves the real
      # publish→epic→Acts.Queue→buffer→flush path indexed it end-to-end
      assert %{hits: [_ | _]} = Search.search("Published Via Epic")
      assert is_binary(uid(post))
    end
  end

  describe "P0: failure handling" do
    setup do: batched_meili_setup()

    test "a Meili failure keeps rows buffered and returns an error (Oban will retry)" do
      # a document with no id has no primary key — Meilisearch rejects the task
      bad = %{
        "index_type" => "Bonfire.Data.Social.Post",
        "post_content" => %{"name" => "No Primary Key", "html_body" => "x"}
      }

      assert {:ok, _} = IndexQueue.enqueue(:public, bad)
      assert IndexQueue.count(:public) == 1

      assert {:error, _} = flush(:public)

      # rows are NOT deleted, so the next flush / Oban retry can pick them up
      assert IndexQueue.count(:public) == 1
    end
  end

  describe "P0: :closed index routing" do
    setup do: batched_meili_setup()

    test "a non-public boundary buffers under :closed and flushes to the closed index" do
      user = fake_user!()
      drain_fixtures()

      post = doc(uid(Post), "Closed Doc")
      assert {:ok, :queued} = Search.maybe_index(post, "closed", current_user: user)

      # routed to :closed, not :public
      assert IndexQueue.count(:closed) == 1
      assert IndexQueue.count(:public) == 0

      assert :ok = flush(:closed)
      assert IndexQueue.count(:closed) == 0
      assert_in_index(:closed, post["id"])
    end
  end

  describe "P0: batched_indexing flag rollback" do
    # wait:true so the synchronous path awaits Meili (the legacy behaviour the
    # rollback restores is itself async unless wait_for_indexing is set)
    setup do: batched_meili_setup(batched: false, wait: true)

    test "with batched_indexing disabled, indexing is synchronous (instant rollback)" do
      user = fake_user!()
      post = doc(uid(Post), "Rollback Path")

      result = Search.maybe_index(post, "public", current_user: user)
      refute match?({:ok, :queued}, result)

      assert IndexQueue.count(:public) == 0
      assert_in_index(:public, post["id"])
    end
  end

  describe "P1: backlog draining" do
    setup do
      batched_meili_setup()
      Bonfire.Common.Config.put(:index_batch_max, 2, :bonfire_search)
      :ok
    end

    test "one flush drains at most index_batch_max and reschedules the remainder" do
      ids = for n <- 1..5, do: uid(Post)

      for {id, n} <- Enum.with_index(ids) do
        assert {:ok, _} = IndexQueue.enqueue(:public, doc(id, "Backlog #{n}"))
      end

      assert IndexQueue.count(:public) == 5

      # one invocation drains exactly the batch cap, leaving the rest buffered
      assert :ok = flush(:public)
      assert IndexQueue.count(:public) == 3
      # and it scheduled a follow-up to drain the backlog
      assert [_ | _] = all_enqueued(worker: FlushWorker)

      # draining to completion indexes every document
      Enum.each(1..3, fn _ -> flush(:public) end)
      assert IndexQueue.count(:public) == 0
      for id <- ids, do: assert_in_index(:public, id)
    end
  end

  describe "P1: debounce coalescing" do
    setup do
      Bonfire.Common.Config.put(:batched_indexing, true, :bonfire_search)
      on_exit(fn -> Bonfire.Common.Config.put(:batched_indexing, true, :bonfire_search) end)
      :ok
    end

    test "repeated schedule/1 within the debounce window collapses to one job" do
      for _ <- 1..5, do: FlushWorker.schedule(:public)

      # the unique option dedupes the burst into a single pending flush
      assert length(all_enqueued(worker: FlushWorker)) == 1
    end
  end

  describe "P1: idempotency & double-flush" do
    setup do: batched_meili_setup()

    test "duplicate ids and a repeated flush are harmless" do
      id = uid(Post)
      assert {:ok, _} = IndexQueue.enqueue(:public, doc(id, "Dup A"))
      assert {:ok, _} = IndexQueue.enqueue(:public, doc(id, "Dup B"))
      assert IndexQueue.count(:public) == 2

      assert :ok = flush(:public)
      assert IndexQueue.count(:public) == 0
      assert_in_index(:public, id)

      # flushing an empty buffer is a no-op, doc still present
      assert :ok = flush(:public)
      assert_in_index(:public, id)

      # delete_ids is idempotent too
      assert {0, _} = IndexQueue.delete_ids([-1])
    end
  end

  describe "P1: prepare_indexable_object passthrough (unit)" do
    test "already-formatted maps re-feed unchanged" do
      by_type = %{"index_type" => "Bonfire.Data.Social.Post", "post_content" => %{}}
      by_id = %{"id" => "01ABC", "post_content" => %{}}

      assert Bonfire.Search.Indexer.prepare_indexable_object(by_type) == by_type
      assert Bonfire.Search.Indexer.prepare_indexable_object(by_id) == by_id

      assert Bonfire.Search.Indexer.prepare_indexable_object([by_type, by_id]) ==
               [by_type, by_id]
    end
  end

  describe "P1: non-indexable input" do
    setup do
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
      Bonfire.Common.Config.put(:batched_indexing, true, :bonfire_search)
      on_exit(fn -> Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search) end)
      :ok
    end

    test "an object with nothing indexable is not buffered" do
      refute match?({:ok, :queued}, Search.maybe_index(%{}, "public", []))
      assert IndexQueue.count(:public) == 0
    end
  end

  describe "P1: safety nets / observability" do
    setup do
      batched_meili_setup()
      Bonfire.Common.Config.put(:index_batch_max, 2, :bonfire_search)
      :ok
    end

    test "queue_configured?/0 returns a boolean and never raises (boot-safe)" do
      # Oban runs in testing mode here (no started queues), so this is `false`
      # under test even though `search_index` is in config/runtime.exs. What
      # matters is the contract: it must never raise, so the boot-time check in
      # `await_and_init` can't crash startup.
      assert is_boolean(FlushWorker.queue_configured?())
    end

    test "a backlog emits a backlog telemetry event with its size" do
      handler = "test-index-queue-backlog-#{System.unique_integer([:positive])}"
      pid = self()

      :telemetry.attach(
        handler,
        [:bonfire_search, :index_queue, :backlog],
        fn _event, measurements, metadata, _ -> send(pid, {:backlog, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      for n <- 1..5, do: IndexQueue.enqueue(:public, doc(uid(Post), "Obs #{n}"))

      # batch_max is 2, so this drains 2 and leaves 3 → backlog mode
      assert :ok = flush(:public)

      assert_received {:backlog, %{size: 3}, %{index: :public}}
    end
  end
end
