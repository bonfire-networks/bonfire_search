# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.IndexQueue do
  @moduledoc """
  Durable buffer of documents pending indexing in Meilisearch.

  Why this exists: Meilisearch processes each `documentAdditionOrUpdate` task
  by re-running index-wide work (word dictionary/prefix structures) that scales
  with the *whole* index, not with the docs in the task. So adding documents one
  at a time on a large index costs ~the same per document as a large batch costs
  for the whole batch. Federation feeds documents in one at a time and the
  inflow never builds enough queue depth for Meilisearch's own auto-batcher to
  coalesce them (see Meilisearch auto-batching spec). We therefore accumulate
  here and flush in large per-index batches via `Bonfire.Search.Workers.FlushWorker`.

  Indexing is already eventually-consistent in production (`wait_for_indexing`
  is only set in tests), so the small added buffering delay changes no contract.
  """
  use Ecto.Schema
  import Ecto.Query
  use Bonfire.Common.Repo
  alias Bonfire.Search.IndexQueue

  @primary_key {:id, :id, autogenerate: true}
  schema "bonfire_search_index_queue" do
    field(:index, :string)
    field(:document, :map)
    field(:inserted_at, :utc_datetime_usec)
  end

  @main_indexes [:public, :closed]

  @doc "Buffer a prepared indexable document for the given index (`:public`/`:closed`)."
  def enqueue(index, document) when is_atom(index) and is_map(document) do
    repo().insert(%IndexQueue{
      index: to_string(index),
      document: document,
      inserted_at: DateTime.utc_now()
    })
  end

  @doc """
  Read up to `limit` buffered rows for `index`, oldest first.

  No row locking: a `documentAdditionOrUpdate` in Meilisearch is keyed by the
  document id, so re-sending the same document is an idempotent overwrite. If
  two flush runs ever overlap (bounded: queue concurrency 1 + debounced unique
  job) the worst case is a little duplicated work, never corruption — much
  cheaper than holding DB row locks across the multi-second Meili call.
  """
  def claim_batch(index, limit) when is_atom(index) and is_integer(limit) do
    index_str = to_string(index)

    from(q in IndexQueue,
      where: q.index == ^index_str,
      order_by: [asc: q.inserted_at],
      limit: ^limit
    )
    |> repo().all()
  end

  @doc "Delete drained rows by id after a successful Meili batch."
  def delete_ids([]), do: {0, nil}

  def delete_ids(ids) when is_list(ids) do
    from(q in IndexQueue, where: q.id in ^ids)
    |> repo().delete_all()
  end

  @doc "Distinct indexes that currently have buffered rows (used on startup drain)."
  def pending_indexes do
    from(q in IndexQueue, select: q.index, distinct: true)
    |> repo().all()
    |> Enum.flat_map(&List.wrap(index_atom(&1)))
  end

  @doc "How many rows are still buffered for `index` (for the backlog follow-up trigger)."
  def count(index) when is_atom(index) do
    index_str = to_string(index)
    repo().aggregate(from(q in IndexQueue, where: q.index == ^index_str), :count)
  end

  @doc """
  Map a stored index string back to its atom, safely (`nil` if unrecognised).

  Reuses the canonical `Bonfire.Search.normalise_index/1` mapping rather than
  a duplicate whitelist, but guards membership so an unexpected stored value
  yields `nil` (the flush worker drops the job) instead of being passed through.
  """
  def index_atom(index_str) do
    case Bonfire.Search.normalise_index(index_str) do
      index when index in @main_indexes -> index
      _ -> nil
    end
  end
end
