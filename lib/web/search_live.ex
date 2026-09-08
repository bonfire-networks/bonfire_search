defmodule Bonfire.Search.Web.SearchLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  alias Bonfire.Search.Filters
  alias Bonfire.Search.UI.FiltersSearchLive

  declare_extension(l("Search"),
    icon: "heroicons-solid:search",
    emoji: "🔍",
    description: l("Search for users or content."),
    exclude_from_nav: true
  )

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  def mount(_params, _session, socket) do
    {:ok,
     assign(
       socket,
       page: "search",
       page_title: l("Search"),
       selected_tab: nil,
       index: "public",
       back: true,
       search_limit: Bonfire.Search.LiveHandler.default_limit(),
       search_term: nil,
       selected_facets: nil,
       search: nil,
       search_filters: %{},
       mobile_filters_open: false,
       hits: [],
       user_hits: [],
       page_info: nil,
       searching: false,
       searching_direct: false,
       sidebar_widgets: widgets(%{})
     )}
  end

  # sidebar widgets receive their assigns at render time, so the filters widget is
  # re-sent from handle_params whenever the term, tab or filters in the URL change.
  # The hashtag tab has no filters of its own, so it gets no widget.
  defp widgets(filters, tab \\ nil) do
    filters_widget =
      if tab != "hashtag",
        do: [{Bonfire.Search.Web.WidgetSearchFiltersLive, [filters: filters, tab: tab]}],
        else: []

    [
      users: [
        secondary: filters_widget ++ [{Bonfire.Tag.Web.WidgetTagsLive, []}]
      ],
      guests: [
        secondary: nil
      ]
    ]
  end

  def handle_params(%{"Bonfire" => %{"Search" => params}}, url, socket),
    do: handle_params(params, url, socket)

  def handle_params(%{"s" => "#" <> hashtag}, _url, socket) when hashtag != "" do
    {:noreply, redirect_to(socket, FiltersSearchLive.hashtag_url(hashtag))}
  end

  def handle_params(params, _url, socket) do
    tab =
      if params["hashtag_search"],
        do: "hashtag",
        else: FiltersSearchLive.type_facet(e(params, "facet", "index_type", nil))
    term = search_term(params, socket)
    index = params["index"] || socket.assigns.index
    raw_filters = Filters.cast_filters(params["filters"])

    if socket_connected?(socket) and is_nil(tab) and Filters.post_only?(raw_filters) do
      url = FiltersSearchLive.tab_url(term, index, raw_filters, Filters.tab_for(raw_filters, tab))
      {:noreply, patch_to(socket, url)}
    else
      filters = Filters.for_tab(raw_filters, tab)
      changed? =
        term != socket.assigns.search_term or tab != socket.assigns.selected_tab or
          index != socket.assigns.index or filters != socket.assigns.search_filters

      socket = assign(socket, search_filters: filters, sidebar_widgets: widgets(filters, tab))

      if socket_connected?(socket) and changed? do
        run_search(socket, term, tab, index)
      else
        {:noreply, socket}
      end
    end
  end

  defp search_term(%{"hashtag_search" => term}, _socket), do: "#" <> term
  defp search_term(%{"s" => term}, _socket), do: String.trim(term || "")

  defp search_term(params, socket) do
    if Map.has_key?(params, "facet") or Map.has_key?(params, "index"),
      do: socket.assigns.search_term,
      else: nil
  end

  defp run_search(socket, term, tab, index) when term in [nil, ""] do
    {:noreply,
     assign(socket,
       search: nil,
       search_term: nil,
       selected_tab: tab,
       selected_facets: nil,
       index: index,
       hits: [],
       user_hits: [],
       page_info: nil,
       searching: false
     )}
  end

  defp run_search(socket, term, tab, index) do
    facets = if tab not in [nil, "hashtag"], do: %{"index_type" => tab}

    Bonfire.Search.LiveHandler.live_search(
      term,
      Bonfire.Search.LiveHandler.default_limit(),
      facets,
      index,
      socket
      |> assign(search_term: term, selected_tab: tab, index: index)
      |> assign_global(search_more: true)
    )
  end

  def handle_event("toggle_index", %{"index" => new_index}, socket) do
    url =
      FiltersSearchLive.tab_url(
        socket.assigns.search,
        new_index,
        e(assigns(socket), :search_filters, %{}),
        socket.assigns.selected_tab
      )

    {:noreply, push_patch(socket, to: url)}
  end

  def handle_info({Bonfire.UI.Social.FeedFiltersModalContentLive, :apply, filters}, socket) do
    filters = Filters.cast_filters(filters)
    tab = Filters.tab_for(filters, socket.assigns.selected_tab)

    url = FiltersSearchLive.tab_url(socket.assigns.search || "", socket.assigns.index, filters, tab)
    {:noreply, patch_to(socket, url)}
  end

  def handle_info(msg, socket) do
    debug(msg, "unhandled info in SearchLive")
    {:noreply, socket}
  end

  # small screens have no sidebar: the same filters editor expands inline under the tabs
  def handle_event("toggle_mobile_filters", _params, socket) do
    {:noreply, assign(socket, mobile_filters_open: !e(assigns(socket), :mobile_filters_open, false))}
  end

  def handle_event("Bonfire.Search:search", params, socket),
    do: Bonfire.Search.LiveHandler.handle_event("patch_search", params, socket)

  def handle_async(name, result, socket) do
    # TODO: handle this redirection in LiveHandlers
    Bonfire.Search.LiveHandler.handle_async(name, result, socket)
  end
end
