defmodule Bonfire.Search.Repo.Migrations.CreateSearchIndexQueue do
  @moduledoc """
  Durable buffer for documents waiting to be (re)indexed in Meilisearch.

  Rows accumulate here as objects are published/federated, and a debounced
  Oban worker drains them per-index in large batches. This exists because
  Meilisearch pays a fixed, index-wide ~per-batch cost regardless of batch
  size, so single-document additions are pathologically expensive on a large
  index — batching amortises that cost.
  """
  use Ecto.Migration

  def up do
    create_if_not_exists table(:bonfire_search_index_queue) do
      # which Meili index this doc belongs to ("public" | "closed")
      add(:index, :string, null: false)
      # the already-formatted indexable document (what gets PUT to Meili)
      add(:document, :map, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    # drain order + per-index batching
    create_if_not_exists(index(:bonfire_search_index_queue, [:index, :inserted_at]))
  end

  def down do
    drop_if_exists(table(:bonfire_search_index_queue))
  end
end
