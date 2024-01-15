defmodule Bonfire.Search.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  # TODO: put in config
  @default_limit 20

  def handle_event("go_search", %{"s" => s} = params, socket) do
    # TODO: show results in a modal rather than a seperate page

    {:noreply, socket |> redirect_to("/search/?s=" <> s)}
  end

  def handle_event(
        "search",
        params,
        %{assigns: %{search_limit: search_limit}} = socket
      ) do
    live_search(params["s"], search_limit || @default_limit, params["facet"], socket)
  end

  def handle_event(
        "search",
        params,
        %{assigns: %{__context__: %{search_limit: search_limit}}} = socket
      ) do
    # debug(socket)

    live_search(params["s"], search_limit || @default_limit, params["facet"], socket)
  end

  def handle_event("search", params, %{assigns: _assigns} = socket) do
    live_search(
      params["s"],
      params["search_limit"] || @default_limit,
      params["facet"],
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
    search_limit = String.to_integer(search_limit) || @default_limit
    live_search(q, search_limit, facet_filters, socket)
  end

  def live_search(q, search_limit, facet_filters, socket)
      when search_limit == "" or is_nil(search_limit) do
    live_search(q, @default_limit, facet_filters, socket)
  end

  def live_search(q, search_limit, facet_filters, socket)
      when is_binary(q) and q != "" and is_integer(search_limit) do
    debug(q, "SEARCHING")
    debug(facet_filters, "FACET")

    q = String.trim(q)
    opts = %{limit: search_limit, current_user: current_user(socket)}

    # TODO: make this a non-blocking operation? (ie. show the other results first and then inject the result of this lookup when ready)
    # FIXME: use maybe_apply
    # TODO fetch async and use send_update to send results to ResultsLive?
    by_link_or_username =
      with {:ok, federated_object_or_character} <-
             Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
               q
               #  fetch_collection: :async
             )
             |> debug("got_by_url_ap_id_or_username") do
        [federated_object_or_character]
        # {:noreply, socket |> redirect_to(path(federated_object_or_character))}
      else
        _ ->
          []
      end

    # tagged =
    #   with hashtags when is_list(hashtags) <-
    #          Bonfire.Tag.Tags.search_hashtag(
    #            q
    #            #  fetch_collection: :async
    #          )
    #          |> debug("got_hashtags") do
    #     hashtags
    #     # {:noreply, socket |> redirect_to(path(federated_object_or_character))}
    #   else
    #     _ ->
    #       []
    #   end

    {num_hits, hits, facets} =
      do_search(q, facet_filters, opts)
      |> debug("did_search1")

    # + length(tagged)
    num_hits = (num_hits || 0) + length(by_link_or_username)

    # ++ tagged 
    hits =
      (by_link_or_username ++ hits)
      |> Enum.uniq_by(&Enums.id/1)
      |> debug("search2 merged")

    {:noreply,
     assign_global(socket,
       selected_facets: facet_filters,
       hits: hits,
       facets: facets || e(socket.assigns, :facets, nil),
       num_hits: num_hits,
       search: q
       #  current_user: current_user(socket.assigns)
     )}
  end

  def live_search(q, _search_limit, _facet_filters, socket) do
    debug(q, "invalid search")
    {:noreply, socket}
  end

  defp do_search(q, facet_filters, opts) do
    facet_filters = facet_filters || %{}

    search =
      Bonfire.Search.search(q, opts, Map.keys(facet_filters), Map.values(facet_filters))
      |> debug("did_search1")

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
      else
        if is_list(search), do: search
      end

    # note we only get proper facets when not already faceting
    facets =
      if !facet_filters and e(search, "facetDistribution", nil) do
        e(search, "facetDistribution", nil)
      end

    {e(search, "nbHits", 0) || length(hits), hits || [], facets}
  end
end
