if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Search.API.GraphQL do
    @moduledoc "Search API fields/endpoints for GraphQL"

    use Absinthe.Schema.Notation
    use Bonfire.Common.Utils
    import Untangle

    alias Bonfire.API.GraphQL

    input_object :search_filters do
      field(:query, non_null(:string), description: "Search query string")

      field(:type, :string,
        description: "Filter by type: accounts, statuses, hashtags, or all (default)"
      )

      field(:limit, :integer, default_value: 20, description: "Maximum results to return")
      field(:offset, :integer, default_value: 0, description: "Number of results to skip")
    end

    object :search_queries do
      @desc "Search for activities/statuses using meilisearch"
      field :search_activities, list_of(:activity) do
        arg(:filter, non_null(:search_filters))
        resolve(&search_activities/3)
      end

      @desc "Search for users/accounts using meilisearch"
      field :search_users, list_of(:user) do
        arg(:filter, non_null(:search_filters))
        resolve(&search_users/3)
      end
    end

    defp search_activities(_parent, %{filter: filter}, info) do
      search_meilisearch(filter, info, "Bonfire.Data.Social.Post", fn id, current_user ->
        case Bonfire.Social.Activities.read(id,
               current_user: current_user,
               preload: [:with_subject, :with_object_more, :with_creator, :with_media]
             ) do
          {:ok, activity} -> [activity]
          _ -> []
        end
      end)
    end

    defp search_users(_parent, %{filter: filter}, info) do
      search_meilisearch(filter, info, "Bonfire.Data.Identity.User", fn id, current_user ->
        case Bonfire.Me.Users.by_id(id, current_user: current_user) do
          {:ok, user} ->
            [Bonfire.Common.Repo.maybe_preload(user, [:character, :profile])]

          _ ->
            []
        end
      end)
    end

    defp search_meilisearch(filter, info, index_type, loader_fn) do
      current_user = GraphQL.current_user(info)
      query = filter[:query] || ""

      if query == "" do
        {:ok, []}
      else
        facet_filter = %{"index_type" => [index_type]}

        search_result =
          Bonfire.Search.search(
            query,
            %{
              index: :closed,
              limit: filter[:limit] || 20,
              offset: filter[:offset] || 0,
              current_user: current_user
            },
            [],
            facet_filter
          )

        hits = (search_result && Map.get(search_result, :hits, [])) || []

        results =
          hits
          |> Enum.map(&Bonfire.Common.Enums.id/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&loader_fn.(&1, current_user))

        {:ok, results}
      end
    end
  end
end
