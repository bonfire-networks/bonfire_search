defmodule Bonfire.Search.Web.FormLive do
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Search.Web.ResultsLive

  prop id, :string, default: "search"
  prop search, :string, default: nil
  prop search_limit, :integer, default: nil
  prop search_placeholder, :string, default: nil
  prop search_more, :any, default: nil
  prop show_more_link, :boolean, default: true
  prop num_hits, :integer, default: nil
  prop hits, :list, default: []
  prop searching, :boolean, default: false
  prop searching_direct, :boolean, default: false
end
