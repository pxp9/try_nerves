defmodule AtomVmFirmwareEsp32.MixProject do
  use Mix.Project

  def project do
    [
      app: :atom_vm_firmware_esp32,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      atomvm: [
        start: AtomVmFirmwareEsp32,
        flash_offset: 0x250000,
        chip: "esp32s3",
        # baud: 115200,
        port: "/dev/ttyACM0"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exatomvm, path: "/home/pxp9/Programming/elixir/exatomvm", runtime: false},
      {:atomvm_packbeam, "~> 0.7.5", runtime: false},
      {:req, "~> 0.5.0", runtime: false},
      {:pythonx, "~> 0.4.0", runtime: false}
    ]
  end

  def aliases do
    [
      packbeam: ["cmd escript _build/dev/lib/atomvm_packbeam/ebin/packbeam.beam"]
    ]
  end
end
