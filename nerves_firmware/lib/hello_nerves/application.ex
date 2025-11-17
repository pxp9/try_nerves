defmodule HelloNerves.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    setup_bot()
    setup_llm_agent()

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
      # LLM Agent for host too (for development/testing)
      {HelloNerves.LLMAgent, []},
      ExGram,
      {HelloNerves.Bot, [method: :polling, token: Application.get_env(:ex_gram, :token)]}
    ]
  end

  defp target_children(_target) do
    [
      {HelloNerves.WiFi, []},
      InterfaceWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hello_nerves, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Interface.PubSub},
      InterfaceWeb.Endpoint,
      # LLM Agent - must start before hardware tools that register with it
      {HelloNerves.LLMAgent, []},
      # %{
      #   id: HelloNerves.UartPort,
      #   start: {Circuits.UART, :start_link, [[name: HelloNerves.UartPort]]},
      #   restart: :transient
      # },
      {Circuits.UART, name: HelloNerves.UartPort},
      {HelloNerves.Uart, []},
      {HelloNerves.LCD1602, [bus: "i2c-1", address: 0x27]},
      ExGram,
      {HelloNerves.Bot, [method: :polling, token: Application.get_env(:ex_gram, :token)]}
    ]
  end

  if Mix.target() == :host do
    defp setup_bot(), do: :ok

    defp setup_llm_agent do
      # On host, try to get from environment variable
      google_api_key = System.get_env("GOOGLE_API_KEY")

      if google_api_key && google_api_key != "" do
        Application.put_env(:req_llm, :google_api_key, google_api_key)
      end
    end
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

    defp setup_llm_agent() do
      kv = Nerves.Runtime.KV.get_all()
      google_api_key = kv["google_api_key"]

      if google_api_key && google_api_key != "" do
        Application.put_env(:req_llm, :google_api_key, google_api_key)
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
