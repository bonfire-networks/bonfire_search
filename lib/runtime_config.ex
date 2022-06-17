defmodule Bonfire.Search.RuntimeConfig do

  def config_module, do: true

  def config do
    import Config

    config :bonfire_search,
      disable_indexing: System.get_env("SEARCH_INDEXING_DISABLED", "false"),
      adapter: Bonfire.Search.Meili,
      instance: System.get_env("SEARCH_MEILI_INSTANCE", "http://search:7700"), # protocol, hostname and port
      api_key: System.get_env("MEILI_MASTER_KEY", "make-sure-to-change-me") # secret key

  end
end
