defmodule HelloNerves.MixProject do
  use Mix.Project

  @app :hello_nerves
  @version "0.1.0"
  @all_targets [
    # :rpi,
    # :rpi0,
    # :rpi2,
    # :rpi3,
    # :rpi3a,
    :rpi3,
    # :rpi5,
    # :bbb,
    # :osd32mp1,
    # :grisp2,
    # :mangopi_mq_pro,
    :qemu_aarch64,
    :x86_64
  ]

  @ble_targets [:rpi0, :rpi0_2, :rpi3, :rpi3a]

  System.put_env("ERL_COMPILER_OPTIONS", "deterministic")

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      aliases: aliases(),
      preferred_cli_target: [run: :host, test: :host, precommit: :host]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {HelloNerves.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},
      {:nerves_time_zones, "~> 0.3.2"},
      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      # {:nerves_system_rpi, "~> 1.24", runtime: false, targets: :rpi},
      # {:nerves_system_rpi0, "~> 1.24", runtime: false, targets: :rpi0},
      # {:nerves_system_rpi2, "~> 1.24", runtime: false, targets: :rpi2},
      {:nerves_system_rpi3, "~> 1.24", runtime: false, targets: :rpi3},
      # {:nerves_system_rpi3a, "~> 1.24", runtime: false, targets: :rpi3a},
      # {:nerves_system_rpi4, "~> 1.24", runtime: false, targets: :rpi4},
      # {:nerves_system_rpi5, "~> 0.2", runtime: false, targets: :rpi5},
      # {:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb},
      # {:nerves_system_osd32mp1, "~> 0.15", runtime: false, targets: :osd32mp1},
      {:nerves_system_x86_64, "~> 1.24", runtime: false, targets: :x86_64},
      {:nerves_system_qemu_aarch64, "~> 0.1.1", runtime: false, targets: :qemu_aarch64},

      # {:nerves_system_grisp2, "~> 0.8", runtime: false, targets: :grisp2},
      # {:nerves_system_mangopi_mq_pro, "~> 0.6", runtime: false, targets: :mangopi_mq_pro}

      ## Common Sensors and peripherials
      {:blue_heron, "~> 0.5", targets: @ble_targets},
      {:bmp280, "~> 0.2", targets: @all_targets},
      {:circuits_gpio, "~> 2.0 or ~> 1.0"},
      {:circuits_i2c, "~> 2.0 or ~> 1.0"},
      {:circuits_spi, "~> 2.0 or ~> 1.0"},
      {:circuits_uart, "~> 1.3"},
      {:delux, "~> 0.2"},
      ## Phoenix deps
      {:phoenix, "~> 1.8.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:ex_gram, git: "https://github.com/rockneurotiko/ex_gram.git", branch: "master"},
      # {:ex_gram, "~> 0.56"},
      {:tesla, "~> 1.2"},
      {:req, "~> 0.5.0"}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://hexdocs.pm/nerves_pack/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
