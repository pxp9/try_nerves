defmodule HelloNerves.PicoServer do
  @moduledoc """
  Handles communication with Raspberry Pi Pico 2W.

  Flow:
  1. Listens on port 8080 for messages from Pico
  2. Pico can send:
     - Hello message: "HELLO:<ip>:<port>" (e.g., "HELLO:10.128.88.69:8080")
       This registers the Pico's IP and port for two-way communication
     - Regular messages: Any plain text message
  3. After hello, Nerves can send messages to Pico's echo server using send_to_pico/1
  """

  use GenServer
  require Logger

  @listen_port 8080

  defmodule State do
    @moduledoc false
    defstruct [:listen_socket, :port, :pico_ip, :pico_port]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a message to the Pico 2W echo server.
  Returns {:ok, echoed_response} or {:error, reason}
  """
  def send_to_pico(message) do
    GenServer.call(__MODULE__, {:send_to_pico, message}, 10_000)
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

    # Start the TCP server
    send(self(), :start_server)

    Logger.info("PicoServer initializing on port #{port}")
    {:ok, state}
  end

  @impl true
  def handle_info(:start_server, state) do
    case :gen_tcp.listen(state.port, [
           :binary,
           active: false,
           reuseaddr: true,
           packet: :line
         ]) do
      {:ok, listen_socket} ->
        Logger.info("PicoServer listening on port #{state.port} for Pico hello message")
        state = %{state | listen_socket: listen_socket}
        parent_pid = self()

        # Start accepting connections
        spawn_link(fn -> accept_loop(listen_socket, parent_pid) end)

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to start PicoServer: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:pico_hello, ip, port}, state) do
    Logger.info("Received Pico hello from #{inspect(ip)}:#{port}")
    new_state = %{state | pico_ip: ip, pico_port: port}
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:pico_message, content, ip}, state) do
    client_ip = :inet.ntoa(ip) |> to_string()
    Logger.info("Received message from Pico (#{client_ip}): #{content}")
    # You can add custom handling here, e.g., broadcast to Phoenix PubSub
    # Phoenix.PubSub.broadcast(HelloNerves.PubSub, "pico_messages", {:pico_message, content})
    {:noreply, state}
  end

  @impl true
  def handle_call({:send_to_pico, message}, _from, state) do
    if state.pico_ip && state.pico_port do
      result = send_tcp_message(state.pico_ip, state.pico_port, message)
      {:reply, result, state}
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
    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    :ok
  end

  # Private Functions

  defp accept_loop(listen_socket, parent_pid) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Spawn a new process to handle this client
        spawn(fn -> handle_client(client_socket, parent_pid) end)

        # Continue accepting new connections
        accept_loop(listen_socket, parent_pid)

      {:error, reason} ->
        Logger.error("Error accepting connection: #{inspect(reason)}")
        accept_loop(listen_socket, parent_pid)
    end
  end

  defp handle_client(socket, parent_pid) do
    {:ok, {ip, port}} = :inet.peername(socket)
    client_ip = :inet.ntoa(ip) |> to_string()
    Logger.info("Connection from #{client_ip}:#{port}")

    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        message = String.trim(data)
        Logger.info("Received: #{message}")

        # Parse and handle message
        case parse_message(message) do
          {:hello, pico_ip, pico_port} ->
            send(parent_pid, {:pico_hello, pico_ip, pico_port})
            Logger.info("Pico registered at #{inspect(pico_ip)}:#{pico_port}")

          {:message, content} ->
            send(parent_pid, {:pico_message, content, ip})
            Logger.info("Pico message: #{content}")

          :error ->
            Logger.warning("Invalid message format: #{message}")
        end

      {:error, reason} ->
        Logger.error("Error receiving: #{inspect(reason)}")
    end

    :gen_tcp.close(socket)
  end

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
      [{a, ""}, {b, ""}, {c, ""}, {d, ""}] when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 ->
        {:ok, {a, b, c, d}}

      _ ->
        :error
    end
  end

  defp send_tcp_message(ip, port, message) do
    Logger.info("Sending to Pico #{inspect(ip)}:#{port}: #{message}")

    case :gen_tcp.connect(ip, port, [:binary, active: false], 5000) do
      {:ok, socket} ->
        case :gen_tcp.send(socket, message) do
          :ok ->
            # Shutdown write to signal end of transmission
            :gen_tcp.shutdown(socket, :write)

            # Wait for echo response
            case :gen_tcp.recv(socket, 0, 5000) do
              {:ok, response} ->
                :gen_tcp.close(socket)
                {:ok, String.trim(response)}

              {:error, reason} ->
                :gen_tcp.close(socket)
                {:error, reason}
            end

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
