defmodule Bonfire.Search.BatchedIndexingTest do
  @moduledoc """
  Pure unit tests for the batched indexing path that don't touch Meilisearch
  and can run concurrently.
  """
  use Bonfire.Search.DataCase, async: true
  use Oban.Testing, repo: Bonfire.Common.Repo

  alias Bonfire.Search
  alias Bonfire.Search.Workers.IndexWorker

  if Application.get_env(:bonfire_search, :adapter) == Bonfire.Search.MeiliLib do
    describe "non-indexable input" do
      setup do
        Process.put([:bonfire_search, :wait_for_indexing], false)
        Process.put([:bonfire_search, :batched_indexing], true)
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

    describe "safety nets (no Meili)" do
      test "queue_configured?/0 returns a boolean and never raises (boot-safe)" do
        assert is_boolean(IndexWorker.queue_configured?())
      end
    end
  end
end
