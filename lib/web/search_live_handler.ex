defmodule Bonfire.Search.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  def default_limit,
    do: Bonfire.Common.Config.get(:default_pagination_limit, 20)

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
      search_limit || default_limit(),
      params["facet"],
      params["index"] || e(assigns(socket), :index, nil),
      socket,
      reset: true
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
      search_limit || default_limit(),
      params["facet"],
      params["index"] || e(assigns(socket), :index, nil),
      socket,
      reset: true
    )
  end

  def handle_event("search", params, %{assigns: _assigns} = socket) do
    live_search(
      params["s"],
      params["search_limit"] || default_limit(),
      params["facet"],
      params["index"] || e(assigns(socket), :index, nil),
      socket,
      reset: true
    )
  end

  def handle_event("load_more", params, %{assigns: assigns} = socket) do
    search_term = e(assigns, :search_term, nil) || e(assigns, :search, nil)

    if is_nil(search_term) or search_term == "" do
      {:noreply, assign_flash(socket, :error, l("No search term found"))}
    else
      pagination = input_to_atoms(params)

      try do
        search_limit = e(assigns, :search_limit, default_limit())

        live_search(
          search_term,
          search_limit,
          e(assigns, :selected_facets, nil),
          e(assigns, :index, nil),
          socket,
          pagination: pagination,
          append: true
        )
      rescue
        error in [ArgumentError] ->
          error(error, "Invalid pagination parameters")
          {:noreply, assign_flash(socket, :error, l("Invalid pagination parameters"))}

        error ->
          error(error, "Failed to load more search results")
          {:noreply, assign_flash(socket, :error, l("Could not load more results"))}
      end
    end
  end

  def handle_event("preload_more", params, socket) do
    # Same as load_more but for infinite scroll preloading
    handle_event("load_more", params, socket)
  end

  def live_search(
        q,
        search_limit \\ default_limit(),
        facet_filters \\ nil,
        index,
        socket,
        opts \\ []
      )

  def live_search(q, search_limit, facet_filters, index, socket, opts)
      when is_binary(search_limit) and search_limit != "" do
    search_limit = String.to_integer(search_limit) || default_limit()
    live_search(q, search_limit, facet_filters, index, socket, opts)
  end

  def live_search(q, search_limit, facet_filters, index, socket, opts)
      when search_limit == "" or is_nil(search_limit) do
    live_search(q, default_limit(), facet_filters, index, socket, opts)
  end

  def live_search(q, search_limit, facet_filters, index, socket, opts)
      when is_binary(q) and q != "" and is_integer(search_limit) do
    debug(q, "SEARCHING")
    debug(facet_filters, "FACET")
    debug(opts, "OPTS")

    q = String.trim(q)

    # Handle pagination - extract offset from cursor or default to 0
    offset =
      case opts[:pagination] do
        %{after: cursor} when is_binary(cursor) ->
          case Integer.parse(cursor) do
            {offset_val, ""} -> offset_val
            _ -> 0
          end

        _ ->
          0
      end

    search_opts = %{
      limit: search_limit,
      offset: offset,
      current_user: current_user(socket),
      index: index
    }

    # First perform the regular search immediately
    {:noreply, socket} =
      result = content_live_search(q, search_limit, facet_filters, [], socket, search_opts, opts)

    # Start the async direct lookup if socket is connected
    if socket_connected?(socket) do
      {:noreply,
       socket
       |> start_async(:direct_lookup, fn ->
         Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(q)
         |> debug("got_by_url_ap_id_or_username")
       end)}
    else
      result
    end
  end

  def live_search(q, _search_limit, _facet_filters, _index, socket, _opts) do
    debug(q, "invalid search")
    {:noreply, socket}
  end

  # Handle the federated lookup result
  def handle_async(:direct_lookup, {:ok, {:ok, federated_object_or_character}}, socket) do
    q = socket.assigns.search

    if String.starts_with?(q, "http") and e(assigns(socket), :hits, []) == [] do
      # Handle URL case when there are no other hits - redirect to the federated object's page
      {:noreply, socket |> redirect_to(path(federated_object_or_character))}
    else
      # Handle username case - add result to search results
      %{assigns: %{hits: current_hits, num_hits: current_num_hits}} = socket

      # Add federated result to existing hits
      updated_hits =
        [federated_object_or_character | current_hits]
        |> Enum.uniq_by(&Enums.id/1)
        |> debug("search merged with federated result")

      {:noreply, assign(socket, hits: updated_hits, num_hits: length(updated_hits))}
    end
  end

  # Handle case where no federated result is found

  # Handle errors in the federated lookup (just log, don't affect UI)
  def handle_async(:direct_lookup, {:exit, reason}, socket) do
    warn(reason, "Federated lookup failed")
    {:noreply, socket}
  end

  def handle_async(:direct_lookup, _, socket) do
    # No changes needed when no result is found
    {:noreply, socket}
  end

  defp content_live_search(
         q,
         search_limit,
         facet_filters,
         extra_results,
         socket,
         search_opts,
         live_opts
       )
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

    {num_hits, hits, facets, page_info} =
      do_search(q, facet_filters, search_opts)
      |> debug("content_searched")

    # + length(tagged)
    total_hits = (num_hits || 0) + length(extra_results)

    # ++ tagged
    new_hits =
      (extra_results ++ hits)
      |> Enum.uniq_by(&Enums.id/1)
      |> debug("search2 merged")

    # Handle pagination state
    current_hits =
      if live_opts[:append] && is_list(e(assigns(socket), :hits, nil)) do
        e(assigns(socket), :hits, []) ++ new_hits
      else
        new_hits
      end

    {:noreply,
     assign(socket,
       index: search_opts[:index],
       selected_facets: facet_filters,
       hits: current_hits,
       facets: facets || e(assigns(socket), :facets, nil),
       num_hits: total_hits,
       search: q,
       search_term: q,
       page_info: page_info
       #  current_user: current_user(socket)
     )}
  end

  defp do_search(q, facet_filters, opts) do
    facet_filters = facet_filters || %{}

    search =
      Bonfire.Search.search(q, opts, Map.keys(facet_filters), facet_filters)
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

    # Extract pagination info from Meilisearch response
    total_hits = search.estimatedTotalHits || search.totalHits || search.nb_hits || length(hits)
    limit = e(search, :limit, e(search, :hitsPerPage, opts[:limit])) || opts[:limit] || 20
    offset = e(search, :offset, 0) || opts[:offset] || 0

    # Build page_info similar to feed pagination
    # Check if there are more results by comparing total hits with current position
    has_more = total_hits > offset + limit

    page_info =
      if has_more do
        %{
          has_next_page: true,
          end_cursor: to_string(offset + limit)
        }
      else
        %{
          has_next_page: false,
          end_cursor: nil
        }
      end

    {total_hits, hits || [], facets, page_info}
  end
end
