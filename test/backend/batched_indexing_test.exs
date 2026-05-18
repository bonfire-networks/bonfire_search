defmodule Bonfire.Search.BatchedIndexingTest do
  @moduledoc """
  Batched indexing using Oban as the buffer: each object enqueues a debounced
  `IndexWorker` job; the first job of a window sweeps its siblings and indexes
  them all in one Meilisearch task, cancelling the swept jobs.
  """
  use Bonfire.Search.DataCase, async: false
  use Bonfire.Common.Settings
  use Oban.Testing, repo: Bonfire.Common.Repo

  alias Bonfire.Search
  alias Bonfire.Search.Workers.IndexWorker
  alias Bonfire.Posts

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

  # assert at the Meili layer (synthetic bare-map fixtures can't go through the
  # high-level hit rendering, which needs real subject/creator data)
  defp assert_in_index(index, id) do
    client = Bonfire.Search.MeiliLib.get_client()
    index_name = Bonfire.Search.Indexer.index_name(index)
    assert {:ok, %{"id" => ^id}} = Meilisearch.Document.get(client, index_name, id)
  end

  defp run(job), do: IndexWorker.perform(job)
  defp job_state(id), do: Bonfire.Common.Repo.get(Oban.Job, id).state

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

  describe "batched path via Bonfire.Search.maybe_index (Oban buffer)" do
    setup do: batched_meili_setup()

    test "maybe_index enqueues a debounced job instead of indexing inline" do
      user = fake_user!()
      post = doc(uid(Post), "Buffered Title")

      assert {:ok, :queued} = Search.maybe_index(post, "public", current_user: user)
      assert_enqueued(worker: IndexWorker, args: %{"index" => "public"})

      # running a pending job sweeps siblings (incl. the user-profile job) and
      # indexes the whole set in one Meili task
      [j | _] = all_enqueued(worker: IndexWorker)
      assert :ok = run(j)

      assert_in_index(:public, post["id"])
    end

    test "a burst is swept into ONE batch and the siblings are cancelled" do
      {:ok, j1} = IndexWorker.enqueue(:public, doc(uid(Post), "Burst 1"))
      {:ok, j2} = IndexWorker.enqueue(:public, doc(uid(Post), "Burst 2"))
      {:ok, j3} = IndexWorker.enqueue(:public, doc(uid(Post), "Burst 3"))

      # running the first job sweeps j2/j3 into the same Meili task
      assert :ok = run(j1)

      for j <- [j1, j2, j3] do
        assert_in_index(:public, j.args["doc"]["id"])
      end

      # swept siblings are cancelled so they never re-run
      assert job_state(j2.id) == "cancelled"
      assert job_state(j3.id) == "cancelled"
    end

    test ":closed boundary routes to the closed index" do
      user = fake_user!()
      post = doc(uid(Post), "Closed Doc")

      assert {:ok, :queued} = Search.maybe_index(post, "closed", current_user: user)
      [j | _] = all_enqueued(worker: IndexWorker, args: %{"index" => "closed"})
      assert :ok = run(j)

      assert_in_index(:closed, post["id"])
    end
  end

  describe "failure handling" do
    setup do: batched_meili_setup()

    test "a Meili failure does NOT cancel siblings (Oban will retry)" do
      # a doc with no id has no primary key — Meili rejects the whole batch
      {:ok, bad} =
        IndexWorker.enqueue(:public, %{
          "index_type" => "Bonfire.Data.Social.Post",
          "post_content" => %{"name" => "No PK"}
        })

      {:ok, sibling} = IndexWorker.enqueue(:public, doc(uid(Post), "Valid Sibling"))

      assert {:error, _} = run(bad)

      # sibling untouched (still pending), so a later run/retry can index it
      assert job_state(sibling.id) in ["scheduled", "available"]
    end
  end

  describe "synchronous fallback" do
    test "batched_indexing=false indexes synchronously, no job enqueued" do
      batched_meili_setup(batched: false, wait: true)
      user = fake_user!()
      post = doc(uid(Post), "Rollback Path")

      result = Search.maybe_index(post, "public", current_user: user)
      refute match?({:ok, :queued}, result)

      assert all_enqueued(worker: IndexWorker) == []
      assert_in_index(:public, post["id"])
    end

    test "wait_for_indexing=true bypasses the buffer (synchronous)" do
      batched_meili_setup(wait: true)
      user = fake_user!()
      post = doc(uid(Post), "Synchronous Title")

      result = Search.maybe_index(post, "public", current_user: user)
      refute match?({:ok, :queued}, result)

      assert all_enqueued(worker: IndexWorker) == []
      assert_in_index(:public, post["id"])
    end
  end

  describe "production path via Posts.publish" do
    setup do: batched_meili_setup()

    test "a real published post is buffered as a job, then indexed" do
      user = fake_user!()

      assert {:ok, post} =
               Posts.publish(
                 current_user: user,
                 post_attrs: %{
                   post_content: %{
                     name: "Published Via Epic",
                     html_body: "went through the :publish epic and Search.Acts.Queue"
                   }
                 },
                 boundary: "public"
               )

      assert [_ | _] = jobs = all_enqueued(worker: IndexWorker)
      assert :ok = run(hd(jobs))

      assert %{hits: [_ | _]} = Search.search("Published Via Epic")
      assert is_binary(uid(post))
    end
  end

  describe "safety nets / observability" do
    test "queue_configured?/0 returns a boolean and never raises (boot-safe)" do
      # Oban runs in testing mode here (no started queues), so this is `false`
      # under test even though `search_index` is in config/runtime.exs. What
      # matters: it must never raise, so the boot check can't crash startup.
      assert is_boolean(IndexWorker.queue_configured?())
    end

    test "a full batch emits backlog telemetry" do
      batched_meili_setup()
      Bonfire.Common.Config.put(:index_batch_max, 2, :bonfire_search)

      handler = "test-backlog-#{System.unique_integer([:positive])}"
      pid = self()

      :telemetry.attach(
        handler,
        [:bonfire_search, :index_queue, :backlog],
        fn _e, meas, meta, _ -> send(pid, {:backlog, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, j1} = IndexWorker.enqueue(:public, doc(uid(Post), "B1"))
      {:ok, _j2} = IndexWorker.enqueue(:public, doc(uid(Post), "B2"))
      {:ok, _j3} = IndexWorker.enqueue(:public, doc(uid(Post), "B3"))

      # batch_max=2 → j1 sweeps 1 sibling (a full batch), backlog remains
      assert :ok = run(j1)
      assert_receive {:backlog, %{size: _}, %{index: :public}}, 1000
    end
  end

  describe "non-indexable input" do
    setup do
      Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search)
      Bonfire.Common.Config.put(:batched_indexing, true, :bonfire_search)
      on_exit(fn -> Bonfire.Common.Config.put(:wait_for_indexing, false, :bonfire_search) end)
      :ok
    end

    test "an object with nothing indexable is not enqueued" do
      refute match?({:ok, :queued}, Search.maybe_index(%{}, "public", []))
      assert all_enqueued(worker: IndexWorker) == []
    end
  end

  describe "prepare_indexable_object passthrough (unit)" do
    test "already-formatted maps re-feed unchanged" do
      by_type = %{"index_type" => "Bonfire.Data.Social.Post", "post_content" => %{}}
      by_id = %{"id" => "01ABC", "post_content" => %{}}

      assert Bonfire.Search.Indexer.prepare_indexable_object(by_type) == by_type
      assert Bonfire.Search.Indexer.prepare_indexable_object(by_id) == by_id

      assert Bonfire.Search.Indexer.prepare_indexable_object([by_type, by_id]) ==
               [by_type, by_id]
    end
  end
end
