defmodule Redlock.ConnectionKeeper do

  @default_port 6379
  @default_reconnection_interval_base 500
  @default_reconnection_interval_max  5_000

  require Logger

  use GenServer

  @spec connection(pid) :: {:ok, pid} | {:error, :not_found}
  def connection(pid) do
    GenServer.call(pid, :get_connection)
  end

  defstruct host: "",
            port: nil,
            redix: nil,
            auth: nil,
            reconnection_interval_base: 0,
            reconnection_interval_max:  0,
            reconnection_attempts:      0

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    send self(), :connect
    {:ok, new(opts)}
  end

  def handle_info(:connect, %{host: host, port: port, auth: auth, reconnection_attempts: attempts}=state) do
    case Redix.start_link([host: host, port: port],
                          [sync_connect: true, exit_on_disconnection: true]) do
      {:ok, pid} ->
        if FastGlobal.get(:redlock_conf).show_debug_logs do
          Logger.debug "<Redlock.ConnectionKeeper:#{host}:#{port}> connected to Redis"
        end
        auth && authenticate(pid, state)
        install_script(pid, state)

      other ->
        Logger.error "<Redlock.ConnectionKeeper:#{host}:#{port}> failed to connect, try to re-connect after interval: #{inspect other}"
        Process.send_after(self(), :connect, calc_backoff(state))
        {:noreply, %{state| redix: nil, reconnection_attempts: attempts + 1}}

    end

  end

  def handle_info({:EXIT, pid, _reason}, %{host: host, port: port, redix: pid, reconnection_attempts: attempts}=state) do
    Logger.error "<Redlock.ConnectionKeeper:#{host}:#{port}> seems to be disconnected, try to re-connect"
    Process.send_after(self(), :connect, calc_backoff(state))
    {:noreply, %{state| redix: nil, reconnection_attempts: attempts + 1}}
  end

  def handle_info(_info, state) do
    {:noreply, state}
  end

  def handle_call(:get_connection, _from, %{redix: nil}=state) do
    {:reply, {:error, :not_found}, state}
  end
  def handle_call(:get_connection, _from, %{redix: redix}=state) do
    {:reply, {:ok, redix}, state}
  end

  def terminate(_reason, _state), do: :ok

  defp new(opts) do

    host = Keyword.fetch!(opts, :host)
    port = Keyword.get(opts, :port, @default_port)
    auth = Keyword.get(opts, :auth)

    reconnection_interval_base =
      Keyword.get(opts,
                  :reconnection_interval_base,
                  @default_reconnection_interval_base)

    reconnection_interval_max  =
      Keyword.get(opts,
                  :reconnection_interval_max,
                  @default_reconnection_interval_max)

    %__MODULE__{
      host:                       host,
      port:                       port,
      auth:                       auth,
      redix:                      nil,
      reconnection_attempts:      0,
      reconnection_interval_base: reconnection_interval_base,
      reconnection_interval_max:  reconnection_interval_max
    }

  end

  defp calc_backoff(state) do
    Redlock.Util.calc_backoff(state.reconnection_interval_base,
                              state.reconnection_interval_max,
                              state.reconnection_attempts)
  end

  defp authenticate(pid, %{host: host, port: port, auth: auth}=state) do
    case Redlock.Command.authenticate(pid, auth) do
      {:ok, _val} ->
        {:noreply, %{state| redix: pid, reconnection_attempts: 0}}

      other ->
        Logger.warn "<Redlock:ConnectionKeeper:#{host}:#{port}> failed to authenticate: #{inspect other}"
        Redix.stop(pid)
        {:noreply, %{state| redix: nil}}
    end
  end

  defp install_script(pid, %{host: host, port: port}=state) do
    case Redlock.Command.install_script(pid) do

      {:ok, _val} ->
        {:noreply, %{state| redix: pid, reconnection_attempts: 0}}

      other ->
        Logger.warn "<Redlock:ConnectionKeeper:#{host}:#{port}> failed to install script: #{inspect other}"
        Redix.stop(pid)
        {:noreply, %{state| redix: nil}}
    end
  end

end
