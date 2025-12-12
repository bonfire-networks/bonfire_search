# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Search.MastoApiCase do
  @moduledoc "Test case for Mastodon API search endpoint testing."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest

      import Bonfire.UI.Common.Testing.Helpers,
        except: [fake_account!: 0, fake_account!: 1, fake_user!: 0, fake_user!: 1, fake_user!: 2]

      import Bonfire.Me.Fake

      import Bonfire.Search.MastoApiCase.Helpers

      @endpoint Application.compile_env!(:bonfire, :endpoint_module)
    end
  end

  setup tags do
    Bonfire.Common.Test.Interactive.setup_test_repo(tags)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defmodule Helpers do
    @moduledoc "Helper functions for Mastodon API search testing."

    import Plug.Conn
    import Phoenix.ConnTest

    @endpoint Application.compile_env!(:bonfire, :endpoint_module)

    def masto_api_conn(conn, opts \\ []) do
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> maybe_authenticate(opts[:user], opts[:account])
    end

    defp maybe_authenticate(conn, nil, _account), do: conn

    defp maybe_authenticate(conn, user, account) do
      conn = Plug.Test.init_test_session(conn, %{})

      conn =
        if account do
          Plug.Conn.put_session(conn, :current_account_id, account.id)
        else
          conn
        end

      Plug.Conn.put_session(conn, :current_user_id, user.id)
    end

    @doc "Helper to create a post with content"
    def create_post!(user, content \\ "Test post content") do
      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: user,
          post_attrs: %{post_content: %{html_body: content}},
          boundary: "public"
        )

      post
    end

    @doc "Helper to create a hashtag"
    def create_hashtag!(name) do
      case Bonfire.Common.Utils.maybe_apply(Bonfire.Tag, :maybe_find_or_add, [nil, name]) do
        {:ok, tag} -> tag
        tag when is_map(tag) -> tag
        _ -> nil
      end
    end
  end
end
