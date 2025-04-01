defmodule Bonfire.Search.DataHelpers do
  use Arrows

  def prepare_meili_for_tests do
    adapter = Bonfire.Search.MeiliLib

    meili_adapter = Bonfire.Common.Config.get(:adapter, nil, :bonfire_search)
    tesla_adapter = Bonfire.Common.Config.get(:adapter, nil, :tesla)

    Bonfire.Common.Config.put([Bonfire.Search.Indexer, :modularity], true, :bonfire_search)
    Bonfire.Common.Config.put(:adapter, adapter, :bonfire_search)
    Bonfire.Common.Config.put(:adapter, {Tesla.Adapter.Finch, name: Bonfire.Finch}, :tesla)

    # clear the index
    adapter.delete(:all, "test_public")
    ~> adapter.wait_for_task()

    adapter.delete(:all, "test_closed") ~> adapter.wait_for_task()

    {meili_adapter, tesla_adapter}
  end

  def reset_meili_after_tests(meili_adapter, tesla_adapter) do
    Bonfire.Common.Config.put(:adapter, meili_adapter, :bonfire_search)
    Bonfire.Common.Config.put(:adapter, tesla_adapter, :tesla)
    Bonfire.Common.Config.put([Bonfire.Search.Indexer, :modularity], false, :bonfire_search)
  end
end
