defmodule Bonfire.Search.Sonic.BuildCommandsTest do
  @moduledoc """
  Pure unit test for the Bonfire-doc → Sonic command mapping (no live Sonic needed).
  The generic FLUSHO+PUSH packing/sequencing is tested in the sonix fork; here we only
  check that docs map to the right buckets/text and delegate per doc × bucket.
  """
  use ExUnit.Case, async: true

  alias Bonfire.Search.Sonic

  test "maps each doc to FLUSHO+PUSH per bucket, across the list" do
    doc1 = %{"id" => "obj1", "index_type" => "T", "post_content" => %{"html_body" => "hello world"}}
    doc2 = %{"id" => "obj2", "post_content" => %{"html_body" => "second doc"}}

    assert Sonic.build_commands([doc1, doc2], "coll") == [
             # doc1 → buckets ["all", "T"]
             "FLUSHO coll all obj1",
             ~s[PUSH coll all obj1 "hello world"],
             "FLUSHO coll T obj1",
             ~s[PUSH coll T obj1 "hello world"],
             # doc2 → bucket ["all"] only (no index_type)
             "FLUSHO coll all obj2",
             ~s[PUSH coll all obj2 "second doc"]
           ]
  end

  test "skips docs with no indexable text" do
    empty = %{"id" => "obj3", "post_content" => %{"html_body" => ""}}
    assert Sonic.build_commands([empty], "coll") == []
  end

  test "empty doc list yields no commands" do
    assert Sonic.build_commands([], "coll") == []
  end
end
