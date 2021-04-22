defmodule Bonfire.Search.LiveHandler do

  alias Bonfire.Common.Utils

  def handle_event("search", params, %{assigns: _assigns} = socket) do
    IO.inspect(search: params)
    # IO.inspect(socket)

    if(socket.view == Bonfire.Search.Web.SearchLive) do
      {:noreply,
      socket |> Phoenix.LiveView.push_patch(to: "/instance/search/all/" <> params["search_field"]["query"])}
    else
      live_search(params["search_field"]["query"], socket)
    end
  end


  def live_search(q, facet \\ nil, socket) when is_binary(q) and q != "" do
    # IO.inspect(q, label: "SEARCH")
    # IO.inspect(facet, label: "TAB")

    facet_filters =
      if facet && facet != "all" do
        %{"index_type" => facet}
      end

    search = Bonfire.Search.search(q, nil, ["index_type"], facet_filters)

    IO.inspect(search: search)

    hits =
      if(Map.has_key?(search, "hits") and length(search["hits"])) do
        # search["hits"]
        Enum.map(search["hits"], &search_hit_prepare/1)
        # Enum.filter(hits, & &1)
      end

    # note we only get proper facets when not already faceting
    facets =
      if (!facet || facet == "all") and Map.has_key?(search, "facetsDistribution") do
        search["facetsDistribution"]
      else
        Utils.e(socket.assigns, :facets, nil)
      end

    IO.inspect(hits: hits)

    {:noreply,
     Phoenix.LiveView.assign(socket,
       selected_tab: facet,
       hits: hits,
       facets: facets,
       num_hits: search["nbHits"],
       search: q
       #  current_user: socket.assigns.current_user
     )}
  end

  def live_search(q, facet, socket) do
    {:noreply, socket}
  end

  def search_hit_prepare(hit) do
    hit
    |> Utils.maybe_to_structs()
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
