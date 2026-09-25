defmodule Bonfire.Search.Filters do
  @moduledoc """
  Search tab rules and `/search` URL building. Filters apply to posts only, so only the Posts tab offers (and keeps) them.

  URL params are cast by the feeds' own `Bonfire.Social.FeedFilters.changeset/2`, keeping only the keys search offers.
  """
  alias Bonfire.Social.FeedFilters

  @people_tab "Bonfire.Data.Identity.User"
  @posts_tab "Bonfire.Data.Social.Post"
  @hashtag_tab "hashtag"

  @object_types [:post, :article]
  @media_types [:link, :image, :video, :audio]

  # the filters editor's rows, and the filter keys they set
  # (authors use :subjects, not :creators, so replies match too)
  @sections [:from_people, :not_people, :hashtags, :origin, :object_types, :media_types]
  @filter_keys [
    :subjects,
    :exclude_subjects,
    :tags,
    :origin,
    :object_types,
    :exclude_object_types,
    :media_types,
    :exclude_media_types
  ]

  def people_tab, do: @people_tab
  def posts_tab, do: @posts_tab
  def hashtag_tab, do: @hashtag_tab
  def object_types, do: @object_types
  def media_types, do: @media_types
  def sections, do: @sections

  @doc """
  The selected tab when it is a result-type facet (People / Posts), else nil (All).

      iex> Bonfire.Search.Filters.type_facet("Bonfire.Data.Social.Post")
      "Bonfire.Data.Social.Post"
      iex> Bonfire.Search.Filters.type_facet("hashtag")
      nil
  """
  def type_facet(tab) when tab in [@people_tab, @posts_tab], do: tab
  def type_facet(_), do: nil

  @doc "True for tabs that list one result type in full (and paginate), as opposed to the All overview."
  def typed_tab?(tab), do: tab in [@people_tab, @posts_tab, @hashtag_tab]

  @doc "True for the one tab that has filters (Posts)."
  def filtered_tab?(tab), do: tab == @posts_tab

  @doc """
  Casts untrusted URL params with `FeedFilters.changeset/2` (its `changes`, so no struct defaults), keeping only the search filter keys.

      iex> Bonfire.Search.Filters.cast_filters(%{"object_types" => "article", "sort_by" => "like_count"})
      %{object_types: [:article]}
  """
  def cast_filters(params) when is_map(params) do
    params
    |> FeedFilters.changeset()
    |> Map.get(:changes)
    |> compact()
  end

  def cast_filters(_), do: %{}

  @doc """
  Builds a `/search` URL preserving the query, index, optional type facet, and the filters (on the Posts tab).

      iex> Bonfire.Search.Filters.tab_url("cats", "public", %{origin: :local, sort_by: false}, "Bonfire.Data.Social.Post")
      "/search?facet[index_type]=Bonfire.Data.Social.Post&filters[origin]=local&index=public&s=cats"
      iex> Bonfire.Search.Filters.tab_url("cats", "public", %{origin: :local})
      "/search?index=public&s=cats"
  """
  def tab_url(term, index, filters, facet \\ nil) do
    facet = type_facet(facet)

    %{"s" => term, "index" => index}
    |> put_present("facet", facet && %{"index_type" => facet})
    |> put_present("filters", if(facet == @posts_tab, do: compact(filters)))
    |> then(&("/search?" <> Plug.Conn.Query.encode(&1)))
  end

  @doc """
  Builds a `/search/tag/` URL (the hashtag tab has no filters of its own).

      iex> Bonfire.Search.Filters.hashtag_url("#cats")
      "/search/tag/cats"
  """
  def hashtag_url(tag), do: "/search/tag/#{String.trim_leading(tag || "", "#")}"

  # keeps only the search filter keys, without unset values (the editor's "Anywhere" origin is :all)
  defp compact(filters) do
    filters
    |> Map.take(@filter_keys)
    |> Map.reject(fn {_, value} -> value in [nil, [], :all, [:all]] end)
  end

  defp put_present(query, _key, empty) when empty in [nil, %{}], do: query
  defp put_present(query, key, value), do: Map.put(query, key, value)
end
