defmodule Bonfire.Search.Web.WidgetSearchFiltersLive do
  @moduledoc "Hosts the shared filter editor in the search sidebar; SearchLive re-sends it with the current filters on each URL change."
  use Bonfire.UI.Common.Web, :stateless_component

  prop filters, :any, default: %{}

  @doc "Assigns shared by the sidebar and mobile search filter editors."
  def editor_assigns(filters) do
    %{
      feed_filters: filters,
      context_key: :search,
      sections: Bonfire.Search.Filters.sections(),
      object_types: Bonfire.Search.Filters.object_types(),
      media_types: Bonfire.Search.Filters.media_types()
    }
  end

  @doc "How many filters are active, for the Filters button badge."
  def active_count(filters) do
    Bonfire.UI.Social.FeedControlsLive
    |> maybe_apply(:active_filters, [filters], fallback_return: [])
    |> length()
  end
end
