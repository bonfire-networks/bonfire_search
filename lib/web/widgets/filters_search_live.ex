defmodule Bonfire.Search.UI.FiltersSearchLive do
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Search.Filters

  prop filters, :any, default: %{}
  prop search, :string, default: nil
  prop index, :string, default: "public"
  prop selected_tab, :any, default: nil

  @doc "The result-type tabs as `{url, label}` pairs for `Bonfire.UI.Common.TabsLive`."
  def tabs(term, index, filters) do
    [
      {Filters.tab_url(term, index, filters), l("All")},
      {Filters.tab_url(term, index, filters, Filters.people_tab()), l("Users")}
    ] ++
      if(module_enabled?(Bonfire.UI.Groups.Preview.GroupLive),
        do: [{Filters.tab_url(term, index, filters, Filters.groups_tab()), l("Groups")}],
        else: []
      ) ++
      [
        # was l("Posts"): the tab lists anything that isn't a user or a group
        {Filters.tab_url(term, index, filters, Filters.posts_tab()), l("Content")}
        # Disabled: the tab opened the feed of the one hashtag named like the term, which isn't a search. Matching hashtags show as chips on the All tab instead, and `/search/tag/<name>` stays
        # {Filters.hashtag_url(term), l("Hashtags")}
      ]
  end

  @doc "The URL of the active tab (TabsLive marks the tab whose key equals `selected_tab`)."
  def active_tab_url(selected_tab, term, index, filters) do
    if selected_tab == Filters.hashtag_tab(),
      do: Filters.hashtag_url(term),
      else: Filters.tab_url(term, index, filters, selected_tab)
  end
end
