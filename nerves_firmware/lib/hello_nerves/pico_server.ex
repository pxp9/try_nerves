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
  Blocks waiting for response with 5 second timeout.
  Returns {:ok, response} or {:error, reason}
  """
  def send_to_pico(message, timeout \\ 5000) do
    GenServer.call(__MODULE__, {:send_to_pico, message})

    receive do
      {:pico_response, response} -> {:ok, response}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Set the RGB LED color on the Pico 2W.
  Colors: "red", "green", "blue", "yellow", "cyan", "magenta", "white", "off"
  Blocks waiting for response with 5 second timeout.
  Returns {:ok, response} or {:error, reason}
  """
  def set_color(color, timeout \\ 5000) when is_binary(color) do
    GenServer.call(__MODULE__, {:send_to_pico, "C:#{color}"})

    receive do
      {:pico_response, response} -> {:ok, response}
    after
      timeout -> {:error, :timeout}
    end
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

      {:response_with_pid, pid, response} ->
        Logger.info("Pico response for #{inspect(pid)}: #{response}")
        # Send message to the reconstructed PID
        send(pid, {:pico_response, response})
        {:noreply, state}

      {:message, content} ->
        Logger.info("Pico message: #{content}")
        {:noreply, state}

      :error ->
        Logger.warning("Invalid message format: #{message}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:send_to_pico, message}, {from_pid, _ref}, state) do
    if state.pico_ip && state.pico_port && state.udp_socket do
      # Format message with PID: #PID<0.234.0>|message
      pid_str = inspect(from_pid)
      full_message = "#{pid_str}|#{message}"
      Logger.info("Sending UDP to Pico #{inspect(state.pico_ip)}:#{state.pico_port}: #{full_message}")

      case :gen_udp.send(state.udp_socket, state.pico_ip, state.pico_port, full_message) do
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

  # Parse response with PID: "#PID<0.234.0>|response"
  defp parse_message("#PID" <> rest) do
    case parse_pid_and_message(rest, [], :pid) do
      {pid_str, response} ->
        case parse_and_reconstruct_pid(pid_str) do
          {:ok, pid} -> {:response_with_pid, pid, response}
          :error -> {:message, "#PID" <> rest}
        end

      :error ->
        {:message, "#PID" <> rest}
    end
  end

  defp parse_message(content) do
    # Any other message is treated as a regular message
    {:message, content}
  end

  # Recursive parser for "#PID<0.234.0>|message"
  # Base case: empty string, parsing failed
  defp parse_pid_and_message(<<>>, _acc, _state), do: :error

  # Match the end of PID: ">|"
  defp parse_pid_and_message(<<?|, rest::binary>>, acc, :pid) do
    pid_str = acc |> Enum.reverse() |> List.to_string()
    {pid_str, rest}
  end

  # Consume one character at a time
  defp parse_pid_and_message(<<char, rest::binary>>, acc, :pid) do
    parse_pid_and_message(rest, [char | acc], :pid)
  end

  # Parse PID string "0.234.0" and reconstruct actual PID using :erlang.list_to_pid/1
  defp parse_and_reconstruct_pid(pid_str) do
    # Convert to charlist format for :erlang.list_to_pid: '<0.234.0>'
    charlist = String.to_charlist(pid_str)
    pid = :erlang.list_to_pid(charlist)
    {:ok, pid}
  rescue
    _ -> :error
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
