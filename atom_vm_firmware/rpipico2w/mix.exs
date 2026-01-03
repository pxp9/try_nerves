defmodule AtomVmFirmware.MixProject do
  use Mix.Project

  def project do
    [
      app: :atom_vm_firmware,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      atomvm: [
        start: AtomVmFirmware,
        pico_path: "/run/media/pxp9/RP2350",
        pico_reset: "/dev/ttyACM*",
        # family_id: :rp2350_arm_s,
        family_id: :rp2350_riscv,
        app_start: "0x101B0000"
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
      {:exatomvm, git: "https://github.com/pxp9/ExAtomVM/", runtime: false},
      {:atomvm_packbeam, "~> 0.7.5", runtime: false},
      {:req, "~> 0.5.0", runtime: false}
    ]
  end

  def aliases do
    [
      packbeam: ["cmd escript _build/dev/lib/atomvm_packbeam/ebin/packbeam.beam"]
    ]
  end
end
