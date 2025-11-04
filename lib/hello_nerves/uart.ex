defmodule HelloNerves.Uart do
  @moduledoc """
  Module to start and manage Circuits.UART connection to ttyACM0 at 9600 baud.
  """
  use GenServer
  require Logger

  @device "ttyACM0"
  @speed 9600

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, uart_pid} = Circuits.UART.start_link()

    case Circuits.UART.open(uart_pid, @device, speed: @speed, active: false) do
      :ok ->
        Logger.info("Opened #{@device} at #{@speed} baud")
        {:ok, uart_pid}

      {:error, reason} ->
        Logger.error("Failed to open #{@device}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  def write(data) do
    GenServer.call(__MODULE__, {:write, data})
  end

  def read(timeout \\ 5000) do
    GenServer.call(__MODULE__, {:read, timeout})
  end

  @impl true
  def handle_call({:write, data}, _from, uart_pid) do
    result = Circuits.UART.write(uart_pid, data)
    {:reply, result, uart_pid}
  end

  @impl true
  def handle_call({:read, timeout}, _from, uart_pid) do
    result = Circuits.UART.read(uart_pid, timeout)
    {:reply, result, uart_pid}
  end
end
