if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Search.Web.MastoSearchController do
    @moduledoc "Mastodon-compatible v2 search REST endpoint."

    use Bonfire.UI.Common.Web, :controller
    import Untangle

    alias Bonfire.Search.API.GraphQLMasto.Adapter

    def search(conn, params) do
      debug(params, "GET /api/v2/search")
      Adapter.search(params, conn)
    end
  end
end
