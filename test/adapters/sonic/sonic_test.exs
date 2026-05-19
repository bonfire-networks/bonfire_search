if Application.get_env(:bonfire_search, :adapter) == Bonfire.Search.Sonic do
  defmodule Bonfire.Search.SonicTest do
    use Bonfire.Search.DataCase, async: false

    alias Bonfire.Search.Sonic
    alias Bonfire.Search.Sonic.Connection

    describe "Sonic service and adapter" do
      test "service is reachable and healthy" do
        assert Sonic.healthy?()
      end

      test "ingest connection is available" do
        assert {:ok, _conn} = Connection.ingest()
      end

      test "search connection is available" do
        assert {:ok, _conn} = Connection.search()
      end

      test "can push and query a document" do
        {:ok, conn} = Connection.ingest()
        collection = "test_sonic_adapter"
        object_id = "test-obj-#{System.unique_integer([:positive])}"
        text = "elixir phoenix search test"

        Sonix.flush(conn, collection)
        assert :ok = Sonix.push(conn, collection, "all", object_id, text)

        {:ok, search_conn} = Connection.search()
        assert {:ok, ids} = Sonix.query(search_conn, collection, "all", "elixir")
        assert object_id in ids

        Sonix.flush(conn, collection)
      end

      test "adapter put_documents and search round-trip" do
        index = :public
        collection = Bonfire.Search.Indexer.index_name(index)

        Sonic.delete(:all, collection)

        doc = %{
          "id" => "sonic-rt-#{System.unique_integer([:positive])}",
          "post_content" => %{"html_body" => "unique roundtrip sonic test content"}
        }

        assert {:ok, :indexed} = Sonic.put_documents(doc, collection)

        result = Sonic.search("roundtrip", %{index: index})
        assert %{hits: hits} = result
        assert Enum.any?(hits, &(&1["id"] == doc["id"]))

        Sonic.delete(:all, collection)
      end

      test "delete removes document from index" do
        index = :public
        collection = Bonfire.Search.Indexer.index_name(index)
        Sonic.delete(:all, collection)

        doc = %{
          "id" => "sonic-del-#{System.unique_integer([:positive])}",
          "post_content" => %{"html_body" => "deleteme sonic content"}
        }

        assert {:ok, :indexed} = Sonic.put_documents(doc, collection)
        Sonic.delete(doc["id"], collection)

        result = Sonic.search("deleteme", %{index: index})
        hits = Map.get(result, :hits, [])
        refute Enum.any?(hits, &(&1["id"] == doc["id"]))

        Sonic.delete(:all, collection)
      end
    end
  end
end
