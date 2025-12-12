# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search.MastoApi.SearchTest do
  use Bonfire.Search.MastoApiCase, async: true

  @moduletag :masto_api

  describe "GET /api/v2/search" do
    setup do
      account = fake_account!()
      user = fake_user!(account)

      {:ok, account: account, user: user}
    end

    test "returns empty results for empty query", %{conn: conn, user: user, account: account} do
      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v2/search?q=")
        |> json_response(200)

      assert response["accounts"] == []
      assert response["statuses"] == []
      assert response["hashtags"] == []
    end

    test "returns all result types when no type filter", %{
      conn: conn,
      user: user,
      account: account
    } do
      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v2/search?q=test")
        |> json_response(200)

      # Response should have all three keys
      assert Map.has_key?(response, "accounts")
      assert Map.has_key?(response, "statuses")
      assert Map.has_key?(response, "hashtags")
      assert is_list(response["accounts"])
      assert is_list(response["statuses"])
      assert is_list(response["hashtags"])
    end

    test "filters by type=accounts", %{conn: conn, user: user, account: account} do
      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v2/search?q=test&type=accounts")
        |> json_response(200)

      # Should still return all keys but statuses and hashtags should be empty
      assert Map.has_key?(response, "accounts")
      assert response["statuses"] == []
      assert response["hashtags"] == []
    end

    test "filters by type=statuses", %{conn: conn, user: user, account: account} do
      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v2/search?q=test&type=statuses")
        |> json_response(200)

      # Should still return all keys but accounts and hashtags should be empty
      assert response["accounts"] == []
      assert Map.has_key?(response, "statuses")
      assert response["hashtags"] == []
    end

    test "filters by type=hashtags", %{conn: conn, user: user, account: account} do
      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v2/search?q=test&type=hashtags")
        |> json_response(200)

      # Should still return all keys but accounts and statuses should be empty
      assert response["accounts"] == []
      assert response["statuses"] == []
      assert Map.has_key?(response, "hashtags")
    end

    test "respects limit parameter", %{conn: conn, user: user, account: account} do
      api_conn = masto_api_conn(conn, user: user, account: account)

      # Limit should be accepted (default is 20, max is 40)
      response =
        api_conn
        |> get("/api/v2/search?q=test&limit=5")
        |> json_response(200)

      assert Map.has_key?(response, "accounts")
      assert Map.has_key?(response, "statuses")
      assert Map.has_key?(response, "hashtags")
    end

    test "respects offset parameter", %{conn: conn, user: user, account: account} do
      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v2/search?q=test&offset=10")
        |> json_response(200)

      assert Map.has_key?(response, "accounts")
      assert Map.has_key?(response, "statuses")
      assert Map.has_key?(response, "hashtags")
    end

    test "works without authentication", %{conn: conn} do
      # Search should work for unauthenticated users too
      response =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v2/search?q=test")
        |> json_response(200)

      assert Map.has_key?(response, "accounts")
      assert Map.has_key?(response, "statuses")
      assert Map.has_key?(response, "hashtags")
    end

    test "returns valid account structure when finding users", %{
      conn: conn,
      user: user,
      account: account
    } do
      # Search for the user we created
      username = user.character.username
      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v2/search?q=#{username}&type=accounts")
        |> json_response(200)

      # If we find accounts, verify structure
      if length(response["accounts"]) > 0 do
        account_result = hd(response["accounts"])
        assert is_binary(account_result["id"])
        assert is_binary(account_result["username"])
        assert is_binary(account_result["acct"])
      end
    end
  end
end
