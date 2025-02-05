import Config

# see Bonfire.Search.RuntimeConfig for env vars configured at runtime
config :bonfire_search,
  adapter: Bonfire.Search.MeiliLib,
  http_adapter: Bonfire.Common.HTTP,
  # protocol, hostname and port
  instance: System.get_env("SEARCH_MEILI_INSTANCE", "http://search:7700"),
  # secret key
  api_key: System.get_env("MEILI_MASTER_KEY", "make-sure-to-change-me")

# for use by API client
# config :tesla, :adapter, {Tesla.Adapter.Finch, name: Bonfire.Finch}
# config :tesla, adapter: Tesla.Adapter.Hackney
config :phoenix, :format_encoders, json: Jason
config :phoenix, :json_library, Jason
