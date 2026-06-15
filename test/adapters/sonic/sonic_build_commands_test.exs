defmodule Bonfire.Search.Sonic.IngestCommandsTest do
  @moduledoc """
  Pure unit test for the Bonfire-doc → Sonic command mapping (no live Sonic needed).
  The generic FLUSHO+PUSH packing/sequencing is tested in the sonix fork; here we only
  check that docs map to the right buckets/text, delegate per doc × bucket, and that
  identity buckets get `LANG(none)` (so usernames aren't stemmed/dropped).
  """
  use ExUnit.Case, async: true

  alias Bonfire.Search.Sonic

  test "identity-type doc gets LANG(none) on the type bucket but not the mixed 'all' bucket" do
    user = %{
      "id" => "user1",
      "index_type" => "Bonfire.Data.Identity.User",
      "character" => %{"username" => "alice"}
    }

    assert Sonic.ingest_commands([user], "coll") == [
             "FLUSHO coll all user1",
             ~s[PUSH coll all user1 "alice"],
             "FLUSHO coll Bonfire.Data.Identity.User user1",
             ~s[PUSH coll Bonfire.Data.Identity.User user1 "alice" LANG(none)]
           ]
  end

  test "non-identity doc indexes into 'all' only, no LANG" do
    post = %{"id" => "post1", "post_content" => %{"html_body" => "hello world"}}

    assert Sonic.ingest_commands([post], "coll") == [
             "FLUSHO coll all post1",
             ~s[PUSH coll all post1 "hello world"]
           ]
  end

  test "skips docs with no indexable text" do
    empty = %{"id" => "post2", "post_content" => %{"html_body" => ""}}
    assert Sonic.ingest_commands([empty], "coll") == []
  end

  test "empty doc list yields no commands" do
    assert Sonic.ingest_commands([], "coll") == []
  end
end
