defmodule Bonfire.Search.ReindexModuleTest do
  @moduledoc "Discovery + dispatch of the per-extension reindex modules (`Bonfire.Common.ReindexModule`)."
  use Bonfire.Search.DataCase, async: false

  import ExUnit.CaptureLog

  test "discovers the registered reindex modules across extensions" do
    modules = Bonfire.Common.ReindexModule.modules()

    assert Bonfire.Me.Users.Reindex in modules
    assert Bonfire.Posts.Reindex in modules

    # every registered module must declare itself and be runnable
    for module <- modules do
      assert module.reindex_module() == module
      assert function_exported?(module, :reindex, 1)
    end
  end

  test "reindex_from_db runs only the given module(s)" do
    # reindex_from_db bails unless an adapter is configured (async: false test → global put is fine)
    prev = Bonfire.Common.Config.get(:adapter, nil, :bonfire_search)
    Bonfire.Common.Config.put(:adapter, Bonfire.Search.DB, :bonfire_search)
    on_exit(fn -> Bonfire.Common.Config.put(:adapter, prev, :bonfire_search) end)

    # it logs `Search reindex: running <module>` per module it runs — assert only the chosen one ran
    # async: false so it runs synchronously in-process (captured + returns :ok, vs the async default)
    log =
      capture_log([level: :info], fn ->
        assert :ok =
                 Bonfire.Search.Indexer.reindex_from_db(only: Bonfire.Posts.Reindex, async: false)
      end)

    assert log =~ "running Bonfire.Posts.Reindex"
    refute log =~ "running Bonfire.Me.Users.Reindex"
  end
end
