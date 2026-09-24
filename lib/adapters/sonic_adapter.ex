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
    An object is always pushed to `"all"` (for unfiltered search) AND to one bucket per `index_type` value (for tab-filtered search like "Posts" or "Users").
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

  Each Sonic TCP connection is locked to one mode after `START`. The adapter maintains two supervised connections, one for INGEST and one for SEARCH, each owned by a `Sonix.Connection` that runs commands on it one at a time. Reach them via `with_ingest/1` and `with_search/1`.

  ## PUSH semantics

  PUSH **appends** text — pushing the same object_id twice accumulates words.
  `put_documents/2` always does FLUSHO → PUSH per bucket to avoid stale text.

  ## Writes are immediately queryable

  Sonic's in-memory index is updated synchronously on PUSH; TRIGGER consolidate only flushes to disk. No `wait_for_task` or `wait_for_indexing` flag needed.
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
  # Connections
  # ---------------------------------------------------------------------------

  @ingest __MODULE__.Ingest
  @search __MODULE__.Search

  @doc """
  Runs `fun` with the INGEST (or SEARCH) connection, exclusively.

  Commands go through `Sonix.Connection` one at a time, because a Sonic command spans a write and a separate read, so concurrent callers sharing a socket would otherwise read each other's responses.
  """
  def with_ingest(fun, timeout \\ nil),
    do: Sonix.Connection.command(@ingest, fun, timeout || command_timeout())

  def with_search(fun, timeout \\ nil),
    do: Sonix.Connection.command(@search, fun, timeout || command_timeout())

  @doc "Options for a `Sonix.Connection` in the given mode, read from app config."
  def connection_opts(mode, extra \\ []) do
    Keyword.merge(
      [
        mode: mode,
        host: Config.get_ext(:bonfire_search, [__MODULE__, :host], "localhost"),
        port: Config.get_ext(:bonfire_search, [__MODULE__, :port], 1491),
        password: Config.get_ext(:bonfire_search, [__MODULE__, :password], "SecretPassword"),
        # must stay under `channel.tcp_timeout` in sonic.cfg, which is 300s
        keepalive_interval:
          Config.get_ext(
            :bonfire_search,
            [__MODULE__, :keepalive_interval],
            to_timeout(second: 120)
          )
      ],
      extra
    )
  end

  # generous by default because the batch ingest path pipelines a whole window of commands
  defp command_timeout do
    Config.get_ext(:bonfire_search, [__MODULE__, :command_timeout], to_timeout(second: 30))
  end

  # ---------------------------------------------------------------------------
  # Adapter callbacks — supervision
  # ---------------------------------------------------------------------------

  @impl true
  def child_specs do
    for {id, mode} <- [{@ingest, "ingest"}, {@search, "search"}] do
      Supervisor.child_spec({Sonix.Connection, connection_opts(mode, name: id)}, id: id)
    end
  end

  # ---------------------------------------------------------------------------
  # Adapter callbacks — search
  # ---------------------------------------------------------------------------

  @impl true
  def healthy? do
    with_ingest(&Sonix.ping/1) == :ok
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

    # quotes/newlines break Sonic's single-line QUERY command (see sanitize)
    string = sanitize(string)

    info("Sonic: searching for #{inspect(string)} in collection=#{collection} bucket=#{bucket}")

    with {:ok, ids} <-
           with_search(
             &Sonix.query(
               &1,
               collection,
               bucket,
               string,
               [limit: limit, offset: offset] ++ lang_opts(bucket)
             ),
             e(opts, :timeout, nil)
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
            # both run in one checkout so no other writer can land between them
            with_ingest(fn conn ->
              # Always flush first — PUSH appends, so we must clear stale text
              Sonix.flush(conn, collection, bucket, object_id)
              Sonix.push(conn, collection, bucket, object_id, text, lang_opts(bucket))
            end)
          end
        end

        {:ok, :indexed}
    end
  end

  def put_documents(docs, collection) when is_list(docs) do
    # Batch: build every FLUSHO+PUSH up front, then pipeline them over a single connection checkout (Sonic has no bulk command, but allows pipelining).
    case ingest_commands(docs, collection) do
      [] ->
        {:ok, :indexed}

      commands ->
        debug(commands, "Sonic: batch indexing #{length(commands)} commands into #{collection}")

        with {:ok, results} <- with_ingest(&Sonix.Tcp.pipeline(&1, commands)) do
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
  def ingest_commands(docs, collection) when is_list(docs) do
    Enum.flat_map(docs, &ingest_commands_for_doc(&1, collection))
  end

  defp ingest_commands_for_doc(doc, collection) do
    object_id = e(doc, "id", nil) || Types.uid(doc)
    text = extract_text(doc)

    if object_id && text != "" do
      Enum.flat_map(buckets_for(doc), fn bucket ->
        # pass lang_opts so identity buckets get LANG(none), matching the single-doc path
        Sonix.Modes.Ingest.flush_push_commands(
          collection,
          bucket,
          object_id,
          text,
          lang_opts(bucket)
        )
      end)
    else
      []
    end
  end

  @impl true
  def delete(:all, collection) do
    # Flush entire collection — used to clear indexes in tests
    with {:ok, _count} <- with_ingest(&Sonix.flush(&1, collection)) do
      {:ok, :deleted}
    end
  end

  def delete(object_id, collection) do
    # Must flush from every bucket the object was pushed to
    buckets = [@all_bucket | known_type_buckets()]

    for bucket <- buckets do
      with_ingest(&Sonix.flush(&1, collection, bucket, object_id))
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
    |> Enum.join(" ")
    |> sanitize_for_indexing()
  end

  # strip HTML to plain text (reusing the shared Text helper), then make it Sonic-safe
  defp sanitize_for_indexing(text) when is_binary(text) do
    Bonfire.Common.Text.text_only(text)
    |> sanitize()
  end

  defp sanitize_for_indexing(text), do: text

  # Sonic's QUERY/PUSH are single-line and quote-delimited, so strip `"` (Sonic-specific);
  # and whitespace/newline collapsing with the generic `Text.normalize_whitespace/1`.
  defp sanitize(text) when is_binary(text) do
    text
    |> String.replace("\"", " ")
    |> Bonfire.Common.Text.normalize_whitespace()
  end

  defp sanitize(text), do: text
end
