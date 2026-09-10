if Application.get_env(:bonfire_search, :adapter) == Bonfire.Search.Sonic do
  defmodule Bonfire.Search.SonicTest do
    use Bonfire.Search.DataCase, async: false

    alias Bonfire.Search.Sonic

    # connection handling itself (START re-handshake, idle drop, keepalive, command
    # serialisation) is covered by Sonix.ConnectionTest in the sonix fork

    describe "Sonic service and adapter" do
      test "service is reachable and healthy" do
        assert Sonic.healthy?()
      end

      test "ingest connection is available" do
        assert Sonic.with_ingest(&Sonix.ping/1) == :ok
      end

      test "search connection is available" do
        assert Sonic.with_search(&Sonix.ping/1) == :ok
      end

      test "can push and query a document" do
        collection = "test_sonic_adapter"
        object_id = "test-obj-#{System.unique_integer([:positive])}"
        text = "elixir phoenix search test"

        assert :ok =
                 Sonic.with_ingest(fn conn ->
                   Sonix.flush(conn, collection)
                   Sonix.push(conn, collection, "all", object_id, text)
                 end)

        assert {:ok, ids} = Sonic.with_search(&Sonix.query(&1, collection, "all", "elixir"))
        assert object_id in ids

        Sonic.with_ingest(&Sonix.flush(&1, collection))
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

        result = Sonic.search("roundtrip", %{index: index, raw: true})
        assert %{hits: hits} = result
        assert Enum.any?(hits, &(&1["id"] == doc["id"]))

        Sonic.delete(:all, collection)
      end

      test "adapter put_documents (batch list) pipelines and both are searchable" do
        index = :public
        collection = Bonfire.Search.Indexer.index_name(index)

        Sonic.delete(:all, collection)

        n = System.unique_integer([:positive])

        docs = [
          %{
            "id" => "sonic-batch-a-#{n}",
            "post_content" => %{"html_body" => "batchroundtrip alpha"}
          },
          %{
            "id" => "sonic-batch-b-#{n}",
            "post_content" => %{"html_body" => "batchroundtrip beta"}
          }
        ]

        assert {:ok, :indexed} = Sonic.put_documents(docs, collection)

        result = Sonic.search("batchroundtrip", %{index: index, raw: true})
        assert %{hits: hits} = result
        ids = Enum.map(hits, & &1["id"])
        assert Enum.all?(docs, &(&1["id"] in ids))

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
