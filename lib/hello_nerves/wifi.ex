defmodule HelloNerves.WiFi do
  use GenServer
  require Logger

  @interface "wlan0"
  @reconnect_interval 5_000
  @scan_retry_interval 2_000

  # Client API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Server Callbacks
  @impl true
  def init(_opts) do
    kv = Nerves.Runtime.KV.get_all()

    # Subscribe to VintageNet connection status changes
    VintageNet.subscribe(["interface", @interface, "connection"])
    VintageNet.subscribe(["interface", @interface, "state"])

    state = %{
      ssid_list: parse_ssids(kv["wifi_ssid"]),
      passphrase_list: parse_passphrases(kv["wifi_passphrase"]),
      force: parse_force(kv["wifi_force"]),
      connected: false,
      current_ssid: nil,
      connection_status: :disconnected
    }

    # Try to connect after a short delay to let VintageNet initialize
    Process.send_after(self(), :try_connect, 1000)

    {:ok, state}
  end

  @impl true
  def handle_info(:try_connect, state) do
    if state.force or not wlan0_configured?() do
      Logger.info("WiFi: Attempting to connect...")
      attempt_connection(state)
    else
      Logger.info("WiFi: Already configured, skipping")
      {:noreply, %{state | connected: true}}
    end
  end

  def handle_info(:retry_scan, state) do
    attempt_connection(state)
  end

  # Handle VintageNet property change events
  def handle_info(
        {VintageNet, ["interface", @interface, "connection"], _old_value, new_value, _meta},
        state
      ) do
    Logger.info("WiFi: Connection status changed to #{inspect(new_value)}")

    case new_value do
      :internet ->
        Logger.info("WiFi: Internet connection established")
        {:noreply, %{state | connection_status: :internet}}

      :lan ->
        Logger.info("WiFi: LAN connection established (no internet)")
        {:noreply, %{state | connection_status: :lan}}

      :disconnected ->
        Logger.warning("WiFi: Disconnected, attempting reconnection")
        Process.send_after(self(), :retry_scan, @reconnect_interval)
        {:noreply, %{state | connection_status: :disconnected, connected: false}}

      _ ->
        {:noreply, %{state | connection_status: new_value}}
    end
  end

  def handle_info(
        {VintageNet, ["interface", @interface, "state"], _old_value, new_value, _meta},
        state
      ) do
    Logger.info("WiFi: Interface state changed to #{inspect(new_value)}")

    case new_value do
      :configured ->
        {:noreply, state}

      :unconfigured ->
        Logger.warning("WiFi: Interface unconfigured, attempting reconnection")
        Process.send_after(self(), :retry_scan, @reconnect_interval)
        {:noreply, %{state | connected: false}}

      _ ->
        {:noreply, state}
    end
  end

  # Catch-all for other VintageNet messages
  def handle_info({VintageNet, _property, _old, _new, _meta}, state) do
    {:noreply, state}
  end

  # Private Functions
  defp attempt_connection(state) do
    if Enum.empty?(state.ssid_list) do
      Logger.warning("WiFi: No SSIDs configured")
      {:noreply, state}
    else
      case scan_for_networks() do
        {:ok, available_aps} ->
          Logger.info("WiFi: Found #{length(available_aps)} networks")
          connect_to_available_network(available_aps, state)

        {:error, reason} ->
          Logger.warning(
            "WiFi: Scan failed: #{inspect(reason)}, retrying in #{@scan_retry_interval}ms"
          )

          Process.send_after(self(), :retry_scan, @scan_retry_interval)
          {:noreply, state}
      end
    end
  end

  defp scan_for_networks do
    case VintageNetWiFi.ioctl(@interface, :scan, []) do
      :ok ->
        Process.sleep(2000)

        aps =
          VintageNet.get(["interface", @interface, "wifi", "access_points"])
          |> VintageNetWiFi.summarize_access_points()

        {:ok, aps}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason ->
      {:error, reason}
  end

  defp connect_to_available_network(available_aps, state) do
    case Enum.find(available_aps, fn ap -> ap.ssid in state.ssid_list end) do
      nil ->
        Logger.warning(
          "WiFi: No matching networks found. Available: #{inspect(Enum.map(available_aps, & &1.ssid))}"
        )

        Process.send_after(self(), :retry_scan, @reconnect_interval)
        {:noreply, state}

      found_ap ->
        ssid_index = Enum.find_index(state.ssid_list, fn ssid -> ssid == found_ap.ssid end)
        passphrase = Enum.at(state.passphrase_list, ssid_index)

        Logger.info("WiFi: Connecting to #{found_ap.ssid}")

        case VintageNetWiFi.quick_configure(found_ap.ssid, passphrase) do
          :ok ->
            {:noreply, %{state | connected: true, current_ssid: found_ap.ssid}}

          {:error, reason} ->
            Logger.error("WiFi: Failed to configure: #{inspect(reason)}")
            Process.send_after(self(), :retry_scan, @reconnect_interval)
            {:noreply, state}
        end
    end
  end

  defp wlan0_configured? do
    VintageNet.get_configuration(@interface) |> VintageNetWiFi.network_configured?()
  catch
    _, _ -> false
  end

  defp parse_ssids(nil), do: []
  defp parse_ssids(""), do: []

  defp parse_ssids(str) do
    String.split(str, ",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp parse_passphrases(nil), do: []
  defp parse_passphrases(""), do: []

  defp parse_passphrases(str) do
    String.split(str, ",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp parse_force(nil), do: false
  defp parse_force(""), do: false
  defp parse_force("false"), do: false
  defp parse_force("FALSE"), do: false
  defp parse_force(_), do: true
end
