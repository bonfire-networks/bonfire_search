defmodule Bonfire.Search.UI.FiltersSearchLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop filters, :any, default: %{}
  prop search, :string, default: nil
  prop index, :string, default: "public"
  prop selected_tab, :any, default: nil

  @type_facets ["Bonfire.Data.Identity.User", "Bonfire.Data.Social.Post"]

  @doc "The selected tab when it is a result-type facet (Users / Posts), else nil."
  def type_facet(selected_tab) when selected_tab in @type_facets, do: selected_tab
  def type_facet(_), do: nil

  @doc "The result-type tabs as `{url, label}` pairs for `Bonfire.UI.Common.TabsLive`."
  def tabs(term, index, filters) do
    [
      {tab_url(term, index, filters), l("All")},
      {tab_url(term, index, filters, "Bonfire.Data.Identity.User"), l("Users")},
      {tab_url(term, index, filters, "Bonfire.Data.Social.Post"), l("Posts")},
      {hashtag_url(term), l("Hashtags")}
    ]
  end

  @doc "The URL of the active tab (TabsLive marks the tab whose key equals `selected_tab`)."
  def active_tab_url("hashtag", term, _index, _filters), do: hashtag_url(term)

  def active_tab_url(selected_tab, term, index, filters),
    do: tab_url(term, index, filters, type_facet(selected_tab))

  @doc """
  Builds a `/search` URL preserving the current query, index, optional type
  facet, and any active search filters (so switching tabs keeps them).
  """
  def tab_url(term, index, filters, facet \\ nil) do
    query =
      %{"s" => term, "index" => index}
      |> maybe_put_facet(facet)
      |> maybe_put_filters(filters)

    "/search?" <> Plug.Conn.Query.encode(query)
  end

  @doc "Builds a `/search/tag/` URL (the hashtag tab has no filters of its own)."
  def hashtag_url(tag), do: "/search/tag/#{String.trim_leading(tag || "", "#")}"

  defp maybe_put_facet(query, nil), do: query
  defp maybe_put_facet(query, facet), do: Map.put(query, "facet", %{"index_type" => facet})

  # filters are scoped by tab: only carry the ones the destination tab can use
  defp maybe_put_filters(query, filters) do
    facet = e(query, "facet", "index_type", nil)

    case filters |> Bonfire.Search.Filters.for_tab(facet) |> Bonfire.Search.Filters.filters_to_params() do
      empty when empty == %{} -> query
      params -> Map.put(query, "filters", params)
    end
  end
end
