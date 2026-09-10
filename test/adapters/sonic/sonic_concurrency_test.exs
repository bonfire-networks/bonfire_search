if Application.get_env(:bonfire_search, :adapter) == Bonfire.Search.Sonic do
  defmodule Bonfire.Search.SonicConcurrencyTest do
    @moduledoc """
    Concurrent searches through the adapter must each return their own results.

    `Sonix.Connection` is what makes concurrent commands safe, and `Sonix.ConnectionConcurrencyTest` in the sonix fork covers that guarantee directly. This covers the wiring instead: that `Bonfire.Search.Sonic`'s search path actually goes through it, so rerouting the adapter back onto a lent-out conn would fail here.

    The sequential test is the control: identical searches over the identical connection, so a failure in the concurrent test is attributable to concurrency rather than to the fixture or the query.
    """

    use Bonfire.Search.DataCase, async: false

    alias Bonfire.Search.Sonic

    @rounds 15

    setup do
      collection = Bonfire.Search.Indexer.index_name(:public)
      Sonic.delete(:all, collection)

      n = System.unique_integer([:positive])
      terms = {"alphaterm#{n}", "betaterm#{n}"}

      expected =
        for term <- Tuple.to_list(terms), into: %{} do
          ids = for i <- 1..5, do: "#{term}-#{i}"

          for id <- ids do
            Sonic.put_documents(
              %{"id" => id, "post_content" => %{"html_body" => term}},
              collection
            )
          end

          {term, Enum.sort(ids)}
        end

      on_exit(fn -> Sonic.delete(:all, collection) end)

      %{expected: expected, terms: terms}
    end

    test "sequential searches each return their own results", ctx do
      results = for i <- 1..@rounds, do: search(term_for(ctx, i))

      assert_own_results(results, ctx.expected)
    end

    test "concurrent searches each return their own results", ctx do
      results =
        1..@rounds
        |> Enum.map(fn i -> Task.async(fn -> search(term_for(ctx, i)) end) end)
        |> Task.await_many(30_000)

      assert_own_results(results, ctx.expected)
    end

    defp search(term), do: {term, Sonic.search(term, %{index: :public, raw: true})}

    defp term_for(%{terms: {alpha, beta}}, i), do: if(rem(i, 2) == 0, do: alpha, else: beta)

    defp assert_own_results(results, expected) do
      for {term, result} <- results do
        assert %{hits: hits} = result
        ids = hits |> Enum.map(& &1["id"]) |> Enum.sort()

        assert ids == expected[term],
               "the #{term} search got #{inspect(ids)} instead of #{inspect(expected[term])}"
      end
    end
  end
end
