defmodule Bonfire.Search.RuntimeConfig do
  def config_module, do: true

  def config do
    import Config

    config :bonfire_search,
      http_adapter:
        String.to_existing_atom(System.get_env("SEARCH_HTTP_ADAPTER", "nil")) ||
          Bonfire.Common.HTTP,
      disable_indexing: System.get_env("SEARCH_INDEXING_DISABLED", "false"),
      adapter: Bonfire.Search.Meili,
      # protocol, hostname and port
      instance: System.get_env("SEARCH_MEILI_INSTANCE", "http://search:7700"),
      # secret key
      api_key: System.get_env("MEILI_MASTER_KEY", "make-sure-to-change-me")
  end
end
