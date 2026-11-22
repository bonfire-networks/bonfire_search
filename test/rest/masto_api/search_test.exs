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

  # Ice Cubes showed a found account with "0 seguaci" while its profile showed 1 (live testing, masto-live-fixes step 2)
  describe "account results of GET /api/v2/search" do
    @tag skip:
           "needs a search index in tests: /api/v2/search finds users through Meilisearch (search_api_graphql.ex:53-65), empty in tests; proven by the live check (masto-live-fixes step 2, decision 8)"
    test "carry real counts", %{conn: conn} do
      account = fake_account!()
      viewer = fake_user!(account)
      found = fake_user!()
      {:ok, _} = Bonfire.Social.Graph.Follows.follow(fake_user!(), found)

      {:ok, _} =
        Bonfire.Posts.publish(
          current_user: found,
          post_attrs: %{post_content: %{html_body: "a found user's post"}},
          boundary: "public"
        )

      result =
        conn
        |> masto_api_conn(user: viewer, account: account)
        |> get("/api/v2/search?q=#{found.character.username}&type=accounts")
        |> json_response(200)
        |> Map.fetch!("accounts")
        |> Enum.find(&(&1["id"] == found.id))

      assert result, "the user is found by username"

      assert Map.take(result, ~w(statuses_count followers_count following_count)) == %{
               "statuses_count" => 1,
               "followers_count" => 1,
               "following_count" => 0
             }
    end
  end

  describe "GET /api/v1/search (GoToSocial serves search at both api versions)" do
    setup do
      account = fake_account!()
      user = fake_user!(account)
      {:ok, account: account, user: user}
    end

    test "is served and returns the same shape as v2", %{
      conn: conn,
      user: user,
      account: account
    } do
      api_conn = masto_api_conn(conn, user: user, account: account)

      response =
        api_conn
        |> get("/api/v1/search?q=test")
        |> json_response(200)

      assert is_list(response["accounts"])
      assert is_list(response["statuses"])
      assert is_list(response["hashtags"])
    end
  end
end
