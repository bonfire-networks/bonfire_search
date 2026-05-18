defmodule Bonfire.Search.InitIndexGuardTest do
  @moduledoc """
  Regression guard: a settings *read* failure during `init_index/4` must not
  trigger an unconditional `set_facets`/`set_searchable_fields` — that would
  enqueue a `settingsUpdate` and force a full reindex of the whole corpus on
  every boot where the read hiccups.
  """
  use Bonfire.Search.DataCase, async: true

  alias Bonfire.Search.Indexer
  alias Bonfire.Search.FailingReadSearchAdapter

  test "a settings-read failure does NOT push settings (no unintended full reindex)" do
    # init_index runs synchronously in this process; the stub's set_* would
    # message us if (wrongly) called
    result = Indexer.init_index(:public, "test_init_guard", true, FailingReadSearchAdapter)

    # both branches fail-safe to nil, so no settings tasks are produced
    assert result == []

    refute_received {:set_called, :facets}
    refute_received {:set_called, :searchable}
  end
end
