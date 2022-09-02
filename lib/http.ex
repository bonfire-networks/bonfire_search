# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.HTTP do
  import Untangle

  def http_adapter(), do: Bonfire.Common.Config.get_ext!(:bonfire_search, :http_adapter)

  def http_request(http_method, url, headers, object \\ nil) do
    http_adapter = http_adapter()

    if(http_method == :get) do
      query_str = URI.encode_query(object)
      url = url <> "?" <> query_str
      apply(http_adapter, http_method, [url, headers])
    else

      json = if object && object !="" && object !=%{} && object !=:ok do
        Jason.encode!(object)
      else
        nil
      end

      # IO.inspect(json: json)
      apply(http_adapter, http_method, [url, json, headers])
    end
  end

  def http_error(true, _http_method, _message, _object, _url) do
    :ok
  end

  case Bonfire.Common.Config.get(:env) || Mix.env() do
    :dev ->
      def http_error(_, http_method, message, object, url) do
        error(object, "Search - Could not #{http_method} object on #{url}, got: #{inspect message} \n -- Sent object")
        {:error, message}
      end

    :test ->
      def http_error(_, http_method, message, _object, url) do
        debug("Search - Could not #{http_method} objects on #{url}: #{inspect message}")
        {:error, message}
      end

    env ->
      # debug(env)

      def http_error(_, http_method, message, _object, url) do
        warn("Search - Could not #{http_method} object on #{url}: #{inspect message}")
        :ok
      end
  end

end
