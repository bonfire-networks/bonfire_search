# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.HTTP do
  import Untangle
  use Bonfire.Common.Config

  def http_adapter(),
    do: Bonfire.Common.Config.get_ext!(:bonfire_search, :http_adapter)

  def http_request(http_method, url, headers, object \\ nil) do
    http_adapter = http_adapter()

    if(http_method == :get) do
      query_str = if object, do: URI.encode_query(object)
      url = "#{url}?#{query_str}"
      apply(http_adapter, http_method, adapter_args(http_adapter, [url, headers]))
    else
      json =
        if object && object != "" && object != %{} && object != :ok do
          Jason.encode!(object)
        else
          nil
        end

      # IO.inspect(json: json)
      apply(http_adapter, http_method, adapter_args(http_adapter, [url, json, headers]))
    end
  end

  # the search index is a service the admin configured, usually on a private address (e.g. `http://search:7700` in Docker), so it skips the SSRF guard
  defp adapter_args(Bonfire.Common.HTTP, args), do: args ++ [[ssrf_check: false]]
  defp adapter_args(_other_adapter, args), do: args

  def http_error(true, _http_method, _message, _object, _url) do
    :ok
  end

  case Bonfire.Common.Config.env() || Mix.env() do
    :dev ->
      def http_error(_, http_method, message, object, url) do
        error(
          object,
          "Search - Could not #{http_method} object on #{url}, got: #{inspect(message)} \n -- Sent object"
        )

        {:error, message}
      end

    :test ->
      def http_error(_, http_method, message, _object, url) do
        warn(message, "Search - Could not #{http_method} objects on #{url}")

        {:error, message}
      end

    _env ->
      # debug(env)

      def http_error(_, http_method, message, _object, url) do
        warn("Search - Could not #{http_method} object on #{url}: #{inspect(message)}")

        :ok
      end
  end
end
