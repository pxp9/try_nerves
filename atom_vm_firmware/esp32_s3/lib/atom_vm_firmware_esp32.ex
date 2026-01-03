defmodule AtomVmFirmwareEsp32 do
  @moduledoc """
  Simple Hello World for AtomVM on ESP32-S3.
  """

  def start do
    IO.puts("Hello from ESP32-S3!")
    loop()
  end

  defp loop() do
    IO.puts("ESP32-S3 is running...")
    Process.sleep(5000)
    loop()
  end
end
