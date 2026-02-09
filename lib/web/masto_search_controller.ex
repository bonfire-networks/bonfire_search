if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Search.Web.MastoSearchController do
    @moduledoc "Mastodon-compatible v2 search REST endpoint."

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Search.API.GraphQLMasto.Adapter

    def search(conn, params), do: Adapter.search(params, conn)
  end
end
