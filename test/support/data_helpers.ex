defmodule Bonfire.Search.DataHelpers do
  use Bonfire.Common.Config

  @doc """
  Switches the search adapter for tests, calls its `prepare_for_tests/0` hook
  (for adapter-specific setup like Tesla config), and clears the test indexes.
  Returns the previous adapter to pass to `reset_indexes_after_tests/2`.
  """
  def prepare_indexes_for_tests(nil), do: nil

  def prepare_indexes_for_tests(adapter) do
    prev_adapter = Bonfire.Common.Config.get(:adapter, nil, :bonfire_search)

    Bonfire.Common.Config.put([Bonfire.Search.Indexer, :modularity], true, :bonfire_search)
    Bonfire.Common.Config.put(:adapter, adapter, :bonfire_search)

    if function_exported?(adapter, :prepare_for_tests, 0), do: adapter.prepare_for_tests()

    adapter.delete(:all, "test_public")
    adapter.delete(:all, "test_closed")

    prev_adapter
  end

  @doc """
  Clears test indexes, calls the adapter's `reset_after_tests/0` hook, and
  restores the previous adapter config.
  """
  def reset_indexes_after_tests(nil, _prev_adapter), do: :ok

  def reset_indexes_after_tests(adapter, prev_adapter) do
    adapter.delete(:all, "test_public")
    adapter.delete(:all, "test_closed")

    if function_exported?(adapter, :reset_after_tests, 0), do: adapter.reset_after_tests()

    Bonfire.Common.Config.put(:adapter, prev_adapter, :bonfire_search)
    Bonfire.Common.Config.put([Bonfire.Search.Indexer, :modularity], false, :bonfire_search)
  end
end
