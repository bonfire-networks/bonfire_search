defmodule Bonfire.Search.Web.SearchLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  # alias Bonfire.Search.Web.ResultsLive

  # Use dynamic limit from config instead of hardcoded value

  declare_extension("Search",
    icon: "heroicons-solid:search",
    emoji: "🔍",
    description: l("Search for users or content."),
    exclude_from_nav: true
  )

  declare_nav_link(l("Search"),
    page: "search",
    href: "/search",
    icon: "ph:magnifying-glass-duotone",
    icon_active: "ph:magnifying-glass-duotone"
  )

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  def mount(_params, _session, socket) do
    # socket = init_assigns(params, session, socket)
    # debug(params, "PARAMS")

    {:ok,
     assign(
       socket,
       page: "search",
       page_title: "Search",
       selected_tab: :search,
       index: "public",
       back: true,
       search_limit: Bonfire.Search.LiveHandler.default_limit(),
       #  me: false,
       #  selected_facets: nil,
       nav_items: Bonfire.Common.ExtensionModule.default_nav(),
       search: nil,
       hits: [],
       page_info: nil,
       searching: false,
       searching_direct: false,
       sidebar_widgets: [
         users: [
           secondary: [
             {Bonfire.Tag.Web.WidgetTagsLive, []}
           ]
         ],
         guests: [
           secondary: nil
         ]
       ]
       #  facets: %{},
       #  num_hits: nil
     )}
  end

  # defp widget(search) do
  #   [
  #     users: [
  #       secondary: [
  #         {Bonfire.Search.UI.FiltersSearchLive, [selected_tab: nil, search: search]}
  #       ]
  #     ]
  #   ]
  # end

  def handle_params(%{"s" => "#" <> hashtag} = params, _url, socket) do
    {:noreply,
     socket
     |> redirect_to("/search/tag/#{hashtag}")}
  end

  def handle_params(params, _url, socket) do
    # Extract nested Bonfire.Search parameters if they exist
    search_params =
      case params do
        %{"Bonfire" => %{"Search" => nested_params}} -> nested_params
        _ -> params
      end

    if socket_connected?(socket) do
      handle_search_params(search_params, nil, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_search_params(%{"s" => s, "facet" => facets} = params, _url, socket)
      when s != "" do
    previous_index = e(assigns(socket), :index, "nil")
    index = params["index"] || previous_index

    # Check if facet has changed
    new_facet_type = e(facets, "index_type", nil)
    current_facet_type = e(assigns(socket), :selected_tab, nil)

    if s != e(assigns(socket), :search_term, nil) or
         index != previous_index or
         new_facet_type != current_facet_type do
      index_type =
        new_facet_type
        |> debug("selected_tabsss")

      # If facet index_type is empty, treat as no facet filter
      search_facets =
        if new_facet_type == "" or is_nil(new_facet_type) do
          nil
        else
          facets
        end

      Bonfire.Search.LiveHandler.live_search(
        s,
        Bonfire.Search.LiveHandler.default_limit(),
        search_facets,
        index,
        socket
        |> assign(
          search_term: s,
          index: index,
          selected_tab: index_type
          # sidebar_widgets: widget(s)
        )
        |> assign_global(search_more: true)
      )
    else
      {:noreply, socket}
    end
  end

  def handle_search_params(%{"s" => s} = params, _url, socket) when s != "" do
    previous_index = e(assigns(socket), :index, "nil")
    index = params["index"] || previous_index

    if s != e(assigns(socket), :search_term, nil) or index != previous_index do
      Bonfire.Search.LiveHandler.live_search(
        s,
        Bonfire.Search.LiveHandler.default_limit(),
        nil,
        index,
        socket
        |> assign(
          search_term: s,
          index: index,
          selected_tab: nil
          # sidebar_widgets: widget(s)
        )
        |> assign_global(search_more: true)
      )
    else
      {:noreply, socket}
    end
  end

  def handle_search_params(%{"hashtag_search" => s} = params, _url, socket)
      when s != "" do
    hashtag_s = "##{s}"
    previous_index = e(assigns(socket), :index, "nil")
    index = params["index"] || previous_index

    if hashtag_s != e(assigns(socket), :search_term, nil) or index != previous_index do
      Bonfire.Search.LiveHandler.live_search(
        hashtag_s,
        index,
        socket
        |> assign(search_term: s, search: s, index: index)
        |> assign_global(search_more: true)
      )
    else
      {:noreply, socket}
    end
  end

  def handle_search_params(%{"facet" => facets} = params, _url, socket) do
    index = params["index"] || e(assigns(socket), :index, "nil")

    index_type =
      e(facets, "index_type", nil)
      |> debug("selected_tabsss")

    Bonfire.Search.LiveHandler.live_search(
      e(assigns(socket), :search_term, nil),
      Bonfire.Search.LiveHandler.default_limit(),
      facets,
      index,
      socket
      |> assign(
        index: index,
        selected_tab: index_type
        # sidebar_widgets: widget(s)
      )
      |> assign_global(search_more: true)
    )
  end

  def handle_search_params(%{"index" => index} = params, _url, socket) do
    Bonfire.Search.LiveHandler.live_search(
      e(assigns(socket), :search_term, nil),
      index,
      socket
      |> assign(
        index: index
        # sidebar_widgets: widget(s)
      )
    )
  end

  def handle_search_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(search_term: nil)
     |> assign_global(search_more: true)}
  end

  # defp type_name(name) do
  #   String.split(name, ".") |> List.last() |> Recase.to_title()
  # end

  # defp link_body(name, 1 = num) do
  #   type_name = type_name(name) |> Inflex.singularize()
  #   "#{num} #{type_name}"
  # end

  # defp link_body(name, num) do
  #   type_name = type_name(name) |> Inflex.pluralize()
  #   "#{num} #{type_name}"
  # end

  def handle_event("toggle_index", %{"index" => new_index}, socket) do
    url =
      "/search?index=#{new_index}&facet[index_type]=#{socket.assigns.selected_tab}&s=#{socket.assigns.search}"

    {:noreply, push_patch(socket, to: url)}
  end

  def handle_event(
        "Bonfire.Search:search",
        params,
        %{assigns: %{__context__: %{selected_facets: selected_facets}}} = socket
      )
      when not is_nil(selected_facets) do
    handle_event(
      "Bonfire.Search:search",
      params,
      assign(socket, selected_facets: selected_facets)
    )
  end

  def handle_event(
        "Bonfire.Search:search",
        params,
        %{assigns: %{selected_facets: selected_facets}} = socket
      )
      when not is_nil(selected_facets) do
    debug(search_with_facet: params)

    # debug(socket)

    {:noreply,
     patch_to(
       socket,
       "/search?" <>
         Plug.Conn.Query.encode(facet: selected_facets) <> "&s=" <> params["s"]
     )}
  end

  def handle_event("Bonfire.Search:search", params, socket) do
    # debug(search: params)
    # debug(socket)

    {:noreply, patch_to(socket, "/search?s=" <> params["s"])}
  end

  def handle_async(name, result, socket) do
    # TODO: handle this redirection in LiveHandlers
    Bonfire.Search.LiveHandler.handle_async(name, result, socket)
  end
end
