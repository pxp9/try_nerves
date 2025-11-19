defmodule AtomVmFirmware do
  @moduledoc """
  UDP Echo Server for AtomVM on Raspberry Pi Pico W.

  This module implements a simple UDP echo server that:
  - Connects to WiFi using configured credentials
  - Opens a UDP socket on port 8080
  - Sends hello message to Nerves device
  - Echoes back any data received from Nerves
  """

  @compile {:no_warn_undefined, [:string, :network, :socket]}
  @port 8080
  # Nerves device UDP server configuration
  @nerves_ip {0, 0, 0, 0}
  @nerves_port 8080

  @doc """
  Start the WiFi station and UDP echo server.

  Configure your WiFi credentials by editing the `ssid` and `psk` values.
  Once connected and IP is acquired, starts a UDP server on port 8080.
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
    {:ok, socket} = :socket.open(:inet, :dgram, :udp)
    IO.puts("UDP Socket open")

    :ok = :socket.setopt(socket, {:socket, :reuseaddr}, true)

    # Bind to specific local IP address and port
    :ok = :socket.bind(socket, %{family: :inet, addr: local_ip, port: @port})
    IO.puts("UDP Listening on #{inspect(:socket.sockname(socket))}")

    # Start receiving loop
    spawn(fn -> udp_receive_loop(socket) end)
  end

  defp udp_receive_loop(socket) do
    IO.puts("Waiting for UDP message...")

    case :socket.recvfrom(socket) do
      {:ok, {source, data}} ->
        source_ip = Map.get(source, :addr)
        source_port = Map.get(source, :port)
        IO.puts("Received UDP from #{inspect(source_ip)}:#{source_port}: #{inspect(data)}")

        # Only respond to Nerves device
        if source_ip == @nerves_ip do
          IO.puts("Echoing back to Nerves")
          :socket.sendto(socket, data, source)
          IO.puts("Echo sent")
        else
          IO.puts("Ignoring message from unauthorized IP: #{inspect(source_ip)}")
        end

        udp_receive_loop(socket)

      {:error, reason} ->
        IO.puts("UDP receive error: #{inspect(reason)}")
        udp_receive_loop(socket)
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
  Send a message to the Nerves device via UDP.
  """
  def send_to_nerves(message) do
    IO.puts("Sending UDP to Nerves: #{message}")

    case :socket.open(:inet, :dgram, :udp) do
      {:ok, socket} ->
        dest = %{family: :inet, addr: @nerves_ip, port: @nerves_port}
        data = "#{message}\n"

        case :socket.sendto(socket, data, dest) do
          :ok ->
            IO.puts("UDP message sent to Nerves successfully")
            :socket.close(socket)
            :ok

          {:error, reason} ->
            IO.puts("Failed to send UDP message: #{inspect(reason)}")
            :socket.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        IO.puts("Failed to open UDP socket: #{inspect(reason)}")
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
