defmodule Bonfire.Search.Web.SearchLive do
  use Bonfire.Web, :live_view


  alias Bonfire.Search.Web.ResultsLive

  def mount(params, session, socket) do
    # socket = init_assigns(params, session, socket)
    IO.inspect(params, label: "PARAMS")

    {:ok,
     socket
     |> assign(
       page_title: "Search",
       me: false,
       current_user: socket.assigns.current_user,
       selected_tab: "all",
       search: "",
       hits: [],
       facets: %{},
       num_hits: nil
     )}
  end

  def handle_params(%{"search" => q, "tab" => tab} = _params, _url, socket) when q != "" do

    Bonfire.Search.LiveHandler.live_search(q, tab, socket)

  end

  def handle_params(%{"tab" => tab} = _params, _url, socket) do
    IO.inspect(tab, label: "TAB")

    {:noreply,
     assign(socket,
       selected_tab: tab
       #  current_user: socket.assigns.current_user
     )}
  end

  def handle_params(_params, _url, socket) do
    # community =
    # CommunitiesHelper.community_load(socket, params, %{icon: true, image: true, character: true})

    # IO.inspect(community, label: "community")

    {:noreply,
     assign(socket,
       #  community: community,
       current_user: socket.assigns.current_user
     )}
  end

  defp link_body(name, icon) do
    assigns = %{name: name, icon: icon}

    ~L"""
      <i class="<%= @icon %>"></i>
      <%= @name %>
    """
  end


end
