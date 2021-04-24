defmodule Bonfire.Search.Web.SearchLive do
  use Bonfire.Web, :live_view
  alias Bonfire.Web.LivePlugs

  alias Bonfire.Search.Web.ResultsLive

  def mount(params, session, socket) do
    LivePlugs.live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf,
      &mounted/3,
    ]
  end

  defp mounted(params, session, socket) do
    # socket = init_assigns(params, session, socket)
    IO.inspect(params, label: "PARAMS")

    {:ok,
     socket
     |> assign(
       page: "search",
       page_title: "Search",
       me: false,
       selected_facets: nil,
       search: "",
       hits: [],
       facets: %{},
       num_hits: nil
     )}
  end

  def handle_params(%{"s" => s, "facet" => facets} = _params, _url, socket) when s != "" do

    Bonfire.Search.LiveHandler.live_search(s, 20, facets, socket)

  end


  def handle_params(%{"s" => s} = _params, _url, socket) when s != "" do

    Bonfire.Search.LiveHandler.live_search(s, socket)

  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket}
  end

  defp type_name(name) do
    String.split(name, ".") |> List.last() |> Recase.to_title()
  end
  defp link_body(name, 1 = num) do
    type_name = type_name(name) |> Inflex.singularize()
    "#{num} #{type_name}"
  end
  defp link_body(name, num) do
    type_name = type_name(name) |> Inflex.pluralize()
    "#{num} #{type_name}"
  end

  def handle_event("search", params, %{assigns: %{selected_facets: selected_facets}} = socket) when not is_nil(selected_facets) do
    IO.inspect(search_with_facet: params)
    # IO.inspect(socket)

    {:noreply,
      socket |> Phoenix.LiveView.push_patch(to: "/search?"<>Plug.Conn.Query.encode(facet: selected_facets)<>"&s=" <> params["search_field"]["query"])}
  end

  def handle_event("search", params, socket) do
    IO.inspect(search: params)
    # IO.inspect(socket)

    {:noreply,
      socket |> Phoenix.LiveView.push_patch(to: "/search?s=" <> params["search_field"]["query"])}
  end

end
