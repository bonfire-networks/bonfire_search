defmodule Bonfire.Search.FailingReadSearchAdapter do
  @moduledoc """
  Test stub: a search adapter whose settings *reads* fail.

  Used to prove `Bonfire.Search.Indexer.init_index/4` does not push settings
  (which would force a full reindex) when it can't read the current settings.
  Every `set_*` call notifies the calling process so tests can assert it was
  NOT invoked.
  """

  def create_index(_index_name, _fail_silently), do: :ok

  def list_facets(_index_name), do: {:error, :simulated_read_failure}
  def list_searchable_fields(_index_name), do: {:error, :simulated_read_failure}

  def set_facets(_index_name, _facets) do
    send(self(), {:set_called, :facets})
    {:ok, :should_not_have_been_called}
  end

  def set_searchable_fields(_index_name, _fields) do
    send(self(), {:set_called, :searchable})
    {:ok, :should_not_have_been_called}
  end
end
