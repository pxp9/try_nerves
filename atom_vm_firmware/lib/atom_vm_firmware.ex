defmodule AtomVmFirmware do
  def setup() do
    IO.inspect("Hello AtomVM!")
  end

  def loop() do
    IO.inspect("LOOOL it works")
    Process.sleep(1000)
    loop()
  end

  def start do
    setup()
    loop()
    :ok
  end
end
