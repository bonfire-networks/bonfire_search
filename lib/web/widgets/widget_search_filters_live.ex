defmodule Bonfire.Search.Web.WidgetSearchFiltersLive do
  @moduledoc "Hosts the shared filter editor in the search sidebar; SearchLive supplies the current filters and tab on each URL change."
  use Bonfire.UI.Common.Web, :stateless_component

  prop filters, :any, default: %{}
  # the current result-type tab (nil = All), which scopes the rows shown
  prop tab, :any, default: nil
  @doc "Assigns shared by the sidebar and mobile search filter editors."
  def editor_assigns(filters, tab) do
    %{
      feed_filters: filters,
      context_key: {:search, tab},
      sections: Bonfire.Search.Filters.sections(tab),
      object_types: [:post, :article],
      media_types: [:link, :image, :video, :audio],
      description: if(is_nil(tab), do: l("Refining by people, hashtags, content or media shows posts only."))
    }
  end
end
