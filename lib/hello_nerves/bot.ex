defmodule HelloNerves.Bot do
  @bot :hello_nerves

  use ExGram.Bot,
    name: @bot,
    setup_commands: true

  require Logger

  command("start")
  command("help", description: "Print the bot's help")
  command("ledon", description: "Turn on the LED")
  command("ledoff", description: "Turn off the LED")
  command("ledstatus", description: "Check LED status")

  middleware(ExGram.Middleware.IgnoreUsername)

  def bot(), do: @bot

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
    case HelloNerves.Uart.write("1") do
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
    case HelloNerves.Uart.write("0") do
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
    case HelloNerves.Uart.write("?") do
      :ok ->
        # Wait a bit for Arduino to respond
        Process.sleep(50)

        case HelloNerves.Uart.read(500) do
          {:ok, "1"} ->
            answer(context, "LED is ON")

          {:ok, "0"} ->
            answer(context, "LED is OFF")

          {:ok, data} ->
            answer(context, "Unexpected response: #{inspect(data)}")

          {:error, :not_connected} ->
            answer(context, "Error: UART not connected")

          {:error, :timeout} ->
            answer(context, "Error: No response from device")

          {:error, reason} ->
            answer(context, "Error: #{inspect(reason)}")
        end

      {:error, :not_connected} ->
        answer(context, "Error: UART not connected")

      {:error, reason} ->
        answer(context, "Error: #{inspect(reason)}")
    end
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
end
