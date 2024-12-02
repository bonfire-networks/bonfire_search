defmodule Bonfire.Search.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  def config do
    import Config

    adapter = System.get_env("SEARCH_ADAPTER", "meili")

    config :bonfire_search,
      http_adapter:
        String.to_existing_atom(System.get_env("SEARCH_HTTP_ADAPTER", "nil")) ||
          Bonfire.Common.HTTP,
      disable_for_autocompletes: System.get_env("SEARCH_AUTOCOMPLETES_DISABLED") in ["true", "1"],
      adapter: if(adapter == "meili", do: Bonfire.Search.MeiliLib),
      # protocol, hostname and port
      instance: System.get_env("SEARCH_MEILI_INSTANCE", "http://search:7700"),
      # secret key
      api_key: System.get_env("MEILI_MASTER_KEY", "make-sure-to-change-me")

    config :bonfire_search, Bonfire.Search.Indexer,
      modularity:
        if(System.get_env("SEARCH_INDEXING_DISABLED") in ["true", "1"] or !adapter, do: :disabled)

    config :bonfire_search, Bonfire.Search.MeiliLib,
      modularity: if(adapter != "meili", do: :disabled)
  end
end
