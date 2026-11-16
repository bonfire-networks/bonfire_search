defmodule Bonfire.Search.SearchOffsetCapTest do
  @moduledoc """
  A search page is asked for with an offset that comes from the client (the `after` cursor of the web search, `offset` of the GraphQL search). An offset far past what an index can hold must not reach the index as it is: it gets an empty page (and a logged hint) instead of reaching the index, while an ordinary offset comes through unchanged.

  The index adapter is a stub that tells the test what it was asked for.
  """
  use Bonfire.Search.DataCase, async: true, needs_adapter: false

  # what Meilisearch serves by default (`maxTotalHits`), which is as far as any offset can be of use
  @window 1_000

  defmodule SpyAdapter do
    def search(_string, opts, _calculate_facets, _filter_facets) do
      send(self(), {:asked_for_offset, opts[:offset]})
      %{hits: []}
    end

    def search(_string, opts) do
      send(self(), {:asked_for_offset, opts[:offset]})
      %{hits: []}
    end
  end

  setup do
    Process.put([:bonfire_search, :adapter], SpyAdapter)
    assert Bonfire.Search.adapter() == SpyAdapter
    :ok
  end

  test "an ordinary offset reaches the index as it is (control)" do
    Bonfire.Search.search("hello", %{offset: 20, limit: 20}, [], %{})

    assert_received {:asked_for_offset, 20}
  end

  test "an offset at the cap still reaches the index (control)" do
    Bonfire.Search.search("hello", %{offset: @window, limit: 20}, [], %{})

    assert_received {:asked_for_offset, @window}
  end

  test "an offset past the cap gets an empty page, without asking the index, and logs a hint naming the key" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{hits: []} =
                 Bonfire.Search.search("hello", %{offset: @window + 20, limit: 20}, [], %{})
      end)

    refute_received {:asked_for_offset, _}
    assert log =~ "max_offset"
    assert log =~ "#{@window + 20}"
  end

  test "a huge offset in the simplified search also gets an empty page" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{hits: []} = Bonfire.Search.search("hello", offset: 9_999_999_999_999, limit: 20)
      end)

    refute_received {:asked_for_offset, _}
    assert log =~ "max_offset"
  end
end
