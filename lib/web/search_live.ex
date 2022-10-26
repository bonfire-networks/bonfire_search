defmodule Bonfire.Search.Web.SearchLive do
  use Bonfire.UI.Common.Web, :surface_live_view
  alias Bonfire.UI.Me.LivePlugs

  alias Bonfire.Search.Web.ResultsLive

  @default_limit 20

  # declare_extension("Search", icon: "twemoji:magnifying-glass-tilted-left")

  def mount(params, session, socket) do
    live_plug(params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      # LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      Bonfire.UI.Common.LivePlugs.StaticChanged,
      Bonfire.UI.Common.LivePlugs.Csrf,
      Bonfire.UI.Common.LivePlugs.Locale,
      &mounted/3
    ])
  end

  defp mounted(params, session, socket) do
    # socket = init_assigns(params, session, socket)
    # debug(params, "PARAMS")

    {:ok,
     assign(
       socket,
       page: "search",
       page_title: "Search",
       selected_tab: "all",
       search_limit: @default_limit,
       #  me: false,
       #  selected_facets: nil,
       search: nil,
       hits: [],
       sidebar_widgets: widget(nil)
       #  facets: %{},
       #  num_hits: nil
     )}
  end

  defp widget(search) do
    [
      users: [
        secondary: [
          {Bonfire.UI.Coordination.FiltersSearchLive, [selected_tab: "all", search: search]}
        ]
      ]
    ]
  end

  def do_handle_params(%{"s" => s, "facet" => facets} = _params, _url, socket)
      when s != "" do
    index_type = e(facets, :index_type, nil)

    Bonfire.Search.LiveHandler.live_search(
      s,
      @default_limit,
      facets,
      socket
      |> assign(
        selected_tab: index_type,
        sidebar_widgets: widget(s)
      )
      |> assign_global(search_more: true)
    )
  end

  def do_handle_params(%{"s" => s} = _params, _url, socket) when s != "" do
    Bonfire.Search.LiveHandler.live_search(
      s,
      socket
      |> assign(sidebar_widgets: widget(s))
      |> assign_global(search_more: true)
    )
  end

  def do_handle_params(%{"hashtag_search" => s} = _params, _url, socket)
      when s != "" do
    Bonfire.Search.LiveHandler.live_search(
      "##{s}",
      assign_global(socket, search_more: true)
    )
  end

  def do_handle_params(_params, _url, socket) do
    {:noreply, assign_global(socket, search_more: true)}
  end

  def handle_params(params, uri, socket) do
    # poor man's hook I guess
    with {_, socket} <-
           Bonfire.UI.Common.LiveHandlers.handle_params(params, uri, socket) do
      undead_params(socket, fn ->
        do_handle_params(params, uri, socket)
      end)
    end
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

  def handle_event(action, attrs, socket),
    do:
      Bonfire.UI.Common.LiveHandlers.handle_event(
        action,
        attrs,
        socket,
        __MODULE__
      )
end
