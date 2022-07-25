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

end
