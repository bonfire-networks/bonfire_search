defmodule Bonfire.Search.Filters do
  @moduledoc """
  Search tab policy and casting between URL parameters and the `Bonfire.Social.FeedFilters` map.

  The fixed whitelist is separate from `FeedFilters.validate/1`: URL input must be limited to search's supported values, and feed struct defaults would introduce ordering and deduplication options into search queries.
  """
  use Bonfire.Common.Utils
  alias Bonfire.Social.FeedFilters

  # NOTE: authors filter via :subjects (plain activity.subject_id match, so replies
  # count and exclusion fails closed) — :creators carries top-level-posts-only
  # feed semantics that would silently drop replies from search results
  @uid_lists [:subjects, :exclude_subjects]
  @enum_lists %{
    object_types: [:post, :article],
    exclude_object_types: [:post, :article],
    media_types: [:link, :image, :video, :audio],
    exclude_media_types: [:link, :image, :video, :audio]
  }
  @origins [:local, :remote]

  @dimensions [
    from_people: [:subjects],
    not_people: [:exclude_subjects],
    hashtags: [:tags],
    origin: [:origin],
    object_types: [:object_types, :exclude_object_types],
    media_types: [:media_types, :exclude_media_types]
  ]
  @shared_sections [:origin]
  @post_only @dimensions |> Keyword.delete(:origin) |> Keyword.values() |> List.flatten()
  @people_tab "Bonfire.Data.Identity.User"
  @posts_tab "Bonfire.Data.Social.Post"

  @doc """
  Filter rows available on a search tab. All offers content filters too; selecting one switches to Posts.

      iex> Bonfire.Search.Filters.sections("Bonfire.Data.Identity.User")
      [:origin]
      iex> Bonfire.Search.Filters.sections("hashtag")
      []
  """
  def sections(@people_tab), do: @shared_sections
  def sections("hashtag"), do: []
  def sections(_), do: Keyword.keys(@dimensions)

  @doc "True when the filters include at least one that only applies to posts."
  def post_only?(filters) when is_map(filters), do: Enum.any?(@post_only, &Map.has_key?(filters, &1))
  def post_only?(_), do: false

  @doc """
  Keeps filters for the tab's rows. All keeps shared dimensions only; content-only selections first switch to Posts through `tab_for/2`.

      iex> Bonfire.Search.Filters.for_tab(%{origin: :local, media_types: [:image]}, "Bonfire.Data.Identity.User")
      %{origin: :local}
      iex> Bonfire.Search.Filters.for_tab(%{origin: :local}, "hashtag")
      %{}
  """
  def for_tab(filters, tab) when is_map(filters) do
    rows =
      if tab in [@posts_tab, @people_tab, "hashtag"],
        do: sections(tab),
        else: @shared_sections

    keys = Enum.flat_map(rows, &Keyword.fetch!(@dimensions, &1))
    Map.take(filters, keys)
  end

  def for_tab(_, _), do: %{}

  @doc "The tab a filter set should land on: Posts when it holds post-only filters, else the current one."
  def tab_for(filters, current_tab) do
    if post_only?(filters), do: @posts_tab, else: current_tab
  end

  @doc """
  Casts untrusted URL params (string or atom keyed) into supported search filters. Unknown keys and invalid values are dropped; empty filters yield `%{}`.
  """
  def cast_filters(params) when is_map(params) do
    %{}
    |> put_lists(@uid_lists, params, &uid_or_nil/1)
    |> put_enum_lists(params)
    |> put_list(:tags, normalise_list(get_field(params, :tags), &FeedFilters.normalise_tag/1))
    |> put_origin(get_field(params, :origin))
  end

  def cast_filters(_), do: %{}

  @doc "Converts a cast filters map back into string-keyed/valued params for URL encoding."
  def filters_to_params(filters) when is_map(filters) do
    filters
    |> Enum.flat_map(fn
      {_k, nil} -> []
      {_k, []} -> []
      {k, v} when is_list(v) -> [{to_string(k), Enum.map(v, &to_string/1)}]
      {k, v} -> [{to_string(k), to_string(v)}]
    end)
    |> Map.new()
  end

  def filters_to_params(_), do: %{}

  defp get_field(params, key), do: e(params, key, nil) || e(params, to_string(key), nil)

  defp put_lists(acc, keys, params, fun) do
    Enum.reduce(keys, acc, fn key, acc ->
      put_list(acc, key, normalise_list(get_field(params, key), fun))
    end)
  end

  defp put_enum_lists(acc, params) do
    Enum.reduce(@enum_lists, acc, fn {key, allowed}, acc ->
      put_list(acc, key, normalise_list(get_field(params, key), &cast_enum(&1, allowed)))
    end)
  end

  # a list filter is either present and non-empty, or absent
  defp put_list(acc, _key, []), do: acc
  defp put_list(acc, key, list), do: Map.put(acc, key, list)

  # wrap, normalise each entry with `fun` (nil = invalid), dedupe
  defp normalise_list(values, fun),
    do: values |> List.wrap() |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp uid_or_nil(value), do: if(Types.is_uid?(value), do: value)

  defp cast_enum(value, allowed),
    do: Enum.find(allowed, fn a -> a == value or to_string(a) == value end)

  # origin is either :local / :remote, or a list of remote instance domains
  # (both shapes are supported by the FeedFilters :origin query filter)
  defp put_origin(acc, values) when is_list(values) do
    put_list(acc, :origin, normalise_list(values, &FeedFilters.normalise_instance_domain/1))
  end

  defp put_origin(acc, value) do
    case cast_enum(value, @origins) do
      nil -> acc
      origin -> Map.put(acc, :origin, origin)
    end
  end
end
