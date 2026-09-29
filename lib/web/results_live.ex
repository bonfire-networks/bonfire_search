defmodule Bonfire.Search.Web.ResultsLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop page, :any, default: nil
  prop search, :string, default: nil
  prop search_limit, :integer, default: nil
  prop search_placeholder, :string, default: nil
  prop search_more, :any, default: nil
  prop show_more_link, :boolean, default: true
  prop num_hits, :integer, default: nil
  prop hits, :list, default: []
  prop user_hits, :list, default: []
  prop page_info, :any, default: nil
  prop searching, :boolean, default: false
  prop searching_direct, :boolean, default: false
  prop selected_tab, :any, default: nil
  prop index, :string, default: "public"
  prop full_text_search, :boolean, default: true

  @doc "Explains an empty result when there is no search index, since only the federated lookup can find anything then."
  def no_results_message(false = _full_text_search),
    do:
      l(
        "Full-text search isn't available on this instance, but you can still look up a profile or post by its @username@instance or URL."
      )

  def no_results_message(_), do: ""
end
