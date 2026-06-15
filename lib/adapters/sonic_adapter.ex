# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Sonic do
  @moduledoc """
  Search adapter backed by Sonic (https://github.com/valeriansaliou/sonic).

  ## Sonic data model

  Sonic has three levels:

      collection / bucket / object_id → searchable text

  - **collection** — top-level namespace. Maps to Bonfire's `index_name`
    (e.g. `"test_public"`, `"prod_closed"`). Separates public from private search.
  - **bucket** — sub-namespace within a collection. Used for type-based filtering.
    An object is always pushed to `"all"` (for unfiltered search) AND to one bucket
    per `index_type` value (for tab-filtered search like "Posts" or "Users").
  - **object** — a single entry: an ID string + a text blob. No structured fields.

  ## Bucket strategy

  Because Sonic has no facet system, type filtering is implemented via buckets:

      PUSH collection "all"                     object_id  text   ← always
      PUSH collection "Bonfire.Data.Social.Post" object_id text   ← per index_type

  On search:
  - No `index_type` filter → QUERY the `"all"` bucket
  - With `index_type` filter → QUERY the specific bucket

  On delete, FLUSHO must mirror all buckets used during PUSH:
      FLUSHO collection "all"                      object_id
      FLUSHO collection "Bonfire.Data.Social.Post"  object_id

  ## Connections

  Each Sonic TCP connection is locked to one mode after `START`. The adapter
  maintains two supervised connections: one for INGEST, one for SEARCH.
  See `Bonfire.Search.Sonic.ConnectionPool`.

  ## PUSH semantics

  PUSH **appends** text — pushing the same object_id twice accumulates words.
  `put_documents/2` always does FLUSHO → PUSH per bucket to avoid stale text.

  ## Writes are immediately queryable

  Sonic's in-memory index is updated synchronously on PUSH; TRIGGER consolidate
  only flushes to disk. No `wait_for_task` or `wait_for_indexing` flag needed.
  """

  use Bonfire.Search.Adapter
  import Untangle
  use Bonfire.Common.Config
  use Bonfire.Common.E
  alias Bonfire.Common.Types
  alias Bonfire.Common.Enums

  @all_bucket "all"

  # pushed/queried with LANG(none) so Sonic doesn't stem or drop stopword-like usernames
  # (eg. "test"). Only the per-type buckets; the mixed "all" bucket keeps stemming, so
  # untyped global search can still miss such usernames.
  @identity_buckets ["Bonfire.Data.Identity.User", "Bonfire.Data.Identity.Character"]

  defp lang_opts(bucket) when bucket in @identity_buckets, do: [lang: "none"]
  defp lang_opts(_bucket), do: []

  # ---------------------------------------------------------------------------
  # Connection helpers
  # ---------------------------------------------------------------------------

  defp ingest_conn, do: Bonfire.Search.Sonic.Connection.ingest()
  defp search_conn, do: Bonfire.Search.Sonic.Connection.search()

  # ---------------------------------------------------------------------------
  # Adapter callbacks — supervision
  # ---------------------------------------------------------------------------

  @impl true
  def child_specs do
    [
      Supervisor.child_spec(
        {Bonfire.Search.Sonic.Connection,
         name: Bonfire.Search.Sonic.Connection.Ingest, mode: "ingest"},
        id: Bonfire.Search.Sonic.Connection.Ingest
      ),
      Supervisor.child_spec(
        {Bonfire.Search.Sonic.Connection,
         name: Bonfire.Search.Sonic.Connection.Search, mode: "search"},
        id: Bonfire.Search.Sonic.Connection.Search
      )
    ]
  end

  # ---------------------------------------------------------------------------
  # Adapter callbacks — search
  # ---------------------------------------------------------------------------

  @impl true
  def healthy? do
    case ingest_conn() do
      {:ok, conn} -> Sonix.ping(conn) == :ok
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def search(string, opts, _calculate_facets, filter_facets) when is_map(filter_facets) do
    index = e(opts, :index, nil) || :public
    index_name = Bonfire.Search.Indexer.index_name(index)
    bucket = filter_facets[:index_type] || filter_facets["index_type"] || @all_bucket
    do_search(string, index_name, bucket, opts)
  end

  def search(string, opts, _calculate_facets, _filter_facets) do
    search(string, opts)
  end

  @impl true
  def search(string, opts) when is_list(opts) or is_map(opts) do
    index = e(opts, :index, nil) || :public
    index_name = Bonfire.Search.Indexer.index_name(index)
    do_search(string, index_name, @all_bucket, opts)
  end

  @impl true
  def search(string, index) when is_binary(index) or is_atom(index) do
    index_name = Bonfire.Search.Indexer.index_name(index)
    do_search(string, index_name, @all_bucket, [])
  end

  @impl true
  def search_by_type(string, facets, opts \\ []) do
    bucket =
      List.wrap(facets)
      |> List.first()
      |> Types.module_to_str()
      |> then(&if &1 == "nil", do: @all_bucket, else: &1)

    index_name = Bonfire.Search.Indexer.index_name(:public)

    do_search(string, index_name, bucket, opts)
    |> e(:hits, [])
    |> Enums.filter_empty([])
  end

  defp do_search(string, collection, bucket, opts) do
    limit = e(opts, :limit, nil) || 20
    offset = e(opts, :offset, nil) || 0
    index = e(opts, :index, nil) || :public

    # quotes/newlines break Sonic's single-line QUERY command (see sanitize_for_sonic)
    string = sanitize_for_sonic(string)

    info("Sonic: searching for #{inspect(string)} in collection=#{collection} bucket=#{bucket}")

    with {:ok, conn} <- search_conn(),
         {:ok, ids} <-
           Sonix.query(
             conn,
             collection,
             bucket,
             string,
             [limit: limit, offset: offset] ++ lang_opts(bucket)
           ) do
      info("Sonic: query returned ids: #{inspect(ids)}")
      # NOTE: Sonic only returns object IDs, so raw hits only contain %{"id" => id}.
      # When searching a typed bucket (not "all"), we know the index_type from the bucket name.
      raw_hits =
        if bucket == @all_bucket do
          Enum.map(ids, &%{"id" => &1})
        else
          Enum.map(ids, &%{"id" => &1, "index_type" => bucket})
        end

      hits =
        if e(opts, :raw, false) do
          raw_hits
        else
          Bonfire.Search.prepare_hits(raw_hits, index, opts)
        end

      %{hits: hits, total: length(ids)}
    else
      err ->
        error(err, "Sonic search failed")
        %{hits: []}
    end
  end

  # ---------------------------------------------------------------------------
  # Adapter callbacks — indexing
  # ---------------------------------------------------------------------------

  @impl true
  def put_documents(doc, collection) when is_map(doc) do
    object_id = e(doc, "id", nil) || Types.uid(doc)

    cond do
      !object_id ->
        error(doc, "Sonic: cannot index document without an id")

      true ->
        text = extract_text(doc)

        if text == "" do
          warn(object_id, "Sonic: no text to index for object, skipping")
        else
          buckets = buckets_for(doc)

          info(
            "Sonic: indexing #{object_id} in buckets #{inspect(buckets)} with text: #{inspect(text)}"
          )

          for bucket <- buckets do
            with {:ok, conn} <- ingest_conn() do
              # Always flush first — PUSH appends, so we must clear stale text
              Sonix.flush(conn, collection, bucket, object_id)
              Sonix.push(conn, collection, bucket, object_id, text, lang_opts(bucket))
            else
              err -> error(err, "Sonic ingest connection failed for bucket #{bucket}")
            end
          end
        end

        {:ok, :indexed}
    end
  end

  def put_documents(docs, collection) when is_list(docs) do
    # Batch: build every FLUSHO+PUSH up front, then pipeline them over a single
    # connection checkout (Sonic has no bulk command, but allows pipelining).
    case build_commands(docs, collection) do
      [] ->
        {:ok, :indexed}

      commands ->
        with {:ok, conn} <- ingest_conn(),
             {:ok, results} <- Sonix.Tcp.pipeline(conn, commands) do
          for {:error, reason} <- results,
              do: error(reason, "Sonic: a pipelined ingest command failed")

          {:ok, :indexed}
        else
          err -> error(err, "Sonic batch indexing failed")
        end
    end
  end

  @doc """
  Maps prepared indexable docs into the flat list of Sonic ingest commands
  (`FLUSHO`+`PUSH` per doc × bucket). Pure — sends nothing. Public for testing.
  """
  def build_commands(docs, collection) when is_list(docs) do
    Enum.flat_map(docs, &doc_commands(&1, collection))
  end

  defp doc_commands(doc, collection) do
    object_id = e(doc, "id", nil) || Types.uid(doc)
    text = extract_text(doc)

    if object_id && text != "" do
      Enum.flat_map(
        buckets_for(doc),
        &Sonix.Modes.Ingest.flush_push_commands(collection, &1, object_id, text)
      )
    else
      []
    end
  end

  @impl true
  def delete(:all, collection) do
    # Flush entire collection — used to clear indexes in tests
    with {:ok, conn} <- ingest_conn() do
      Sonix.flush(conn, collection)
      {:ok, :deleted}
    end
  end

  def delete(object_id, collection) do
    # Must flush from every bucket the object was pushed to
    buckets = [@all_bucket | known_type_buckets()]

    for bucket <- buckets do
      with {:ok, conn} <- ingest_conn() do
        Sonix.flush(conn, collection, bucket, object_id)
      else
        err -> error(err, "Sonic delete failed for bucket #{bucket}")
      end
    end

    {:ok, :deleted}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp buckets_for(%{"index_type" => type}) when is_binary(type), do: [@all_bucket, type]
  defp buckets_for(%{"index_type" => types}) when is_list(types), do: [@all_bucket | types]
  defp buckets_for(_), do: [@all_bucket]

  defp known_type_buckets do
    # Best-effort: flush from all known types on delete.
    # If a type bucket was never pushed to, FLUSHO is a no-op.
    [
      "Bonfire.Data.Social.Post",
      "Bonfire.Data.Identity.User",
      "Bonfire.Tag.Tagged"
    ]
  end

  defp extract_text(doc) when is_map(doc) do
    Bonfire.Search.Indexer.main_searcheable_fields()
    |> Enum.flat_map(fn field_path ->
      keys = String.split(field_path, ".")

      case get_in(doc, keys) do
        nil -> []
        val when is_binary(val) and val != "" -> [val]
        vals when is_list(vals) -> Enum.filter(vals, &(is_binary(&1) and &1 != ""))
        _ -> []
      end
    end)
    |> Enum.map(&strip_html/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp strip_html(text) when is_binary(text) do
    Regex.replace(~r/<[^>]+>/, text, " ")
    |> sanitize_for_sonic()
  end

  # strip quotes + collapse whitespace/newlines that would break Sonic's line protocol
  defp sanitize_for_sonic(text) when is_binary(text) do
    text
    |> String.replace("\"", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sanitize_for_sonic(text), do: text
end
