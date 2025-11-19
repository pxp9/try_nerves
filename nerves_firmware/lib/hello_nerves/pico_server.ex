defmodule HelloNerves.PicoServer do
  @moduledoc """
  Handles UDP communication with Raspberry Pi Pico 2W.

  Flow:
  1. Listens on UDP port 8080 for messages from Pico
  2. Pico sends hello message: "HELLO:<ip>:<port>" (e.g., "HELLO:10.128.88.69:8080")
  3. Stores Pico's IP and port
  4. Can send UDP messages to Pico using send_to_pico/1
  """

  use GenServer
  require Logger

  @listen_port 8080

  defmodule State do
    @moduledoc false
    defstruct [:udp_socket, :port, :pico_ip, :pico_port]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a message to the Pico 2W via UDP.
  Returns :ok or {:error, reason}
  """
  def send_to_pico(message) do
    GenServer.call(__MODULE__, {:send_to_pico, message})
  end

  @doc """
  Get the stored Pico information.
  """
  def get_pico_info do
    GenServer.call(__MODULE__, :get_pico_info)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @listen_port)

    state = %State{port: port}

    # Start the UDP server
    send(self(), :start_server)

    Logger.info("PicoServer initializing on UDP port #{port}")
    {:ok, state}
  end

  @impl true
  def handle_info(:start_server, state) do
    case :gen_udp.open(state.port, [:binary, active: true]) do
      {:ok, udp_socket} ->
        Logger.info("PicoServer listening on UDP port #{state.port} for Pico messages")
        state = %{state | udp_socket: udp_socket}
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to start PicoServer: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{udp_socket: socket} = state) do
    message = String.trim(data)
    ip_tuple = :inet.ntoa(ip) |> to_string()
    Logger.info("Received UDP from #{ip_tuple}:#{port}: #{message}")

    # Parse and handle message
    case parse_message(message) do
      {:hello, pico_ip, pico_port} ->
        Logger.info("Pico registered at #{inspect(pico_ip)}:#{pico_port}")
        new_state = %{state | pico_ip: pico_ip, pico_port: pico_port}
        {:noreply, new_state}

      {:message, content} ->
        Logger.info("Pico message: #{content}")
        {:noreply, state}

      :error ->
        Logger.warning("Invalid message format: #{message}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:send_to_pico, message}, _from, state) do
    if state.pico_ip && state.pico_port && state.udp_socket do
      Logger.info("Sending UDP to Pico #{inspect(state.pico_ip)}:#{state.pico_port}: #{message}")

      case :gen_udp.send(state.udp_socket, state.pico_ip, state.pico_port, message) do
        :ok ->
          Logger.info("UDP message sent to Pico")
          {:reply, :ok, state}

        {:error, reason} = error ->
          Logger.error("Failed to send UDP: #{inspect(reason)}")
          {:reply, error, state}
      end
    else
      {:reply, {:error, :pico_not_registered}, state}
    end
  end

  @impl true
  def handle_call(:get_pico_info, _from, state) do
    info = %{
      pico_ip: state.pico_ip,
      pico_port: state.pico_port
    }

    {:reply, info, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.udp_socket do
      :gen_udp.close(state.udp_socket)
    end

    :ok
  end

  # Private Functions

  defp parse_message("HELLO:" <> rest) do
    case String.split(rest, ":") do
      [ip_str, port_str] ->
        with {:ok, ip} <- parse_ip(ip_str),
             {port, ""} <- Integer.parse(port_str) do
          {:hello, ip, port}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_message(content) do
    # Any other message is treated as a regular message
    {:message, content}
  end

  defp parse_ip(ip_str) do
    parts =
      ip_str
      |> String.split(".")
      |> Enum.map(&Integer.parse/1)

    case parts do
      [{a, ""}, {b, ""}, {c, ""}, {d, ""}]
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 ->
        {:ok, {a, b, c, d}}

      _ ->
        :error
    end
  end
end
