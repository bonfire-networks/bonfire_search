# SPDX-License-Identifier: AGPL-3.0-only

defmodule Bonfire.Search.Sonic.Connection do
  @moduledoc """
  Wraps a Sonix TCP connection with automatic `START <mode>` re-handshake.

  `Sonix.Tcp` (via the `Connection` behaviour) already handles TCP-level
  reconnection. However it does not re-issue the `START <mode> <password>`
  Sonic Channel handshake after reconnecting. This GenServer holds the conn
  PID and re-starts the channel whenever the underlying TCP reconnects.

  Use via `Bonfire.Search.Sonic.ConnectionPool`.
  """

  use GenServer
  import Untangle
  use Bonfire.Common.Config

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns `{:ok, conn_pid}` or `{:error, reason}`."
  def get(name) do
    GenServer.call(name, :get)
  rescue
    e -> {:error, e}
  end

  def ingest, do: get(__MODULE__.Ingest)
  def search, do: get(__MODULE__.Search)

  @impl GenServer
  def init(opts) do
    mode = Keyword.fetch!(opts, :mode)
    {:ok, %{conn: nil, mode: mode}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    case open(state.mode) do
      {:ok, conn} ->
        {:noreply, %{state | conn: conn}}

      {:error, reason} ->
        warn(reason, "Sonic #{state.mode} connection failed, retrying in 5s")
        Process.send_after(self(), :reconnect, 5_000)
        {:noreply, %{state | conn: nil}}
    end
  end

  @impl GenServer
  def handle_call(:get, _from, %{conn: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:get, _from, state) do
    # TODO: This protects callers from Sonix returning Sonic's fresh TCP greeting
    # after an internal reconnect, but it adds one PING round trip per checkout.
    # If this becomes hot, cache the health check briefly or retry only after a
    # command returns the known stale-channel protocol responses.
    if connected?(state.conn) do
      {:reply, {:ok, state.conn}, state}
    else
      close(state.conn)

      case open(state.mode) do
        {:ok, conn} ->
          {:reply, {:ok, conn}, %{state | conn: conn}}

        {:error, reason} ->
          warn(reason, "Sonic #{state.mode} reconnect failed")
          {:reply, {:error, :not_connected}, %{state | conn: nil}}
      end
    end
  end

  @impl GenServer
  def handle_info(:reconnect, %{conn: nil} = state) do
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

  defp connected?(conn) when is_pid(conn) do
    Sonix.ping(conn) == :ok
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp connected?(_), do: false

  defp close(conn) when is_pid(conn) do
    Sonix.quit(conn)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp close(_), do: :ok

  # Opens a TCP connection via Sonix and issues the START handshake.
  # Sonix.Tcp handles TCP-level reconnection automatically; we only need
  # to re-issue START after the initial connect (or after a crash of this GenServer).
  defp open(mode) do
    host = Config.get_ext(:bonfire_search, [__MODULE__, :host], "localhost")
    port = Config.get_ext(:bonfire_search, [__MODULE__, :port], 1491)
    password = Config.get_ext(:bonfire_search, [__MODULE__, :password], "SecretPassword")

    with {:ok, conn} <- Sonix.init(host, port),
         {:ok, _} <- Sonix.start(conn, mode, password) do
      {:ok, conn}
    end
  end
end
