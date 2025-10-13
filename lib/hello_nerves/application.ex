defmodule HelloNerves.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    setup_wifi()

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
  defp target_children(_target) do
    [
      InterfaceWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:hello_nerves, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Interface.PubSub},
      InterfaceWeb.Endpoint
    ]
  end

  if Mix.target() == :host do
    defp setup_wifi(), do: :ok
  else
    defp setup_wifi() do
      kv = Nerves.Runtime.KV.get_all()

      if true?(kv["wifi_force"]) or not wlan0_configured?() do
        ssid = kv["wifi_ssid"]
        passphrase = kv["wifi_passphrase"]

        if not empty?(ssid) do
          _ = VintageNetWiFi.quick_configure(ssid, passphrase)
          :ok
        end
      end
    end

    defp wlan0_configured?() do
      VintageNet.get_configuration("wlan0") |> VintageNetWiFi.network_configured?()
    catch
      _, _ -> false
    end
    
    defp true?(""), do: false
    defp true?(nil), do: false
    defp true?("false"), do: false
    defp true?("FALSE"), do: false
    defp true?(_), do: true

    defp empty?(""), do: true
    defp empty?(nil), do: true
    defp empty?(_), do: false
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    InterfaceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
