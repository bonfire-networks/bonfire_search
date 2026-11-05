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
  @doc """
  The arguments of every call to `module.fun_name` made while `fun` runs, from every process (a LiveView's included), eg. to count how many index searches or database loads a page makes. Calls between a module's own clauses are local, so this global trace sees each outside call once.
  """
  def traced_calls({module, fun_name}, fun) do
    :erlang.trace_pattern({module, fun_name, :_}, true, [])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    try do
      fun.()
    after
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({module, fun_name, :_}, false, [])
    end

    ref = :erlang.trace_delivered(:all)
    receive do: ({:trace_delivered, :all, ^ref} -> :ok)

    collect_traced_calls(module, fun_name, [])
  end

  defp collect_traced_calls(module, fun_name, acc) do
    receive do
      {:trace, _pid, :call, {^module, ^fun_name, args}} ->
        collect_traced_calls(module, fun_name, [args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "How many index searches for `term` the adapter got while `fun` ran."
  def count_index_searches(adapter, term, fun) do
    traced_calls({adapter, :search}, fun)
    |> Enum.count(&match?([^term | _], &1))
  end

  def reset_indexes_after_tests(nil, _prev_adapter), do: :ok

  def reset_indexes_after_tests(adapter, prev_adapter) do
    adapter.delete(:all, "test_public")
    adapter.delete(:all, "test_closed")

    if function_exported?(adapter, :reset_after_tests, 0), do: adapter.reset_after_tests()

    Bonfire.Common.Config.put(:adapter, prev_adapter, :bonfire_search)
    Bonfire.Common.Config.put([Bonfire.Search.Indexer, :modularity], false, :bonfire_search)
  end
end
