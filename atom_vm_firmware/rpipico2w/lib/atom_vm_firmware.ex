defmodule AtomVmFirmware do
  @moduledoc """
  UDP Echo Server for AtomVM on Raspberry Pi Pico W.

  This module implements a simple UDP echo server that:
  - Connects to WiFi using configured credentials
  - Opens a UDP socket on port 8080
  - Sends hello message to Nerves device
  - Echoes back any data received from Nerves
  """

  @compile {:no_warn_undefined, [:network, :socket, GPIO]}
  @port 8080
  # Nerves device UDP server configuration
  @nerves_ip {10, 128, 88, 168}
  @nerves_port 8080
  # RGB LED GPIO pins (GP22=Red, GP21=Green, GP20=Blue)
  @pin_red 22
  @pin_green 21
  @pin_blue 20

  @doc """
  Start the WiFi station and UDP echo server.

  Configure your WiFi credentials by editing the `ssid` and `psk` values.
  Once connected and IP is acquired, starts a UDP server on port 8080.
  """

  def setup() do
    IO.puts("Setup")

    setup_rgb()
    rgb_color("blue")

    config = [
      sta: [
        ssid: "Yolo-Guest",
        psk: "FunFastFair",
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
        # Red on error
        rgb_color("red")
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

    # Show green when connected
    rgb_color("green")

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
    # IO.puts("UDP Listening on #{inspect(:socket.sockname(socket))}")

    # Start receiving loop
    spawn(fn -> udp_receive_loop(socket) end)
  end

  defp udp_receive_loop(socket) do
    IO.puts("Waiting for UDP message...")

    case :socket.recvfrom(socket) do
      {:ok, {source, data}} ->
        source_ip = Map.get(source, :addr)
        source_port = Map.get(source, :port)
        IO.puts("Received UDP from #{inspect(source_ip)}:#{source_port}: \"#{data}\"")

        # Only respond to Nerves device
        if source_ip == @nerves_ip do
          spawn(fn -> handle_udp_message(data, socket, source) end)
        end

        udp_receive_loop(socket)

      {:error, reason} ->
        IO.puts("UDP receive error: #{inspect(reason)}")
        udp_receive_loop(socket)
    end
  end

  defp handle_udp_message("#PID" <> rest, socket, source) do
    case parse_pid_and_message(rest, [], :pid) do
      {pid_str, actual_message} ->
        full_pid = "#PID#{pid_str}"
        IO.puts("PID: #{full_pid}, Message: #{inspect(actual_message)}")
        IO.puts("Message byte_size: #{byte_size(actual_message)}")
        process_message_with_pid(actual_message, full_pid, socket, source)

      :error ->
        IO.puts("Failed to parse PID message")
        :socket.sendto(socket, "ERROR:Invalid PID format", source)
    end
  end

  # Fallback for messages without PID (echo)
  defp handle_udp_message(message, socket, source) do
    IO.puts("Message without PID, echoing back")
    :socket.sendto(socket, message, source)
  end

  # Recursive parser for "#PID<0.234.0>|message"
  # Base case: empty string, parsing failed
  defp parse_pid_and_message(<<>>, _acc, _state), do: :error

  # Match the end of PID: "|"
  defp parse_pid_and_message(<<?|, rest::binary>>, acc, :pid) do
    pid_str = :erlang.list_to_binary(:lists.reverse(acc))
    {pid_str, rest}
  end

  # Consume one character at a time
  defp parse_pid_and_message(<<char, rest::binary>>, acc, :pid) do
    parse_pid_and_message(rest, [char | acc], :pid)
  end

  # Process message with PID - Color command
  defp process_message_with_pid("C:" <> color, pid_str, socket, source) do
    ## Forces the evaluation of color so rgb_color() receives a value
    IO.puts("Setting color to: #{inspect(color)}")
    rgb_color(color)
    response = "#{pid_str}|OK:#{color}"
    :socket.sendto(socket, response, source)
  end

  # Process message with PID - Echo
  defp process_message_with_pid(message, pid_str, socket, source) do
    response = "#{pid_str}|#{message}"
    :socket.sendto(socket, response, source)
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

  # RGB LED Control Functions

  @doc """
  Initialize RGB LED pins as outputs.
  Call this once during setup.
  """
  def setup_rgb() do
    GPIO.init(@pin_red)
    GPIO.init(@pin_green)
    GPIO.init(@pin_blue)

    GPIO.set_pin_mode(@pin_red, :output)
    GPIO.set_pin_mode(@pin_green, :output)
    GPIO.set_pin_mode(@pin_blue, :output)

    rgb_off()
    IO.puts("RGB LED initialized")
  end

  @doc """
  Set RGB LED color using 0-255 values for each channel.
  For now, this is binary (on/off per channel).
  Full PWM support would require more advanced control.
  """
  def set_rgb(red, green, blue) when red in 0..255 and green in 0..255 and blue in 0..255 do
    GPIO.digital_write(@pin_red, if(red > 0, do: :high, else: :low))
    GPIO.digital_write(@pin_green, if(green > 0, do: :high, else: :low))
    GPIO.digital_write(@pin_blue, if(blue > 0, do: :high, else: :low))
  end

  @doc """
  Turn off RGB LED (all colors off).
  """
  def rgb_off do
    GPIO.digital_write(@pin_red, :low)
    GPIO.digital_write(@pin_green, :low)
    GPIO.digital_write(@pin_blue, :low)
  end

  @doc """
  Set RGB to specific colors using string pattern matching.
  """
  def rgb_color("red"), do: set_rgb(255, 0, 0)
  def rgb_color("green"), do: set_rgb(0, 255, 0)
  def rgb_color("blue"), do: set_rgb(0, 0, 255)
  def rgb_color("yellow"), do: set_rgb(255, 255, 0)
  def rgb_color("cyan"), do: set_rgb(0, 255, 255)
  def rgb_color("magenta"), do: set_rgb(255, 0, 255)
  def rgb_color("white"), do: set_rgb(255, 255, 255)
  def rgb_color("off"), do: rgb_off()

  def rgb_color(unknown) do
    IO.puts("Unknown color: #{inspect(unknown)}")
    :ok
  end
end
