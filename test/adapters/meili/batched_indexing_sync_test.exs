# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.BatchedIndexingSyncTest do
  @moduledoc """
  Integration tests for batched indexing that require Meilisearch and global
  config mutation — cannot run async.
  """
  use Bonfire.Search.DataCase, async: false

  use Oban.Testing, repo: Bonfire.Common.Repo

  alias Bonfire.Search
  alias Bonfire.Search.Workers.IndexWorker
  alias Bonfire.Posts

  if Application.get_env(:bonfire_search, :adapter) == Bonfire.Search.MeiliLib do
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

      prev = prepare_indexes_for_tests(Bonfire.Search.MeiliLib)

      on_exit(fn ->
        reset_indexes_after_tests(Bonfire.Search.MeiliLib, prev)
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

        # run one public-index job — it sweeps all siblings into one batch
        [j | _] = all_enqueued(worker: IndexWorker, args: %{"index" => "public"})
        assert :ok = run(j)

        assert_in_index(:public, post["id"])
      end

      test "a burst is swept into ONE batch and the siblings are cancelled" do
        {:ok, j1} = IndexWorker.enqueue(:public, doc(uid(Post), "Burst 1"))
        {:ok, j2} = IndexWorker.enqueue(:public, doc(uid(Post), "Burst 2"))
        {:ok, j3} = IndexWorker.enqueue(:public, doc(uid(Post), "Burst 3"))

        assert :ok = run(j1)

        for j <- [j1, j2, j3] do
          assert_in_index(:public, j.args["doc"]["id"])
        end

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
        {:ok, bad} =
          IndexWorker.enqueue(:public, %{
            "index_type" => "Bonfire.Data.Social.Post",
            "post_content" => %{"name" => "No PK"}
          })

        {:ok, sibling} = IndexWorker.enqueue(:public, doc(uid(Post), "Valid Sibling"))

        assert {:error, _} = run(bad)

        assert job_state(sibling.id) in ["scheduled", "available"]
      end
    end

    describe "synchronous fallback: batched_indexing=false" do
      setup do: batched_meili_setup(batched: false, wait: true)

      test "indexes synchronously, no job enqueued" do
        user = fake_user!()
        post = doc(uid(Post), "Rollback Path")

        result = Search.maybe_index(post, "public", current_user: user)
        refute match?({:ok, :queued}, result)

        assert all_enqueued(worker: IndexWorker) == []
        assert_in_index(:public, post["id"])
      end
    end

    describe "synchronous fallback: wait_for_indexing=true" do
      setup do: batched_meili_setup(batched: true, wait: true)

      test "bypasses the buffer and indexes synchronously" do
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

    describe "observability" do
      setup do: batched_meili_setup()

      test "a full batch emits backlog telemetry" do
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

        assert :ok = run(j1)
        assert_receive {:backlog, %{size: _}, %{index: :public}}, 1000
      end
    end
  end
end
