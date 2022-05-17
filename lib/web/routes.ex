defmodule Bonfire.Search.Web.Routes do
  defmacro __using__(_) do

    quote do

      # pages anyone can view
      scope "/search", Bonfire.UI.Me do
        pipe_through :browser

      end

      # pages only guests can view
      scope "/search", Bonfire.UI.Me do
        pipe_through :browser
        pipe_through :guest_only

      end

      # pages you need an account to view
      scope "/", Bonfire.Search.Web do
        pipe_through :browser
        pipe_through :account_required

        live "/search", SearchLive
        live "/tag/:hashtag_search", SearchLive, as: Bonfire.Tag.Hashtag
      end

      # pages you need to view as a user
      scope "/search", Bonfire.UI.Me do
        pipe_through :browser
        pipe_through :user_required

      end

      # pages only admins can view
      scope "/search", Bonfire.UI.Me do
        pipe_through :browser
        pipe_through :admin_required

      end

    end
  end
end
