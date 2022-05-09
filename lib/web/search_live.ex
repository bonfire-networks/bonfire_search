defmodule Bonfire.Search.Web.SearchLive do
  use Bonfire.UI.Common.Web, :surface_view
  alias Bonfire.Me.Web.LivePlugs

  alias Bonfire.Search.Web.ResultsLive

  def mount(params, session, socket) do
    live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
      &mounted/3,
    ]
  end

  defp mounted(params, session, socket) do
    # socket = init_assigns(params, session, socket)
    # debug(params, "PARAMS")

    {:ok,
     socket
     |> assign(
       page: "search",
       page_title: "Search",
       selected_tab: "all",
      #  me: false,
      #  selected_facets: nil,
      #  search: "",
      #  hits: [],
      #  facets: %{},
      #  num_hits: nil
     )}
  end

  def handle_params(%{"s" => s, "facet" => facets} = _params, _url, socket) when s != "" do
    index_type = e(facets, :index_type, nil)
    
    Bonfire.Search.LiveHandler.live_search(s, 20, facets, socket 
    |> assign(selected_tab: index_type)
    |> assign_global(search_more: true))
  end


  def handle_params(%{"s" => s} = _params, _url, socket) when s != "" do
    Bonfire.Search.LiveHandler.live_search(s, socket |> assign_global(search_more: true))
  end

  def handle_params(%{"hashtag_search" => s} = _params, _url, socket) when s != "" do
    Bonfire.Search.LiveHandler.live_search("\"#{s}\"", socket |> assign_global(search_more: true))
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket |> assign_global(search_more: true)}
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

  def handle_event("Bonfire.Search:search", params, %{assigns: %{__context__: %{selected_facets: selected_facets}}} = socket) when not is_nil(selected_facets) do
    handle_event("Bonfire.Search:search", params, socket |> assign(selected_facets: selected_facets))
  end

  def handle_event("Bonfire.Search:search", params, %{assigns: %{selected_facets: selected_facets}} = socket) when not is_nil(selected_facets) do
    debug(search_with_facet: params)
    # debug(socket)

    {:noreply,
      socket |> Phoenix.LiveView.push_patch(to: "/search?"<>Plug.Conn.Query.encode(facet: selected_facets)<>"&s=" <> params["s"])}
  end

  def handle_event("Bonfire.Search:search", params, socket) do
    # debug(search: params)
    # debug(socket)

    {:noreply,
      socket |> Phoenix.LiveView.push_patch(to: "/search?s=" <> params["s"])}
  end

  def handle_event(action, attrs, socket), do: Bonfire.UI.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)

end
