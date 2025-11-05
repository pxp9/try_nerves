defmodule HelloNerves.Bot do
  @bot :hello_nerves

  use ExGram.Bot,
    name: @bot,
    setup_commands: true

  command("start")
  command("help", description: "Print the bot's help")
  command("ledon", description: "Turn on the LED")
  command("ledoff", description: "Turn off the LED")

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
end
