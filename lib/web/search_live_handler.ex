defmodule Bonfire.Search.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  # TODO: put in config
  @default_limit 20

  def handle_event("go_search", %{"s" => s} = _params, socket) do
    # TODO: show results in a modal rather than a seperate page

    {:noreply, socket |> redirect_to("/search/?s=" <> s)}
  end

  def handle_event(
        "search",
        params,
        %{assigns: %{search_limit: search_limit}} = socket
      ) do
    live_search(
      params["s"],
      search_limit || @default_limit,
      params["facet"],
      params["index"] || e(assigns(socket), :index, nil),
      socket
    )
  end

  def handle_event(
        "search",
        params,
        %{assigns: %{__context__: %{search_limit: search_limit}}} = socket
      ) do
    # debug(socket)

    live_search(
      params["s"],
      search_limit || @default_limit,
      params["facet"],
      params["index"] || e(assigns(socket), :index, nil),
      socket
    )
  end

  def handle_event("search", params, %{assigns: _assigns} = socket) do
    live_search(
      params["s"],
      params["search_limit"] || @default_limit,
      params["facet"],
      params["index"] || e(assigns(socket), :index, nil),
      socket
    )
  end

  def live_search(
        q,
        search_limit \\ @default_limit,
        facet_filters \\ nil,
        index,
        socket
      )

  def live_search(q, search_limit, facet_filters, index, socket)
      when is_binary(search_limit) and search_limit != "" do
    search_limit = String.to_integer(search_limit) || @default_limit
    live_search(q, search_limit, facet_filters, index, socket)
  end

  def live_search(q, search_limit, facet_filters, index, socket)
      when search_limit == "" or is_nil(search_limit) do
    live_search(q, @default_limit, facet_filters, index, socket)
  end

  def live_search(q, search_limit, facet_filters, index, socket)
      when is_binary(q) and q != "" and is_integer(search_limit) do
    debug(q, "SEARCHING")
    debug(facet_filters, "FACET")

    q = String.trim(q)
    opts = %{limit: search_limit, current_user: current_user(socket), index: index}

    # TODO: make this a non-blocking operation? (ie. show the other results first and then inject the result of this lookup when ready)
    # FIXME: use maybe_apply
    # TODO fetch async and use send_update to send results to ResultsLive?
    with {:ok, federated_object_or_character} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
             q
             #  fetch_collection: :async
           )
           |> debug("got_by_url_ap_id_or_username") do
      if String.starts_with?(q, "http") do
        {:noreply, socket |> redirect_to(path(federated_object_or_character))}
      else
        content_live_search(
          q,
          search_limit,
          facet_filters,
          [federated_object_or_character],
          socket,
          opts
        )
      end
    else
      _ ->
        content_live_search(q, search_limit, facet_filters, [], socket, opts)
    end
  end

  def live_search(q, _search_limit, _facet_filters, _index, socket) do
    debug(q, "invalid search")
    {:noreply, socket}
  end

  defp content_live_search(q, search_limit, facet_filters, extra_results, socket, opts)
       when is_binary(q) and q != "" and is_integer(search_limit) do
    # tagged =
    #   with hashtags when is_list(hashtags) <-
    #          Bonfire.Tag.search_hashtag(
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
      |> debug("content_searched")

    # + length(tagged)
    num_hits = (num_hits || 0) + length(extra_results)

    # ++ tagged
    hits =
      (extra_results ++ hits)
      |> Enum.uniq_by(&Enums.id/1)
      |> debug("search2 merged")

    {:noreply,
     assign(socket,
       index: opts[:index],
       selected_facets: facet_filters,
       hits: hits,
       facets: facets || e(assigns(socket), :facets, nil),
       num_hits: num_hits,
       search: q
       #  current_user: current_user(assigns(socket))
     )}
  end

  defp do_search(q, facet_filters, opts) do
    facet_filters = facet_filters || %{}

    search =
      Bonfire.Search.search(q, opts, Map.keys(facet_filters), Map.values(facet_filters))
      |> debug("did_search")

    hits = e(search, :hits, [])
    # if(
    #   is_map(search) and Map.has_key?(search, "hits") and
    #     length(search["hits"])
    # ) do
    #   search["hits"]
    #   # return object-like results
    #   |> Enum.map(
    #     &(&1
    #       |> input_to_atoms()
    #       |> maybe_to_structs())
    #   )
    # else
    #   if is_list(search), do: search
    # end

    # note we only get proper facets when not already faceting
    facets =
      if !facet_filters and e(search, :facet_distribution, nil) do
        e(search, :facet_distribution, nil)
      end

    {e(search, :nb_hits, 0) || e(search, :estimated_total_hits, 0) || length(hits), hits || [],
     facets}
  end
end
