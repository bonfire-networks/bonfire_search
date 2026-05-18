# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Workers.FlushWorker do
  @moduledoc """
  Drains `Bonfire.Search.IndexQueue` into Meilisearch in large per-index batches.

  Scheduled debounced (one unique job per index): a burst of buffered documents
  collapses into a single delayed flush, so Meilisearch receives one
  `documentAdditionOrUpdate` task of many documents instead of one task per
  document. This is the whole point — Meilisearch's per-task cost is index-wide
  and ~constant regardless of batch size, so batching is ~Nx cheaper.

  Failure handling: rows are deleted only after Meilisearch confirms the batch
  succeeded. On any failure the rows stay buffered and Oban retries the job with
  backoff (and the next debounced flush would pick them up regardless).
  """
  use Oban.Worker,
    queue: :search_index,
    max_attempts: 5

  import Untangle
  use Bonfire.Common.Config
  alias Bonfire.Search.IndexQueue

  @queue :search_index
  @default_batch_max 1000
  @default_debounce_seconds 5
  @default_warn_threshold 10_000

  @doc """
  Whether the Oban queue this worker runs on is actually configured.

  If it isn't, `schedule/2` still inserts jobs but nothing ever runs them, so
  the buffer grows silently and nothing gets indexed. Callers use this to fail
  loudly at boot instead.
  """
  def queue_configured? do
    case Oban.config() do
      %{queues: queues} when is_list(queues) -> Keyword.has_key?(queues, @queue)
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Schedule a debounced flush for `index` (`:public`/`:closed`)."
  def schedule(index, opts \\ []) when is_atom(index) do
    debounce =
      Bonfire.Common.Config.get_ext(
        :bonfire_search,
        :index_debounce_seconds,
        @default_debounce_seconds
      )

    schedule_in = Keyword.get(opts, :schedule_in, debounce)

    %{"index" => to_string(index)}
    |> new(
      queue: :search_index,
      schedule_in: schedule_in,
      # collapse repeated schedules within the debounce window into one job
      unique: [
        keys: [:index],
        period: max(debounce, 1),
        states: [:scheduled, :available, :executing]
      ]
    )
    |> Bonfire.Common.TestInstanceRepo.oban_insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"index" => index_str}}) do
    case IndexQueue.index_atom(index_str) do
      nil ->
        error(index_str, "FlushWorker: unknown index, dropping job")
        :ok

      index ->
        flush_one_batch(index)
    end
  end

  defp flush_one_batch(index) do
    batch_max =
      Bonfire.Common.Config.get_ext(:bonfire_search, :index_batch_max, @default_batch_max)

    case IndexQueue.claim_batch(index, batch_max) do
      [] ->
        :ok

      rows ->
        docs = Enum.map(rows, & &1.document)
        ids = Enum.map(rows, & &1.id)
        adapter = Bonfire.Search.adapter()

        with {:ok, task} <-
               Bonfire.Search.Indexer.maybe_index_object(docs, index)
               |> debug("FlushWorker: batched #{length(docs)} docs into #{index}"),
             {:ok, _done} <- adapter.wait_for_task(task) do
          IndexQueue.delete_ids(ids)

          # cheap, no extra query: how big a batch we just shipped
          :telemetry.execute(
            [:bonfire_search, :index_queue, :flush],
            %{batch_size: length(rows)},
            %{index: index}
          )

          # a full batch means there's very likely more buffered — drain it now
          # rather than waiting for the next debounce window. A short batch
          # means we drained the visible backlog; any rows inserted during the
          # multi-second Meili call carry their own debounced flush, so no COUNT
          # query is needed in that case.
          if length(rows) >= batch_max do
            # only here (backlog mode) do we pay a COUNT — exactly when the
            # number is worth knowing — to surface a growing backlog loudly
            backlog = IndexQueue.count(index)

            :telemetry.execute(
              [:bonfire_search, :index_queue, :backlog],
              %{size: backlog},
              %{index: index}
            )

            threshold =
              Bonfire.Common.Config.get_ext(
                :bonfire_search,
                :index_queue_warn_threshold,
                @default_warn_threshold
              )

            if backlog >= threshold do
              warn(
                backlog,
                "Search index buffer backlog for #{index} exceeds #{threshold} — Meilisearch slow or unhealthy?"
              )
            end

            schedule(index, schedule_in: 0)
          end

          :ok
        else
          e ->
            # leave rows buffered; let Oban retry with backoff
            error(e, "FlushWorker: indexing batch failed, will retry")
            {:error, e}
        end
    end
  end
end
