defmodule Bonfire.UI.Coordination.FiltersSearchLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop filters, :any, default: %{}
  prop search, :string, default: ""
  prop selected_tab, :string, default: "All"
end
