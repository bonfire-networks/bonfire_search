defmodule Bonfire.Search.HTTPSSRFTest do
  @moduledoc """
  The search index is a service the admin configured, usually on a private address (e.g. `http://search:7700` in Docker), so search requests must still reach it while `Bonfire.Common.HTTP` refuses private addresses for everything else.
  """
  use ExUnit.Case, async: false
  @moduletag :backend

  setup do
    test_pid = self()

    Tesla.Mock.mock(fn env ->
      send(test_pid, {:hit, env.url})
      %Tesla.Env{status: 200, body: "{}"}
    end)

    :ok
  end

  test "the search index is reached on a private address" do
    assert {:ok, %{status: 200}} =
             Bonfire.Search.HTTP.http_request(:get, "http://10.0.0.9:7700/health", [])

    assert_received {:hit, "http://10.0.0.9:7700/health?"}
  end

  test "writes to the search index are sent to a private address" do
    assert {:ok, %{status: 200}} =
             Bonfire.Search.HTTP.http_request(:post, "http://10.0.0.9:7700/indexes", [], %{
               "uid" => "test"
             })

    assert_received {:hit, "http://10.0.0.9:7700/indexes"}
  end
end
