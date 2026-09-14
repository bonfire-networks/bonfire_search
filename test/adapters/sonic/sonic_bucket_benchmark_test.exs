if Application.get_env(:bonfire_search, :adapter) == Bonfire.Search.Sonic do
  defmodule Bonfire.Search.SonicBucketBenchmarkTest do
    @moduledoc """
    Benchmarks Sonic bucket layouts to gate two decisions: whether untyped global search should drop the `"all"` bucket in favour of fanning out over per-type buckets, and whether group-scoped search should fan out over per-category buckets (variant A) or query a denormalised tree bucket (variant B).

    Seeds the same synthetic corpus into three layouts in throwaway `bench_*` collections on the local Sonic, consolidates, then measures query latency (Benchee), hit counts, ingest time and store growth per layout. Fan-out jobs run both sequentially (one exclusive checkout per QUERY, today's production path) and in parallel across a pool of search connections, which is the real parallelism unit: Sonic executes each channel's commands inline in that channel's thread, so pipelining on one channel could only save ~0.3ms round trips.

    Run with:

        SEARCH_ADAPTER=sonic just test-backend extensions/bonfire_search/test/adapters/sonic/sonic_bucket_benchmark_test.exs --only benchmark

    Knobs: `SONIC_BENCH_SIZES` (comma-separated corpus sizes, default `10000,100000`) and `SONIC_BENCH_QUICK=1` (short warmup/time, for smoke-testing the harness).
    """

    use ExUnit.Case, async: false

    alias Bonfire.Search.Sonic

    @moduletag :benchmark
    @moduletag timeout: :infinity

    # terms planted at controlled selectivity; distinct from the lorem filler vocabulary
    @terms %{"rare" => "benchrareword", "medium" => "benchmediumword", "common" => "benchcommonword"}

    # 8 type buckets with a realistic skew (posts dominate), thresholds over a 0..99 draw
    @typed_skew [
      {"Bonfire.Data.Social.Post", 55},
      {"Bonfire.Data.Identity.User", 70},
      {"Bonfire.Data.Identity.Character", 80},
      {"Bonfire.Files.Media", 88},
      {"Bonfire.Classify.Category", 93},
      {"Bonfire.Tag.Tagged", 97},
      {"Bonfire.Data.Social.Message", 99},
      {"other", 100}
    ]

    @topics 100
    @limit 20
    # max pool started; jobs take subsets, so pool size becomes a measured axis
    @max_pool 16
    # simulated simultaneous searches for the inter-user concurrency jobs
    @conc_users 32

    test "bucket layouts: fan-out vs single bucket" do
      for size <- corpus_sizes() do
        run_for_corpus(size)
      end
    end

    defp run_for_corpus(size) do
      run_id = System.unique_integer([:positive])
      collections = %{
        monolith: "bench_#{size}_monolith_#{run_id}",
        typed: "bench_#{size}_typed_#{run_id}",
        scoped: "bench_#{size}_scoped_#{run_id}"
      }

      on_exit(fn ->
        for {_, coll} <- collections, do: Sonic.with_ingest(&Sonix.flush(&1, coll))
      end)

      IO.puts("\n== Sonic bucket benchmark, corpus #{size} ==\n")
      print_env_info()

      seed_report =
        for layout <- [:monolith, :typed, :scoped] do
          before_bytes = store_bytes()
          {ms, pushed} = seed(layout, collections[layout], size)
          consolidate()
          {layout, ms, pushed, delta_bytes(before_bytes, store_bytes())}
        end

      jobs = jobs(collections)

      IO.puts("-- hit counts at LIMIT(#{@limit}) per bucket --")

      for {name, fun} <- jobs, {term_label, term} <- @terms do
        IO.puts("  #{name} / #{term_label}: #{length(fun.(term))} hits")
      end

      IO.puts("\n-- ingest & store growth per layout --")

      for {layout, ms, pushed, delta} <- seed_report do
        IO.puts("  #{layout}: #{pushed} pushes in #{ms}ms, store +#{delta}")
      end

      {warmup, time} =
        if System.get_env("SONIC_BENCH_QUICK") in ["1", "true"], do: {0.5, 1}, else: {2, 5}

      Benchee.run(
        Map.new(jobs, fn {name, fun} -> {name, fn term -> fun.(term) end} end),
        inputs: @terms,
        warmup: warmup,
        time: time,
        print: [fast_warning: false]
      )
    end

    # ---------------------------------------------------------------------------
    # Layouts & seeding
    # ---------------------------------------------------------------------------

    # Returns {milliseconds, push_count}. Deterministic per (layout, size).
    # Term planting and bucket assignment MUST be drawn independently: a correlated modulo scheme once put a planted term in 100% of some buckets' docs, and Sonic's IDF filter (query_minimum_term_idf_default, active from 100 objects per bucket) then dropped the term in those buckets entirely as a stopword. Text draws happen before bucket draws with a fixed count per doc, so the corpus is identical across layouts under the same seed.
    defp seed(layout, collection, size) do
      :rand.seed(:exsss, {42, size, 1})

      commands =
        Enum.flat_map(1..size, fn i ->
          text = doc_text(size)

          for bucket <- doc_buckets(layout) do
            Sonix.Modes.Ingest.push_command(collection, bucket, "obj-#{i}", text)
          end
        end)

      {micros, :ok} =
        :timer.tc(fn ->
          # chunked so no single connection checkout runs unreasonably long
          commands
          |> Enum.chunk_every(2_000)
          |> Enum.each(fn chunk ->
            {:ok, _results} =
              Sonic.with_ingest(&Sonix.Tcp.pipeline(&1, chunk), to_timeout(minute: 5))
          end)

          :ok
        end)

      {div(micros, 1000), length(commands)}
    end

    defp doc_buckets(:monolith), do: ["all"]

    defp doc_buckets(:typed) do
      r = :rand.uniform(100) - 1
      {bucket, _} = Enum.find(@typed_skew, fn {_, threshold} -> r < threshold end)
      [bucket]
    end

    # 20% direct group content, the rest spread over topics; every doc also lands in the
    # denormalised tree bucket, which is exactly variant B's extra storage
    defp doc_buckets(:scoped) do
      own = if :rand.uniform(5) == 1, do: "scope_group", else: "topic_#{:rand.uniform(@topics)}"
      [own, "tree"]
    end

    # ~50 lorem words of filler (natural-language-shaped, so Sonic's stemming and stopword handling do real work; caveat: lorem's ~200-word vocabulary makes every filler word a common one), plus terms planted at ~30% / ~1% / ~10-per-corpus selectivity via independent draws, so no bucket ends up with a term in ~all of its docs (which Sonic's IDF filter would drop). Deterministic because Faker draws from :rand, seeded in seed/3, with a fixed draw count per doc.
    defp doc_text(size) do
      planted =
        List.flatten([
          if(:rand.uniform() < 0.3, do: [@terms["common"]], else: []),
          if(:rand.uniform() < 0.01, do: [@terms["medium"]], else: []),
          if(:rand.uniform() < 10 / size, do: [@terms["rare"]], else: [])
        ])

      Enum.join(planted ++ Faker.Lorem.words(50), " ")
    end

    # ---------------------------------------------------------------------------
    # Query jobs
    # ---------------------------------------------------------------------------

    defp jobs(collections) do
      pool = start_search_pool!(@max_pool)
      p = fn n -> Enum.take(pool, n) end
      typed = Enum.map(@typed_skew, &elem(&1, 0))
      scope25 = scope_buckets(25)

      [
        # isolates the fixed per-command overhead (connection GenServer, TCP round trip, docker port proxying) from Sonic's actual query work: every QUERY pays at least this
        {"ping_baseline",
         fn _term ->
           :ok = Sonic.with_search(&Sonix.ping/1)
           []
         end},
        {"all_single", query_job(collections.monolith, ["all"])},
        {"tree_single", query_job(collections.scoped, ["tree"])},
        # the escalation path's building block: prefix completion against the consolidated FST.
        # SUGGEST is FST-only, so this also proves suggestions exist at all after consolidation
        {"suggest_single",
         fn term ->
           case Sonic.with_search(
                  &Sonix.suggest(&1, collections.monolith, "all", String.slice(term, 0, 6),
                    limit: 5
                  )
                ) do
             {:ok, words} -> words
             other -> flunk("suggest failed: #{inspect(other)}")
           end
         end},
        # the full client-side escalation flow: thin exact QUERY for a partial word, SUGGEST to
        # complete it, re-QUERY with the best completion. Hit count shows whether the completion
        # actually recovers the planted term's results
        {"escalate_partial_word",
         fn term ->
           partial = String.slice(term, 0, byte_size(term) - 3)

           {:ok, _thin} =
             Sonic.with_search(&Sonix.query(&1, collections.monolith, "all", partial, limit: @limit))

           {:ok, words} =
             Sonic.with_search(&Sonix.suggest(&1, collections.monolith, "all", partial, limit: 5))

           case words do
             [best | _] ->
               {:ok, ids} =
                 Sonic.with_search(&Sonix.query(&1, collections.monolith, "all", best, limit: @limit))

               ids

             [] ->
               []
           end
         end},
        {"typed_fanout_seq", query_job(collections.typed, typed)},
        {"typed_fanout_par8", parallel_query_job(collections.typed, typed, p.(8))},
        {"scope_fanout_seq_5", query_job(collections.scoped, scope_buckets(5))},
        {"scope_fanout_seq_25", query_job(collections.scoped, scope25)},
        # pool-size axis on the representative 26-bucket fan-out
        {"scope_fanout_par2_25", parallel_query_job(collections.scoped, scope25, p.(2))},
        {"scope_fanout_par4_25", parallel_query_job(collections.scoped, scope25, p.(4))},
        {"scope_fanout_par8_25", parallel_query_job(collections.scoped, scope25, p.(8))},
        {"scope_fanout_par16_25", parallel_query_job(collections.scoped, scope25, p.(16))},
        {"scope_fanout_par8_100",
         parallel_query_job(collections.scoped, scope_buckets(@topics), p.(8))},
        # inter-user concurrency: many simultaneous single-bucket searches contending for the pool
        {"conc#{@conc_users}_pool2", concurrent_users_job(collections.monolith, p.(2))},
        {"conc#{@conc_users}_pool8", concurrent_users_job(collections.monolith, p.(8))},
        {"conc#{@conc_users}_pool16", concurrent_users_job(collections.monolith, p.(16))}
      ]
    end

    # M simultaneous single-bucket searches spread round-robin over the pool: the inter-user concurrency story, as opposed to the fan-out jobs' intra-search parallelism. Wall time approximates how long the slowest of M concurrent users waits.
    defp concurrent_users_job(collection, pool) do
      pool_size = length(pool)

      fn term ->
        1..@conc_users
        |> Enum.map(fn i ->
          Task.async(fn ->
            case Sonix.Connection.command(
                   Enum.at(pool, rem(i, pool_size)),
                   &Sonix.query(&1, collection, "all", term, limit: @limit)
                 ) do
              {:ok, ids} -> ids
              other -> raise "concurrent query failed: #{inspect(other)}"
            end
          end)
        end)
        |> Task.await_many(60_000)
        |> List.flatten()
        |> Enum.uniq()
      end
    end

    defp scope_buckets(n), do: ["scope_group" | Enum.map(1..n, &"topic_#{&1}")]

    # sequential fan-out over the shared adapter connection, one exclusive checkout per QUERY:
    # what production does today
    defp query_job(collection, buckets) do
      fn term ->
        Enum.flat_map(buckets, fn bucket ->
          case Sonic.with_search(&Sonix.query(&1, collection, bucket, term, limit: @limit)) do
            {:ok, ids} -> ids
            other -> flunk("query #{collection}/#{bucket} failed: #{inspect(other)}")
          end
        end)
      end
    end

    # parallel fan-out across a pool of search connections. Sonic executes each channel's commands inline in that channel's thread (see core/src/executor dispatch), so one channel is strictly sequential and connections are the unit of parallelism
    defp parallel_query_job(collection, buckets, pool) do
      pool_size = length(pool)

      fn term ->
        buckets
        |> Enum.with_index()
        |> Enum.group_by(fn {_bucket, i} -> rem(i, pool_size) end, fn {bucket, _} -> bucket end)
        |> Task.async_stream(
          fn {slot, slot_buckets} ->
            conn = Enum.at(pool, slot)

            Enum.flat_map(slot_buckets, fn bucket ->
              case Sonix.Connection.command(
                     conn,
                     &Sonix.query(&1, collection, bucket, term, limit: @limit)
                   ) do
                {:ok, ids} -> ids
                other -> raise "query #{collection}/#{bucket} failed: #{inspect(other)}"
              end
            end)
          end,
          max_concurrency: pool_size,
          ordered: false,
          timeout: 60_000
        )
        |> Enum.flat_map(fn {:ok, ids} -> ids end)
      end
    end

    defp start_search_pool!(size) do
      for n <- 1..size do
        name = Module.concat(__MODULE__, "SearchPool#{n}")

        case start_supervised(
               {Sonix.Connection, Sonic.connection_opts("search", name: name)},
               id: name
             ) do
          {:ok, _} -> name
          # already started by a previous corpus-size iteration of the same test
          {:error, {:already_started, _}} -> name
          {:error, {{:already_started, _}, _}} -> name
        end
      end
    end

    # ---------------------------------------------------------------------------
    # Environment helpers
    # ---------------------------------------------------------------------------

    # saturation in the pool jobs is only interpretable against the available CPU budget
    defp print_env_info do
      case System.cmd("docker", ["info", "--format", "{{.NCPU}}"], stderr_to_stdout: true) do
        {ncpu, 0} ->
          IO.puts(
            "docker VM CPUs: #{String.trim(ncpu)}, BEAM schedulers: #{System.schedulers_online()}"
          )

        _ ->
          IO.puts("BEAM schedulers: #{System.schedulers_online()}")
      end
    rescue
      _ -> :ok
    end

    defp corpus_sizes do
      System.get_env("SONIC_BENCH_SIZES", "10000,100000")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_integer(String.trim(&1)))
    end

    # FST consolidation runs on a timer (consolidate_after), so trigger it explicitly and measure steady state rather than the in-memory journal
    defp consolidate do
      opts = Sonic.connection_opts("control")

      with {:ok, conn} <- Sonix.init(opts[:host], opts[:port]),
           {:ok, _} <- Sonix.start(conn, "control", opts[:password]),
           :ok <- Sonix.trigger(conn, "consolidate") do
        Sonix.quit(conn)
        # give the FST rebuild a moment to land on disk before measuring
        Process.sleep(500)
      else
        other -> IO.puts("  (consolidate skipped: #{inspect(other)})")
      end
    end

    # Store size via a throwaway alpine mounting the sonic data volume: the sonic image is distroless (no shell, no du), and on macOS the volume mountpoint lives inside the VM.
    # Best-effort: returns nil when docker or the volume can't be found.
    defp store_bytes do
      with {vols, 0} <- System.cmd("docker", ["volume", "ls", "-q"], stderr_to_stdout: true),
           vol when is_binary(vol) <-
             vols |> String.split("\n", trim: true) |> Enum.find(&(&1 =~ "sonic")),
           {out, 0} <-
             System.cmd(
               "docker",
               ["run", "--rm", "-v", "#{vol}:/data:ro", "alpine", "du", "-sk", "/data"],
               stderr_to_stdout: true
             ),
           [kb | _] <- String.split(out, "\t") do
        String.to_integer(String.trim(kb)) * 1024
      else
        _ -> nil
      end
    rescue
      _ -> nil
    end

    defp delta_bytes(before_bytes, after_bytes)
         when is_integer(before_bytes) and is_integer(after_bytes),
         do: "#{Float.round((after_bytes - before_bytes) / 1_048_576, 2)}MB"

    defp delta_bytes(_, _), do: "n/a (no docker volume access)"
  end
end
