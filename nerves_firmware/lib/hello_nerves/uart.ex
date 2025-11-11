defmodule HelloNerves.Uart do
  use GenServer
  require Logger

  @uart_name HelloNerves.UartPort
  @device_regex ~r"^ttyACM\d$"
  @speed 9600
  @reconnect_interval 150

  # Client API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def write(data) do
    GenServer.call(__MODULE__, {:write, data})
  end

  def read(timeout \\ 5000) do
    GenServer.call(__MODULE__, {:read, timeout})
  end

  # Server Callbacks
  @impl true
  def init(_opts) do
    state = %{
      device: nil,
      connected: false,
      rx_buffer: ""
    }

    # Try to connect immediately
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call({:write, _data}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:write, data}, _from, state) do
    case Circuits.UART.write(@uart_name, data) do
      :ok ->
        {:reply, :ok, state}

      {:error, :ebadf} ->
        Logger.warning("UART: Write failed (bad file descriptor), attempting reconnection")
        Circuits.UART.close(@uart_name)
        send(self(), :connect)
        {:reply, {:error, :not_connected}, %{state | connected: false, device: nil}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:read, _timeout}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:read, _timeout}, _from, %{rx_buffer: buffer} = state) when buffer != "" do
    # Return buffered data immediately
    {:reply, {:ok, buffer}, %{state | rx_buffer: ""}}
  end

  def handle_call({:read, timeout}, _from, state) do
    case Circuits.UART.read(@uart_name, timeout) do
      {:ok, data} ->
        {:reply, {:ok, data}, state}

      {:error, :ebadf} ->
        Logger.warning("UART: Read failed (bad file descriptor), attempting reconnection")
        Circuits.UART.close(@uart_name)
        send(self(), :connect)
        {:reply, {:error, :not_connected}, %{state | connected: false, device: nil}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case find_and_open_device() do
      {:ok, device} ->
        Logger.info("UART connected to #{device}")
        {:noreply, %{state | device: device, connected: true}}

      {:error, reason} ->
        Logger.warning(
          "UART connection failed: #{inspect(reason)}, retrying in #{@reconnect_interval}ms"
        )

        Process.send_after(self(), :connect, @reconnect_interval)
        {:noreply, %{state | connected: false}}
    end
  end

  # Handle UART errors (like cable disconnect) - only with active: true
  def handle_info({:circuits_uart, device_path, {:error, reason}}, state)
      when is_binary(device_path) do
    Logger.warning("UART error on #{device_path}: #{inspect(reason)}, attempting reconnection")

    Circuits.UART.close(@uart_name)

    Process.send_after(self(), :connect, @reconnect_interval)
    {:noreply, %{state | device: nil, connected: false}}
  end

  # Handle data received from UART - buffer it for later reading
  def handle_info({:circuits_uart, device_path, data}, state) when is_binary(device_path) do
    Logger.debug("UART received from #{device_path}: #{inspect(data)}")
    {:noreply, %{state | rx_buffer: state.rx_buffer <> data}}
  end

  def stop(pid) do
    GenServer.stop(pid)
    GenServer.stop(@uart_name)
  end

  # Private Functions
  defp find_and_open_device do
    case find_device() do
      nil ->
        {:error, :no_device_found}

      device ->
        case Circuits.UART.open(@uart_name, "/dev/#{device}", speed: @speed, active: true) do
          :ok -> {:ok, device}
          error -> {:error, error}
        end
    end
  end

  defp find_device do
    Circuits.UART.enumerate()
    |> Map.keys()
    |> Enum.find(&String.match?(&1, @device_regex))
  end
end
