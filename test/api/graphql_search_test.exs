if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Search.API.GraphQL.SearchTest do
    use Bonfire.Search.DataCase, async: false
    use Repatch.ExUnit

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @search """
    query($query: String!, $limit: Int) {
      search_users(filter: {query: $query, type: "accounts", limit: $limit}) {
        id
      }
      search_activities(filter: {query: $query, type: "statuses", limit: $limit}) {
        id
      }
    }
    """

    test "search result lists are present and empty for blank queries" do
      user = fake_user!()

      {:ok, result} =
        Absinthe.run(@search, Schema,
          variables: %{"query" => "", "limit" => 5},
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors]
      assert get_in(result, [:data, "search_users"]) == []
      assert get_in(result, [:data, "search_activities"]) == []
    end

    test "search backend failure returns GraphQL errors instead of success-shaped empty lists" do
      user = fake_user!()

      Repatch.patch(Bonfire.Search, :search, fn _query,
                                                _opts,
                                                _calculate_facets,
                                                _filter_facets ->
        nil
      end)

      {:ok, result} =
        Absinthe.run(@search, Schema,
          variables: %{"query" => "graph search failure", "limit" => 5},
          context: Schema.context(%{current_user: user})
        )

      assert result[:errors]
      assert get_in(result, [:data, "search_users"]) == nil
      assert get_in(result, [:data, "search_activities"]) == nil
    end
  end
end
