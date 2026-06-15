defmodule Bonfire.Search.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  def config do
    import Config

    adapter_name = System.get_env("SEARCH_ADAPTER", "meili")

    meili_key =
      if adapter_name == "meili" do
        case {System.get_env("MEILI_MASTER_KEY"), System.get_env("MEILI_MASTER_KEY_FILE")} do
          {key, _} when is_binary(key) and key != "" -> key
          {_, file} when is_binary(file) and file != "" -> File.read!(file)
          _ -> nil
        end
      end

    adapter =
      case adapter_name do
        "meili" -> if meili_key, do: Bonfire.Search.MeiliLib
        "sonic" -> Bonfire.Search.Sonic
        _ -> nil
      end

    config :bonfire_search,
      http_adapter:
        String.to_existing_atom(System.get_env("SEARCH_HTTP_ADAPTER", "nil")) ||
          Bonfire.Common.HTTP,
      disable_for_autocompletes: System.get_env("SEARCH_AUTOCOMPLETES_DISABLED") in ["true", "1"],
      # merge a DB query into identity search results (so users appear without being reindexed);
      # disabled by default — enable with SEARCH_MERGE_DB_RESULTS=1
      merge_db_results: System.get_env("SEARCH_MERGE_DB_RESULTS") in ["true", "1"],
      adapter: adapter,
      instance: System.get_env("SEARCH_MEILI_INSTANCE", "http://search:7700"),
      api_key: meili_key

    config :bonfire_search,
      modularity: if(!adapter, do: :disabled)

    config :bonfire_search, Bonfire.Search.Indexer,
      modularity:
        if(
          !adapter or config_env() == :test or
            System.get_env("SEARCH_INDEXING_DISABLED") in ["true", "1"],
          do: :disabled
        )

    config :bonfire_search, Bonfire.Search.MeiliLib,
      modularity: if(adapter != Bonfire.Search.MeiliLib, do: :disabled)

    if adapter == Bonfire.Search.Sonic do
      config :bonfire_search, Bonfire.Search.Sonic.Connection,
        host: System.get_env("SONIC_HOST", "localhost"),
        port: System.get_env("SONIC_PORT", "1491") |> String.to_integer(),
        password:
          (case {System.get_env("SONIC_PASSWORD"), System.get_env("SONIC_PASSWORD_FILE")} do
             {key, _} when is_binary(key) and key != "" -> key
             {_, file} when is_binary(file) and file != "" -> File.read!(file)
             _ -> nil
           end)
    end
  end
end
