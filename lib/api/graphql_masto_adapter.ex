if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Search.API.GraphQLMasto.Adapter do
    @moduledoc """
    Search API endpoints for Mastodon-compatible client apps.

    Implements the v2 search endpoint which returns accounts, statuses, and hashtags.
    This adapter orchestrates search across multiple domains:
    - Accounts: via GraphQL user search
    - Statuses: delegates to Social adapter for interaction state handling
    - Hashtags: via Bonfire.Tag

    Endpoint: GET /api/v2/search
    """

    use Bonfire.Common.Utils
    use Arrows
    import Untangle

    use AbsintheClient,
      schema: Bonfire.API.GraphQL.Schema,
      action: [mode: :internal]

    alias Bonfire.API.GraphQL.RestAdapter
    alias Bonfire.API.MastoCompat.{Mappers, PaginationHelpers}

    # User profile fragment inlined for compile-order independence
    @user """
      id
      created_at: date_created
      profile {
        avatar: icon
        avatar_static: icon
        header: image
        header_static: image
        display_name: name
        note: summary
        website
      }
      character {
        username
        acct: username
        url: canonical_uri
        peered {
          canonical_uri
        }
      }
    """

    # GraphQL query for searching users/accounts
    @graphql "query ($filter: SearchFilters!) {
      search_users(filter: $filter) {
        #{@user}
      }
    }"
    def search_users_gql(params, conn) do
      graphql(conn, :search_users_gql, params)
    end

    @doc """
    Search for accounts, statuses, and hashtags.

    Implements Mastodon v2 search endpoint which returns:
    - accounts: matching user profiles
    - statuses: matching posts
    - hashtags: matching tags

    Params:
    - q: search query string (required)
    - type: filter results by type (accounts, statuses, hashtags)
    - limit: max results per type (default 20, max 40)
    - offset: pagination offset
    - resolve: attempt to resolve remote accounts (boolean)
    - following: only return accounts the user is following (boolean)

    Endpoint: GET /api/v2/search
    """
    def search(params, conn) do
      current_user = conn.assigns[:current_user]
      query = params["q"] || ""

      if query == "" do
        RestAdapter.json(conn, %{
          "accounts" => [],
          "statuses" => [],
          "hashtags" => []
        })
      else
        search_opts = %{
          limit: validate_search_limit(params["limit"]),
          offset: parse_offset(params["offset"]),
          current_user: current_user
        }

        results = do_search(query, params["type"], search_opts, conn)

        RestAdapter.json(conn, results)
      end
    end

    # Perform search and categorize results based on type filter
    defp do_search(query, type, opts, conn) do
      case type do
        "accounts" ->
          %{"accounts" => search_accounts(query, opts, conn), "statuses" => [], "hashtags" => []}

        "statuses" ->
          %{"accounts" => [], "statuses" => search_statuses(query, opts, conn), "hashtags" => []}

        "hashtags" ->
          %{"accounts" => [], "statuses" => [], "hashtags" => search_hashtags(query, opts)}

        _ ->
          # Search all types
          %{
            "accounts" => search_accounts(query, opts, conn),
            "statuses" => search_statuses(query, opts, conn),
            "hashtags" => search_hashtags(query, opts)
          }
      end
    end

    # Search for accounts/users using GraphQL
    defp search_accounts(query, opts, conn) do
      current_user = opts[:current_user]

      filter = %{
        "query" => query,
        "limit" => opts[:limit] || 20,
        "offset" => opts[:offset] || 0
      }

      case graphql(conn, :search_users_gql, %{"filter" => filter}) do
        %{data: %{search_users: users}} when is_list(users) ->
          # Skip expensive stats for search results (N+1 query prevention)
          users
          |> Enum.flat_map(fn user ->
            case Mappers.Account.from_user(user,
                   current_user: current_user,
                   skip_expensive_stats: true
                 ) do
              result when is_map(result) and map_size(result) > 0 ->
                if Map.get(result, "id"), do: [result], else: []

              _ ->
                []
            end
          end)

        _ ->
          []
      end
    rescue
      e ->
        error(e, "Search accounts failed")
        []
    end

    # Search for statuses/posts - delegates to Social adapter for interaction state handling
    defp search_statuses(query, opts, conn) do
      alias Bonfire.Social.API.GraphQLMasto.Adapter, as: SocialAdapter

      # Delegate to social adapter which has the activity fragment and batch loading helpers
      SocialAdapter.search_statuses_for_api(query, opts, conn)
    rescue
      e ->
        error(e, "Search statuses failed")
        []
    end

    # Search for hashtags
    # Note: Hashtags don't go through GraphQL since they're simple tag lookups
    defp search_hashtags(query, opts) do
      # Use maybe_apply for efficient module/function checking with caching
      case Utils.maybe_apply(Bonfire.Tag, :search_hashtag, [query, [limit: opts[:limit] || 20]]) do
        hashtags when is_list(hashtags) and hashtags != [] ->
          hashtags
          |> Enum.map(fn tag ->
            name = extract_tag_name(tag)

            if name && name != "" do
              %{
                "name" => name,
                "url" => Bonfire.Common.URIs.base_url() <> "/search/tag/#{name}",
                "history" => []
              }
            end
          end)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end
    rescue
      e ->
        error(e, "Search hashtags failed")
        []
    end

    # Extract tag name from various tag formats
    defp extract_tag_name(%{name: name}) when is_binary(name), do: name
    defp extract_tag_name(%{named: %{name: name}}) when is_binary(name), do: name
    defp extract_tag_name(%{"name" => name}) when is_binary(name), do: name
    defp extract_tag_name(name) when is_binary(name), do: name
    defp extract_tag_name(_), do: nil

    # Search uses different defaults: 20 limit, 40 max
    defp validate_search_limit(limit),
      do: PaginationHelpers.validate_limit(limit, default: 20, max: 40)

    defp parse_offset(nil), do: 0

    defp parse_offset(offset) when is_binary(offset) do
      case Integer.parse(offset) do
        {n, _} when n >= 0 -> n
        _ -> 0
      end
    end

    defp parse_offset(offset) when is_integer(offset) and offset >= 0, do: offset
    defp parse_offset(_), do: 0
  end
end
