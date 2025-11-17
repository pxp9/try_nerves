defmodule HelloNerves.Bot do
  @bot :hello_nerves

  use ExGram.Bot,
    name: @bot

  require Logger

  command("start")
  command("help", description: "Print the bot's help")
  command("ledon", description: "Turn on the LED")
  command("ledoff", description: "Turn off the LED")
  command("ledstatus", description: "Check LED status")
  command("light", description: "Read light sensor value")

  middleware(ExGram.Middleware.IgnoreUsername)

  def bot(), do: @bot

  ## Put here all the initizalization of the bot which will not require Internet
  def init(_opts) do
    :ok
  end

  def handle({:command, :start, msg}, context) do
    log_command("start", msg)
    answer(context, "Hi!")
  end

  def handle({:command, :help, msg}, context) do
    log_command("help", msg)
    answer(context, "Here is your help:")
  end

  def handle({:command, :ledon, msg}, context) do
    log_command("ledon", msg)

    case HelloNerves.Uart.led_on() do
      :ok ->
        answer(context, "LED turned ON")

      {:error, :not_connected} ->
        answer(context, "Error: UART not connected")

      {:error, reason} ->
        answer(context, "Error: #{inspect(reason)}")
    end
  end

  def handle({:command, :ledoff, msg}, context) do
    log_command("ledoff", msg)

    case HelloNerves.Uart.led_off() do
      :ok ->
        answer(context, "LED turned OFF")

      {:error, :not_connected} ->
        answer(context, "Error: UART not connected")

      {:error, reason} ->
        answer(context, "Error: #{inspect(reason)}")
    end
  end

  def handle({:command, :ledstatus, msg}, context) do
    log_command("ledstatus", msg)

    case HelloNerves.Uart.led_status() do
      {:ok, :on} ->
        answer(context, "LED is ON")

      {:ok, :off} ->
        answer(context, "LED is OFF")

      {:error, :not_connected} ->
        answer(context, "Error: UART not connected")

      {:error, reason} ->
        answer(context, "Error: #{inspect(reason)}")
    end
  end

  def handle({:command, :light, msg}, context) do
    log_command("light", msg)

    case HelloNerves.Uart.read_light_sensor() do
      {:ok, adc_value} ->
        message = format_light_value(adc_value)
        answer(context, message, parse_mode: "MarkdownV2")

      {:error, :not_connected} ->
        answer(context, "Error: UART not connected")

      {:error, reason} ->
        answer(context, "Error: #{inspect(reason)}")
    end
  end

  def handle({:info, :init}, _cnt) do
    Logger.info("Init with Internet")

    user = Application.get_env(:hello_nerves, :tg_owner_user)

    if user do
      send_ip_to_user(user)
    end

    :ok
  end

  def handle({:text, text, tg_model}, context) do
    log_command("LLM Prompt", tg_model)

    case HelloNerves.LLMAgent.prompt(text) do
      {:ok, response} ->
        answer(context, response)

      {:error, reason} ->
        answer(context, "LLM Error: #{inspect(reason)}")
    end
  end

  def handle({message_type, _tg_model} = _msg, _cnt) do
    Logger.warning("Unhandled update: #{message_type}")
  end

  def handle({message_type, _parsed, _tg_model} = _msg, _cnt) do
    Logger.warning("Unhandled update parsed: #{message_type}")
  end

  # Helper function to log user commands
  defp log_command(command, msg) do
    user = get_user_info(msg)
    Logger.info("Bot: User #{user} requested /#{command}")
  end

  defp get_user_info(%{from: %{username: username, first_name: first_name, id: id}})
       when not is_nil(username) do
    "@#{username} (#{first_name}, ID: #{id})"
  end

  defp get_user_info(%{from: %{first_name: first_name, id: id}}) do
    "#{first_name} (ID: #{id})"
  end

  defp get_user_info(%{from: %{id: id}}) do
    "User ID: #{id}"
  end

  defp get_user_info(_msg) do
    "Unknown user"
  end

  # Send IP address to a specific user
  defp send_ip_to_user(user_id) do
    ip_info = get_ip_addresses()
    message = format_ip_message(ip_info)

    case ExGram.send_message(user_id, message, parse_mode: "MarkdownV2") do
      {:ok, _} ->
        Logger.info("Bot: Sent IP address to user #{user_id}")
        :ok

      {:error, reason} ->
        Logger.error("Bot: Failed to send IP to user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Get all network interface IP addresses
  defp get_ip_addresses do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        ifaddrs
        |> Enum.map(fn {iface, opts} ->
          addrs =
            opts
            |> Enum.filter(fn
              {:addr, _} -> true
              _ -> false
            end)
            |> Enum.map(fn {:addr, addr} -> addr end)
            |> Enum.reject(&is_loopback?/1)

          {to_string(iface), addrs}
        end)
        |> Enum.reject(fn {_iface, addrs} -> Enum.empty?(addrs) end)

      {:error, _} ->
        []
    end
  end

  # Check if address is loopback
  defp is_loopback?({127, 0, 0, 1}), do: true
  defp is_loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp is_loopback?(_), do: false

  # Format IP addresses for message
  defp format_ip_message([]) do
    "*Device Network Information*\n\nNo network interfaces found."
  end

  defp format_ip_message(ip_info) do
    interfaces =
      ip_info
      |> Enum.map_join("\n\n", fn {iface, addrs} ->
        addr_list =
          addrs
          |> Enum.map_join("\n  ", &format_ip_addr/1)

        "*#{iface}*:\n  #{addr_list}"
      end)

    "*Device Network Information*\n\n#{interfaces}"
  end

  # Format IP address tuple to string
  defp format_ip_addr({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}" |> escape_markdown()
  end

  defp format_ip_addr({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]

    parts
    |> Enum.map_join(":", &Integer.to_string(&1, 16))
  end

  defp format_ip_addr(addr) do
    inspect(addr)
  end

  # Format light sensor value (0-1023 ADC) for Telegram
  defp format_light_value(adc_value) when adc_value >= 0 and adc_value <= 1023 do
    percentage = Float.round(adc_value / 1023 * 100, 1)
    voltage = Float.round(adc_value / 1023 * 5.0, 2)
    description = get_light_description(adc_value)
    icon = get_light_icon(adc_value)

    """
    #{icon} *Light Sensor Reading*

    *Level*: #{escape_markdown(description)}
    *Raw ADC*: #{adc_value} / 1023
    *Percentage*: #{escape_markdown("#{percentage}%")}
    *Voltage*: #{escape_markdown("#{voltage}V")}
    """
    |> String.trim()
  end

  # Get descriptive text for light level
  defp get_light_description(adc_value) when adc_value < 100, do: "Very Dark 🌑"
  defp get_light_description(adc_value) when adc_value < 300, do: "Dark 🌒"
  defp get_light_description(adc_value) when adc_value < 500, do: "Dim 🌓"
  defp get_light_description(adc_value) when adc_value < 700, do: "Normal 🌔"
  defp get_light_description(adc_value) when adc_value < 900, do: "Bright 🌕"
  defp get_light_description(_adc_value), do: "Very Bright ☀️"

  # Get icon for light level
  defp get_light_icon(adc_value) when adc_value < 100, do: "🌑"
  defp get_light_icon(adc_value) when adc_value < 300, do: "🌒"
  defp get_light_icon(adc_value) when adc_value < 500, do: "🌓"
  defp get_light_icon(adc_value) when adc_value < 700, do: "🌔"
  defp get_light_icon(adc_value) when adc_value < 900, do: "🌕"
  defp get_light_icon(_adc_value), do: "☀️"

  # Escape special characters for MarkdownV2
  defp escape_markdown(text) do
    text
    |> String.replace("_", "\\_")
    |> String.replace("*", "\\*")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
    |> String.replace("~", "\\~")
    |> String.replace("`", "\\`")
    |> String.replace(">", "\\>")
    |> String.replace("#", "\\#")
    |> String.replace("+", "\\+")
    |> String.replace("-", "\\-")
    |> String.replace("=", "\\=")
    |> String.replace("|", "\\|")
    |> String.replace("{", "\\{")
    |> String.replace("}", "\\}")
    |> String.replace(".", "\\.")
    |> String.replace("!", "\\!")
  end
end
