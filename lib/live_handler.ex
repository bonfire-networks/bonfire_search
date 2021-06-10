defmodule Bonfire.Search.LiveHandler do
  use Bonfire.Web, :live_handler

  @default_limit 20

  def handle_event("search", params, %{assigns: %{search_limit: search_limit}} = socket) do
    IO.inspect(search: params)
    # IO.inspect(socket)

    live_search(params["s"], search_limit || @default_limit, nil, socket)
  end

  def handle_event("search", params, %{assigns: %{__context__: %{search_limit: search_limit}}} = socket) do
    IO.inspect(search: params)
    # IO.inspect(socket)

    live_search(params["s"], search_limit || @default_limit, nil, socket)
  end

  def handle_event("search", params, %{assigns: _assigns} = socket) do
    IO.inspect(search: params)
    # IO.inspect(socket)

    live_search(params["s"], params["search_limit"] || @default_limit, nil, socket)
  end

  def live_search(q, search_limit \\ @default_limit, facet_filters \\ nil, socket)

  def live_search(q, search_limit, facet_filters, socket) when is_binary(search_limit) and search_limit !="" do
    IO.inspect(search_limit)
    search_limit = String.to_integer(search_limit) || @default_limit
    live_search(q, search_limit, facet_filters, socket)
  end

  def live_search(q, search_limit, facet_filters, socket) when is_binary(q) and q != "" and is_integer(search_limit) do
    # IO.inspect(q, label: "SEARCH")
    # IO.inspect(facet_filters, label: "TAB")

    opts = %{limit: search_limit}

    search = Bonfire.Search.search(q, opts, ["index_type"], facet_filters)

    # IO.inspect(search_results: search)

    hits =
      if(is_map(search) and Map.has_key?(search, "hits") and length(search["hits"])) do
        # search["hits"]
        Enum.map(search["hits"], &search_hit_prepare/1)
        # Enum.filter(hits, & &1)
      end

    # note we only get proper facets when not already faceting
    facets =
      if !facet_filters and Map.has_key?(search, "facetsDistribution") do
        search["facetsDistribution"]
      else
        e(socket.assigns, :facets, nil)
      end

    # IO.inspect(hits: hits)
    IO.inspect(facets: facets)

    # TODO use send_update to send results to ResultsLive
    {:noreply,
     assign_global(socket,
       selected_facets: facet_filters,
       hits: hits,
       facets: facets,
       num_hits: search["nbHits"],
       search: q
       #  current_user: current_user(socket)
     )}
  end

  def live_search(q, search_limit, facet_filters, socket) do
    IO.inspect(invalid_search: search_limit)
    {:noreply, socket}
  end

  def search_hit_prepare(hit) do
    hit
    |> maybe_to_structs()
  end

  # def handle_event("search", params, %{assigns: _assigns} = socket) do
  #   IO.inspect(search: params)
  #   IO.inspect(socket)

  #   if(socket.view == Bonfire.Search.Web.SearchLive) do
  #     {:noreply,
  #     socket |> Phoenix.LiveView.push_patch(to: "/instance/search/all/" <> params["search_field"]["query"])}
  #   else
  #     {:noreply,
  #     socket |> Phoenix.LiveView.push_redirect(to: "/instance/search/all/" <> params["search_field"]["query"])}
  #   end
  # end


end
