defmodule Bonfire.Search.Web.FormLive do
  use Bonfire.UI.Common.Web, :stateless_component

  alias Bonfire.Search.Web.ResultsLive
  prop search_limit, :integer

end
