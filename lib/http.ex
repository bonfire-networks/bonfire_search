# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.HTTP do
  import Where
  alias ActivityPub.HTTP # FIXME: use something else?

  def http_request(http_method, url, headers, object \\ nil) do
    if(http_method == :get) do
      query_str = URI.encode_query(object)
      url = url <> "?" <> query_str
      apply(HTTP, http_method, [url, headers])
    else

      json = if object && object !="" && object !=%{} && object !=:ok do
        Jason.encode!(object)
      else
        nil
      end

      # IO.inspect(json: json)
      apply(HTTP, http_method, [url, json, headers])
    end
  end

  def http_error(true, _http_method, _message, _object, _url) do
    :ok
  end

  if Mix.env() == :test do
    def http_error(_, http_method, message, _object, url) do
      debug("Search - Could not #{http_method} objects on #{url}: #{inspect message}")
      {:error, message}
    end
  end

  if Mix.env() == :dev do
    def http_error(_, http_method, message, object, url) do
      error("Search - Could not #{http_method} object on #{url}: #{inspect message}")
      debug(inspect(object))
      {:error, message}
    end
  else
    def http_error(_, http_method, message, _object, url) do
      warn("Search - Could not #{http_method} object on #{url}: #{inspect message}")
      :ok
    end
  end

end
