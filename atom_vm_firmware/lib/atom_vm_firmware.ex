defmodule AtomVmFirmware do
  @moduledoc """
  TCP Echo Server for AtomVM on Raspberry Pi Pico W.

  This module implements a simple TCP echo server that:
  - Connects to WiFi using configured credentials
  - Starts a TCP server on port 8080
  - Echoes back any data received from clients
  """

  @compile {:no_warn_undefined, [:string, :network, :socket]}
  @port 8080
  # Nerves device TCP server configuration
  @nerves_ip {0, 0, 0, 0}
  @nerves_port 8080

  @doc """
  Start the WiFi station and TCP echo server.

  Configure your WiFi credentials by editing the `ssid` and `psk` values.
  Once connected and IP is acquired, starts a TCP server on port 8080.
  """

  def setup() do
    IO.puts("Setup")

    config = [
      sta: [
        ssid: "ssid",
        psk: "psk",
        connected: &connected/0,
        got_ip: &got_ip/1,
        disconnected: &disconnected/0
      ],
      sntp: [
        host: "pool.ntp.org",
        synchronized: &sntp_sync/1
      ]
    ]

    case :network.start(config) do
      {:ok, _pid} ->
        loop()

      error ->
        IO.puts("An error occurred starting network: #{inspect(error)}")
        IO.inspect(error)
    end
  end

  def loop() do
    # IO.puts("Loop")
    Process.sleep(1000)
    loop()
  end

  def start do
    setup()
    loop()
  end

  defp connected() do
    IO.puts("Connected")
  end

  defp disconnected() do
    IO.puts("Disconnected")
  end

  defp got_ip({ip, net_mask, gtw}) do
    IO.puts("IP: #{inspect(ip)}, NetMask: #{inspect(net_mask)}, GTW: #{inspect(gtw)}")
    setup_socket(ip)
    # Send hello message to Nerves device
    send_hello_to_nerves(ip)
  end

  def setup_socket(local_ip) do
    {:ok, socket} = :socket.open(:inet, :stream, :tcp)
    IO.puts("Socket open")

    :ok = :socket.setopt(socket, {:socket, :reuseaddr}, true)
    :ok = :socket.setopt(socket, {:socket, :linger}, %{onoff: true, linger: 0})

    # Bind to specific local IP address (not :any)
    :ok = :socket.bind(socket, %{family: :inet, addr: local_ip, port: @port})
    :ok = :socket.listen(socket)
    IO.puts("Listening on #{inspect(:socket.sockname(socket))}")
    spawn(fn -> accept(socket) end)
  end

  defp accept(socket) do
    IO.puts("Waiting conn ...")

    case :socket.accept(socket) do
      {:ok, conn} ->
        case :socket.peername(conn) do
          {:ok, %{addr: peer_ip}} ->
            IO.puts("Conn local #{inspect(:socket.sockname(conn))} Peer: #{inspect(peer_ip)}")

            # Only accept connections from the Nerves device
            if peer_ip == @nerves_ip do
              IO.puts("Accepted connection from authorized Nerves device")
              spawn(fn -> handle_accept(conn) end)
            else
              IO.puts("Rejected connection from unauthorized IP: #{inspect(peer_ip)}")
              :socket.close(conn)
            end

            accept(socket)

          {:error, reason} ->
            IO.puts("Cannot get peer info: #{inspect(reason)}")
            :socket.close(conn)
            accept(socket)
        end

      {:error, reason} ->
        IO.puts("Cannot accept connection #{inspect(reason)}")
    end
  end

  defp handle_accept(conn) do
    case :socket.recv(conn) do
      {:ok, data} ->
        IO.puts("Received #{inspect(data)}")
        send_data(conn, data, 0)

      {:error, reason} ->
        IO.puts(
          "Cannot receive the data from #{inspect(:socket.peername(conn))} because #{inspect(reason)}"
        )
    end
  end

  defp send_data(conn, data, n_chunk) do
    case :socket.send(conn, data) do
      :ok ->
        IO.puts("All data sent")

      {:ok, rest} ->
        IO.puts("Sent Chunk #{n_chunk}")
        send_data(conn, rest, n_chunk + 1)

      {:error, reason} ->
        IO.puts("Cannot sent data #{inspect(reason)}")
    end
  end

  defp sntp_sync({tvsec, tvusec}) do
    IO.puts("Synchronized time with SNTP server. TVSec=#{tvsec} TVUsec=#{tvusec}\n")

    {{year, month, day}, {hour, minute, second}} = :erlang.universaltime()

    IO.puts(
      "Date: #{year}/#{month}/#{day} #{hour}:#{minute}:#{second} (#{:erlang.system_time(:millisecond)}ms)~"
    )
  end

  @doc """
  Send a message to the Nerves device via TCP.
  """
  def send_to_nerves(message) do
    IO.puts("Sending to Nerves: #{message}")

    case :socket.open(:inet, :stream, :tcp) do
      {:ok, socket} ->
        case :socket.connect(socket, %{family: :inet, addr: @nerves_ip, port: @nerves_port}) do
          :ok ->
            data = "#{message}\n"

            case :socket.send(socket, data) do
              :ok ->
                IO.puts("Message sent to Nerves successfully")
                :socket.shutdown(socket, :write)
                :socket.close(socket)
                :ok

              {:error, reason} ->
                IO.puts("Failed to send message: #{inspect(reason)}")
                :socket.close(socket)
                {:error, reason}
            end

          {:error, reason} ->
            IO.puts("Failed to connect to Nerves: #{inspect(reason)}")
            :socket.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        IO.puts("Failed to open socket: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Send hello message to the Nerves device with Pico's IP and port info.
  Message format: "HELLO:<ip>:<port>"
  """
  def send_hello_to_nerves(ip) do
    {a, b, c, d} = ip
    ip_str = "#{a}.#{b}.#{c}.#{d}"
    message = "HELLO:#{ip_str}:#{@port}"
    send_to_nerves(message)
  end
end
