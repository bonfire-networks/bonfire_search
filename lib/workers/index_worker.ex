# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Workers.IndexWorker do
  @moduledoc """
  Batched Meilisearch indexing that uses Oban itself as the buffer.

  Each published/federated object enqueues one job carrying its prepared
  document, with a short debounce delay. When the first job of a debounce
  window runs, it *sweeps* every sibling job for the same index that is still
  waiting, indexes the whole set in **one** Meilisearch task, and cancels the
  swept siblings so they don't run again.

  Why: a single-document `documentAdditionOrUpdate` on a large Meili index
  triggers an index-wide word/prefix rebuild (~seconds) whose cost is ~fixed
  regardless of how many documents are in the task. Collapsing N per-object
  jobs into one Meili task pays that fixed cost once per batch instead of once
  per document — without a separate buffer table (Oban's own durable job table
  is the buffer; restarts resume it automatically).
  """
  @queue_atom :search_index

  use Oban.Worker,
    queue: @queue_atom,
    max_attempts: 5

  import Untangle
  import Ecto.Query
  use Bonfire.Common.Config
  use Bonfire.Common.Repo

  # string form, for matching the `oban_jobs.queue` column
  @queue Atom.to_string(@queue_atom)
  # the waiting states a sibling can still be swept from
  @waiting ["available", "scheduled"]
  @default_batch_max 1000
  @default_debounce_seconds 5
  @default_warn_threshold 10_000

  @doc "Buffer a prepared indexable doc for `index` by enqueuing a debounced job."
  def enqueue(index, document) when is_atom(index) and is_map(document) do
    debounce =
      Bonfire.Common.Config.get_ext(
        :bonfire_search,
        :index_debounce_seconds,
        @default_debounce_seconds
      )

    %{"index" => to_string(index), "doc" => document}
    |> new(schedule_in: debounce)
    |> Bonfire.Common.TestInstanceRepo.oban_insert()
  end

  @doc """
  Whether the `search_index` Oban queue is actually configured.

  If it isn't, jobs are still inserted but nothing ever runs them — the buffer
  grows and nothing gets indexed, silently. Callers use this to fail loudly at
  boot instead. Never raises (boot-safe).
  """
  def queue_configured? do
    case Oban.config() do
      %{queues: queues} when is_list(queues) -> Keyword.has_key?(queues, @queue_atom)
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"index" => index_str, "doc" => doc}}) do
    case Bonfire.Search.normalise_index(index_str) do
      index when index in [:public, :closed] ->
        flush_batch(index, index_str, doc, job_id)

      _ ->
        error(index_str, "IndexWorker: unknown index #{inspect(index_str)}, dropping job")
        :ok
    end
  end

  # Jobs still waiting to index `index_str`. The search_index queue is exclusive
  # to this worker, so queue + state + args index is enough to find siblings
  # (no fragile worker-name match). Shared by the sweep and the backlog count.
  defp pending_for_index(index_str) do
    from(j in Oban.Job,
      where:
        j.queue == @queue and j.state in @waiting and
          fragment("? ->> 'index' = ?", j.args, ^index_str)
    )
  end

  defp flush_batch(index, index_str, doc, job_id) do
    batch_max =
      Bonfire.Common.Config.get_ext(:bonfire_search, :index_batch_max, @default_batch_max)

    siblings =
      pending_for_index(index_str)
      |> where([j], j.id != ^job_id)
      |> order_by([j], asc: j.id)
      |> limit(^(batch_max - 1))
      |> repo().all()

    sibling_ids = Enum.map(siblings, & &1.id)
    docs = [doc | Enum.map(siblings, &Map.get(&1.args, "doc"))]
    adapter = Bonfire.Search.adapter()

    with {:ok, task} <-
           Bonfire.Search.Indexer.maybe_index_object(docs, index)
           |> debug("IndexWorker: batched #{length(docs)} docs into #{index}"),
         {:ok, _done} <- adapter.wait_for_task(task) do
      # the swept siblings' docs are indexed now; stop them re-running
      if sibling_ids != [] do
        Oban.cancel_all_jobs(
          Bonfire.Common.TestInstanceRepo.oban_name(),
          from(j in Oban.Job, where: j.id in ^sibling_ids)
        )
      end

      :telemetry.execute(
        [:bonfire_search, :index_queue, :flush],
        %{batch_size: length(docs)},
        %{index: index}
      )

      # a full sweep means there's likely more waiting — worth the COUNT
      if length(docs) >= batch_max, do: emit_backlog(index, index_str)
      :ok
    else
      e ->
        # leave siblings untouched; Oban retries this job with backoff. Emit the
        # backlog here too: during a Meili outage flushes only ever fail, so
        # this is the *only* path that can observe a growing queue.
        error(e, "IndexWorker: indexing batch failed, will retry")
        emit_backlog(index, index_str)
        {:error, e}
    end
  end

  defp emit_backlog(index, index_str) do
    pending = pending_for_index(index_str) |> repo().aggregate(:count)

    :telemetry.execute(
      [:bonfire_search, :index_queue, :backlog],
      %{size: pending},
      %{index: index}
    )

    threshold =
      Bonfire.Common.Config.get_ext(
        :bonfire_search,
        :index_queue_warn_threshold,
        @default_warn_threshold
      )

    if pending >= threshold do
      warn(
        pending,
        "Search index backlog for #{index} exceeds #{threshold} — Meilisearch slow or unhealthy?"
      )
    end

    :ok
  end
end
