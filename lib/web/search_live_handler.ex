defmodule Bonfire.Search.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  alias Bonfire.Search.Filters

  def default_limit,
    do: Bonfire.Common.Config.get(:default_pagination_limit, 20)

  def handle_event("go_search", %{"s" => "#" <> hashtag} = _params, socket) do
    # TODO: show results in a modal rather than a separate page?

    {:noreply, socket |> redirect_to("/search/tag/#{hashtag}")}
  end

  def handle_event("go_search", %{"s" => s, "facet" => facet} = _params, socket)
      when facet != %{} do
    url = "/search/?facet[index_type]=#{facet["index_type"]}&s=#{s}"
    {:noreply, socket |> redirect_to(url)}
  end

  def handle_event("go_search", %{"s" => s} = _params, socket) do
    {:noreply, socket |> assign(selected_tab: nil) |> redirect_to("/search/?s=" <> s)}
  end

  def handle_event("patch_search", %{"s" => "#" <> hashtag} = _params, socket) do
    {:noreply, socket |> patch_to("/search/tag/#{hashtag}")}
  end

  def handle_event("patch_search", %{"s" => s} = params, socket) do
    # Use existing search term if the provided one is empty
    search_term =
      if s == "" or is_nil(s) do
        e(assigns(socket), :search_term, nil) || e(assigns(socket), :search, "")
      else
        s
      end

    # Only patch if we have a valid search term
    if search_term != "" and not is_nil(search_term) do
      # A form that names no facet keeps the tab the user is on (so tab-scoped filters
      # survive a re-search); an explicit facet switches to it
      facet =
        case e(params, "facet", "index_type", nil) do
          empty when empty in ["", nil] ->
            e(assigns(socket), :selected_tab, nil)

          index_type ->
            index_type
        end

      # keep the current index and any active search filters in the URL
      url =
        Filters.tab_url(
          search_term,
          e(assigns(socket), :index, "public"),
          e(assigns(socket), :search_filters, %{}),
          facet
        )

      {:noreply, patch_to(socket, url)}
    else
      # If no search term available, just stay on the page
      {:noreply, socket}
    end
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

  def live_search("#" <> hashtag = s, _, _, _, socket, _) do
    # let the Hashtag view handle it by default
    {:noreply,
     socket
     |> assign(selected_tab: Filters.hashtag_tab(), search: hashtag, search_term: s)}
  end

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

    # Set searching state to true
    socket = assign(socket, searching: true)

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

    current_user = current_user(socket)

    search_opts = %{
      limit: search_limit,
      offset: offset,
      current_user: current_user,
      index: index,
      # applied DB-side when loading hits (see Bonfire.Search.load_activities_for_search/2);
      # the Meili adapter must drop this key from its passthrough search params
      feed_filters: e(assigns(socket), :search_filters, %{})
    }

    # Start the async direct lookup only for URLs and @mentions (not plain text searches)
    if socket_connected?(socket) do
      socket =
        if String.starts_with?(q, ["http://", "https://", "@"]) do
          socket
          |> assign(searching_direct: true)
          |> start_async(:direct_lookup, fn ->
            Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(q,
              user_id: id(current_user)
            )
            |> debug("got_by_url_ap_id_or_username")
          end)
        else
          socket
        end

      content_live_search(q, search_limit, facet_filters, socket, search_opts, opts)
    else
      {:noreply, socket}
    end
  end

  def live_search(q, _search_limit, _facet_filters, _index, socket, _opts) do
    debug(q, "invalid search")
    {:noreply, socket}
  end

  # Handle the federated lookup result
  def handle_async(:direct_lookup, {:ok, {:ok, federated_object_or_character}}, socket) do
    q = e(assigns(socket), :search, nil)
    current_hits = e(assigns(socket), :hits, [])
    current_user_hits = e(assigns(socket), :user_hits, [])

    if String.starts_with?(q || "", "http") and current_hits == [] and current_user_hits == [] do
      # Handle URL case when there are no other hits - redirect to the federated object's page
      {:noreply,
       socket
       |> assign(searching_direct: false)
       |> redirect_to(path(federated_object_or_character))}
    else
      # Load the federated result through the same pipeline as search results
      result_id = Enums.id(federated_object_or_character)

      if result_id do
        # Check if the result is a user/character type
        result_type = Types.object_type(federated_object_or_character)

        if result_type in [Bonfire.Data.Identity.User, Bonfire.Data.Identity.Character] do
          # It's a user — add to user_hits directly
          updated_user_hits =
            [federated_object_or_character | current_user_hits]
            |> Enum.uniq_by(&Enums.id/1)

          {:noreply,
           assign(socket,
             user_hits: updated_user_hits,
             num_hits: length(current_hits) + length(updated_user_hits),
             searching_direct: false
           )}
        else
          # It's a post/content — load via standard feed pipeline
          loaded =
            Bonfire.Search.load_activities_for_search(
              [result_id],
              current_user: current_user(socket)
            )

          if loaded != [] do
            updated_hits =
              (loaded ++ current_hits)
              |> Enum.uniq_by(&Enums.id/1)

            {:noreply,
             assign(socket,
               hits: updated_hits,
               num_hits: length(updated_hits) + length(current_user_hits),
               searching_direct: false
             )}
          else
            # Couldn't load as activity, add as-is to user_hits as fallback
            updated_user_hits =
              [federated_object_or_character | current_user_hits]
              |> Enum.uniq_by(&Enums.id/1)

            {:noreply,
             assign(socket,
               user_hits: updated_user_hits,
               num_hits: length(current_hits) + length(updated_user_hits),
               searching_direct: false
             )}
          end
        end
      else
        {:noreply, assign(socket, searching_direct: false)}
      end
    end
  end

  # Handle case where no federated result is found

  # Handle errors in the federated lookup (just log, don't affect UI)
  def handle_async(:direct_lookup, {:exit, reason}, socket) do
    warn(reason, "Federated lookup failed")
    {:noreply, assign(socket, searching_direct: false)}
  end

  def handle_async(:direct_lookup, _, socket) do
    # The federated lookup (of a URL or @handle) found nothing. If federation isn't open, it likely
    # couldn't reach the remote server — tell the user why (#647/#2058). Open + manual modes both
    # allow on-demand lookup, so a not-found there is genuine and gets no notice.
    socket =
      case maybe_apply(Bonfire.Federate.ActivityPub, :federation_mode, [current_user(socket)],
             fallback_return: true
           ) do
        false ->
          assign_flash(
            socket,
            :info,
            l(
              "Federation is currently disabled, so profiles or posts from other servers can't be looked up."
            )
          )

        :allowlist_only ->
          assign_flash(
            socket,
            :info,
            l(
              "This instance only federates with allow-listed servers, so that profile or post may not be reachable."
            )
          )

        _ ->
          socket
      end

    {:noreply, assign(socket, searching_direct: false)}
  end

  @overview_people_limit 6

  @doc "How many people the All tab's strip shows (a dedicated typed query, see below)."
  def overview_people_limit, do: @overview_people_limit

  # People need a typed query: mixed search ranks them against posts and can fill a page with posts alone.
  defp maybe_overview_people(search_result, q, nil = _facet_filters, opts) do
    if e(opts, :offset, 0) in [0, nil] do
      people =
        Bonfire.Search.search_and_load(
          q,
          ["index_type"],
          %{"index_type" => Filters.people_tab()},
          Map.merge(opts, %{limit: @overview_people_limit, offset: 0})
        )

      Map.put(search_result, :users, e(people, :users, []))
    else
      search_result
    end
  end

  defp maybe_overview_people(search_result, _q, _facet_filters, _opts), do: search_result

  # Posts includes articles, which have their own index type. Use the mixed index and
  # the existing DB content-type filter so Sonic and Meili share this query path.
  defp search_query(facets, opts) do
    if facets == %{"index_type" => Filters.posts_tab()} do
      filters = Map.put_new(opts.feed_filters, :object_types, Filters.object_types())
      {nil, Map.put(opts, :feed_filters, filters)}
    else
      {facets, opts}
    end
  end

  # max further candidate pages to try when DB-side filters prune a page to nothing
  @max_empty_pages 3

  # DB-side filters run after the index has picked a page of candidates, so a filtered
  # page can come back empty while later ones still match: skip ahead a few pages
  # rather than showing "nothing found" above a "Load more" button.
  defp search_skipping_empty_pages(q, facets, opts, tries_left \\ @max_empty_pages) do
    result = Bonfire.Search.search_and_load(q, Map.keys(facets || %{}), facets, opts)

    with [] when tries_left > 0 <- e(result, :activities, []),
         true <- Bonfire.Search.feed_filters(opts) != %{},
         cursor when is_binary(cursor) <- e(result, :page_info, :end_cursor, nil),
         {offset, ""} <- Integer.parse(cursor) do
      search_skipping_empty_pages(q, facets, Map.put(opts, :offset, offset), tries_left - 1)
    else
      _ -> result
    end
  end

  defp content_live_search(
         q,
         search_limit,
         facet_filters,
         socket,
         search_opts,
         live_opts
       )
       when is_binary(q) and q != "" and is_integer(search_limit) do
    try do
      {query_facets, query_opts} = search_query(facet_filters, search_opts)

      search_result =
        search_skipping_empty_pages(q, query_facets, query_opts)
        |> debug("search_and_load result")
        |> maybe_overview_people(q, facet_filters, search_opts)

      activities = e(search_result, :activities, [])
      users = e(search_result, :users, [])

      # Handle pagination state - append to existing hits on load_more
      current_hits =
        if live_opts[:append] && is_list(e(assigns(socket), :hits, nil)) do
          e(assigns(socket), :hits, []) ++ activities
        else
          activities
        end

      current_user_hits =
        if live_opts[:append] && is_list(e(assigns(socket), :user_hits, nil)) do
          e(assigns(socket), :user_hits, []) ++ users
        else
          users
        end

      {:noreply,
       socket
       |> assign(
         index: search_opts[:index],
         selected_facets: facet_filters,
         hits: current_hits,
         user_hits: current_user_hits,
         facets: search_result.facets || e(assigns(socket), :facets, nil),
         num_hits: search_result.total_hits,
         search: q,
         search_term: q,
         page_info: search_result.page_info,
         searching: false
       )}
    rescue
      error ->
        error(error, "Search failed")
        # keep the term so the input and result-type tabs stay consistent with what was searched
        {:noreply, assign(socket, searching: false, search: q, search_term: q)}
    end
  end
end
