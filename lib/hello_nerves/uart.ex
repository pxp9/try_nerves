defmodule HelloNerves.Uart do
  @moduledoc """
  Module to start and manage Circuits.UART connection to ttyACM0 at 9600 baud.
  """
  require Logger

  @device_regex ~r"^ttyACM\d$"
  @speed 9600

  def open() do
    device =
      File.ls!("/dev")
      |> Enum.find(&String.match?(&1, @device_regex))

    if device do
      Circuits.UART.open(__MODULE__, "/dev/#{device}", speed: @speed, active: false)
    else
      {:error, :enoent}
    end
  end

  def write(data) do
    ensure_open(fn -> Circuits.UART.write(__MODULE__, data) end)
  end

  defp ensure_open(operation) do
    case operation.() do
      {:error, :ebadf} ->
        Logger.info("Reopening")

        case open() do
          :ok ->
            Process.sleep(300)
            operation.()

          error ->
            error
        end

      result ->
        result
    end
  end

  def read(timeout) do
    ensure_open(fn -> Circuits.UART.read(__MODULE__, timeout) end)
  end
end
