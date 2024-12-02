defmodule Bonfire.Search.UI.FiltersSearchLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop filters, :any, default: %{}
  prop search, :string, default: nil
  prop index, :string, default: "public"
  prop selected_tab, :any, default: nil
end
