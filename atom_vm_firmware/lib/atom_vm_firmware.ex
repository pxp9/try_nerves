defmodule AtomVmFirmware do
  @moduledoc """
  TCP Echo Server for AtomVM on Raspberry Pi Pico W.

  This module implements a simple TCP echo server that:
  - Connects to WiFi using configured credentials
  - Starts a TCP server on port 8080
  - Echoes back any data received from clients
  """

  @compile {:no_warn_undefined, [:network, :socket]}
  @port 8080

  @doc """
  Start the WiFi station and TCP echo server.

  Configure your WiFi credentials by editing the `ssid` and `psk` values.
  Once connected and IP is acquired, starts a TCP server on port 8080.
  """

  def setup() do
    IO.puts("Setup")

    config = [
      sta: [
        ssid: "",
        psk: "",
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
    IO.puts("Loop")
    Process.sleep(:infinity)
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
  end

  defp sntp_sync({tvsec, tvusec}) do
    IO.puts("Synchronized time with SNTP server. TVSec=#{tvsec} TVUsec=#{tvusec}\n")

    {{year, month, day}, {hour, minute, second}} = :erlang.universaltime()

    IO.puts(
      "Date: #{year}/#{month}/#{day} #{hour}:#{minute}:#{second} (#{:erlang.system_time(:millisecond)}ms)~"
    )
  end
end
