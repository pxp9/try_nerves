defmodule HelloNerves.Bot do
  @bot :hello_nerves

  use ExGram.Bot,
    name: @bot,
    setup_commands: true

  command("start")
  command("help", description: "Print the bot's help")
  command("ledon", description: "Turn on the LED")
  command("ledoff", description: "Turn off the LED")
  command("ledstatus", description: "Check LED status")

  middleware(ExGram.Middleware.IgnoreUsername)

  def bot(), do: @bot

  def handle({:command, :start, _msg}, context) do
    answer(context, "Hi!")
  end

  def handle({:command, :help, _msg}, context) do
    answer(context, "Here is your help:")
  end

  def handle({:command, :ledon, _msg}, context) do
    case HelloNerves.Uart.write("1") do
      :ok ->
        answer(context, "LED turned ON")

      {:error, :not_connected} ->
        answer(context, "Error: UART not connected")

      {:error, reason} ->
        answer(context, "Error: #{inspect(reason)}")
    end
  end

  def handle({:command, :ledoff, _msg}, context) do
    case HelloNerves.Uart.write("0") do
      :ok ->
        answer(context, "LED turned OFF")

      {:error, :not_connected} ->
        answer(context, "Error: UART not connected")

      {:error, reason} ->
        answer(context, "Error: #{inspect(reason)}")
    end
  end

  def handle({:command, :ledstatus, _msg}, context) do
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
end
