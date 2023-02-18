defmodule Bonfire.Search.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  # TODO: put in config
  @default_limit 20

  def handle_event(
        "search",
        params,
        %{assigns: %{search_limit: search_limit}} = socket
      ) do
    debug(search: params)
    # debug(socket)

    live_search(params["s"], search_limit || @default_limit, nil, socket)
  end

  def handle_event(
        "search",
        params,
        %{assigns: %{__context__: %{search_limit: search_limit}}} = socket
      ) do
    debug(search: params)
    # debug(socket)

    live_search(params["s"], search_limit || @default_limit, nil, socket)
  end

  def handle_event("search", params, %{assigns: _assigns} = socket) do
    debug(search: params)
    # debug(socket)

    live_search(
      params["s"],
      params["search_limit"] || @default_limit,
      nil,
      socket
    )
  end

  def live_search(
        q,
        search_limit \\ @default_limit,
        facet_filters \\ nil,
        socket
      )

  def live_search(q, search_limit, facet_filters, socket)
      when is_binary(search_limit) and search_limit != "" do
    # debug(search_limit)
    search_limit = String.to_integer(search_limit) || @default_limit
    live_search(q, search_limit, facet_filters, socket)
  end

  def live_search(q, search_limit, facet_filters, socket)
      when search_limit == "" do
    live_search(q, @default_limit, facet_filters, socket)
  end

  def live_search(q, search_limit, facet_filters, socket)
      when is_binary(q) and q != "" and is_integer(search_limit) do
    # debug(q, "SEARCH")
    debug(facet_filters, "TAB")

    opts = %{limit: search_limit}

    search = Bonfire.Search.Fuzzy.search(q, opts, ["index_type"], facet_filters)

    # debug(search_results: search)

    hits =
      if(
        is_map(search) and Map.has_key?(search, "hits") and
          length(search["hits"])
      ) do
        search["hits"]
        # return object-like results
        |> Enum.map(
          &(&1
            |> input_to_atoms()
            |> maybe_to_structs())
        )
      end

    # note we only get proper facets when not already faceting
    facets =
      if !facet_filters and e(search, "facetDistribution", nil) do
        e(search, "facetDistribution", nil)
      else
        e(socket.assigns, :facets, nil)
      end

    # TODO: make this a non-blocking operation (ie. show the other results first and then inject the result of this lookup when ready)
    # FIXME: use maybe_apply
    hits =
      (with {:ok, federated_object_or_character} <-
              Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(q,
                fetch_collection: :async
              ) do
         [federated_object_or_character] ++
           (hits || [])
       else
         _ ->
           hits
       end ||
         [])
      |> Enum.uniq_by(&%{id: &1.id})

    # debug(hits, "hits")

    # TODO use send_update to send results to ResultsLive
    {:noreply,
     assign_global(socket,
       selected_facets: facet_filters,
       hits: hits,
       facets: facets,
       num_hits: e(search, "nbHits", 0),
       search: q
       #  current_user: current_user(socket)
     )}
  end

  def live_search(q, _search_limit, _facet_filters, socket) do
    debug(q, "invalid search")
    {:noreply, socket}
  end

  # def handle_event("search", params, %{assigns: _assigns} = socket) do
  #   debug(search: params)
  #   debug(socket)

  #   if(socket.view == Bonfire.Search.Web.SearchLive) do
  #     {:noreply,
  #     socket |> patch_to("/instance/search/all/" <> params["search_field"]["query"])}
  #   else
  #     {:noreply,
  #     socket |> redirect_to("/instance/search/all/" <> params["search_field"]["query"])}
  #   end
  # end
end
