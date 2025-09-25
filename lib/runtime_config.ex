defmodule Bonfire.Search.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  def config do
    import Config

    adapter = System.get_env("SEARCH_ADAPTER", "meili")

    # Determine api_key, only reading file if env var is set
    api_key =
      case {System.get_env("MEILI_MASTER_KEY"), System.get_env("MEILI_MASTER_KEY_FILE")} do
        {key, _} when is_binary(key) and key != "" -> key
        {_, file} when is_binary(file) and file != "" -> File.read!(file)
        _ -> nil
      end

    config :bonfire_search,
      http_adapter:
        String.to_existing_atom(System.get_env("SEARCH_HTTP_ADAPTER", "nil")) ||
          Bonfire.Common.HTTP,
      disable_for_autocompletes: System.get_env("SEARCH_AUTOCOMPLETES_DISABLED") in ["true", "1"],
      adapter: if(adapter == "meili" and api_key, do: Bonfire.Search.MeiliLib),
      # protocol, hostname and port
      instance: System.get_env("SEARCH_MEILI_INSTANCE", "http://search:7700"),
      # secret key
      api_key: api_key

    config :bonfire_search, Bonfire.Search.Indexer,
      modularity:
        if(
          !adapter or config_env() == :test or
            System.get_env("SEARCH_INDEXING_DISABLED") in ["true", "1"],
          do: :disabled
        )

    config :bonfire_search, Bonfire.Search.MeiliLib,
      modularity: if(adapter != "meili", do: :disabled)
  end
end
