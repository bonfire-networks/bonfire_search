defmodule Bonfire.Search.Web.ResultsLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop hits, :list
  prop search_more, :any
  
end
