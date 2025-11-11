defmodule HelloNerves.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    setup_bot()

    children =
      [
        # Children for all targets
        # Starts a worker by calling: HelloNerves.Worker.start_link(arg)
        # {HelloNerves.Worker, arg},
      ] ++ target_children(Nerves.Runtime.mix_target())

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HelloNerves.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  defp target_children(:host) do
    [
      InterfaceWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hello_nerves, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Interface.PubSub},
      InterfaceWeb.Endpoint,
      ExGram,
      {HelloNerves.Bot, [method: :polling, token: Application.get_env(:ex_gram, :token)]}
    ]
  end

  defp target_children(_target) do
    [
      InterfaceWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hello_nerves, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Interface.PubSub},
      InterfaceWeb.Endpoint,
      %{
        id: HelloNerves.UartPort,
        start: {Circuits.UART, :start_link, [[name: HelloNerves.UartPort]]},
        restart: :transient
      },
      # {Circuits.UART, name: HelloNerves.UartPort},
      {HelloNerves.Uart, []},
      {HelloNerves.WiFi, []},
      # I2C LCD1602 - Change address to 0x3F if 0x27 doesn't work
      {HelloNerves.LCD1602, [bus: "i2c-1", address: 0x27]},
      ExGram,
      {HelloNerves.Bot, [method: :polling, token: Application.get_env(:ex_gram, :token)]}
    ]
  end

  if Mix.target() == :host do
    defp setup_bot(), do: :ok
  else
    defp setup_bot() do
      kv = Nerves.Runtime.KV.get_all()
      token = kv["bot_token"]
      tg_owner_user = kv["tg_owner_user"]

      if token && token != "" do
        Application.put_env(:ex_gram, :token, token)
      end

      if tg_owner_user && tg_owner_user != "" do
        Application.put_env(:hello_nerves, :tg_owner_user, tg_owner_user)
      end
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    InterfaceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
