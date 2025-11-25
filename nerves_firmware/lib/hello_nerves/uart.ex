defmodule HelloNerves.Uart do
  use GenServer
  require Logger

  @uart_name HelloNerves.UartPort
  @device_regex ~r"^ttyACM\d$"
  @speed 9600
  @reconnect_interval 150

  # Client API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def write(data) do
    GenServer.call(__MODULE__, {:write, data})
  end

  def read(timeout \\ 5000) do
    GenServer.call(__MODULE__, {:read, timeout})
  end

  @doc """
  Turn LED on (sends "1" to Arduino).
  """
  def led_on do
    GenServer.call(__MODULE__, :led_on)
  end

  @doc """
  Turn LED off (sends "0" to Arduino).
  """
  def led_off do
    GenServer.call(__MODULE__, :led_off)
  end

  @doc """
  Get LED status (sends "?" to Arduino).
  Returns {:ok, :on}, {:ok, :off}, or {:error, reason}
  """
  def led_status do
    GenServer.call(__MODULE__, :led_status)
  end

  @doc """
  Read light sensor value (sends "L" to Arduino).
  Returns {:ok, adc_value} or {:error, reason}
  """
  def read_light_sensor do
    GenServer.call(__MODULE__, :read_light_sensor)
  end

  @doc """
  Blink LED with configurable parameters (sends "B<count>,<duration_ms>,<interval_ms>\\n" to Arduino).
  Returns :ok or {:error, reason}
  """
  def blink_led(count, duration_ms, interval_ms) do
    GenServer.call(__MODULE__, {:blink_led, count, duration_ms, interval_ms})
  end

  ## Tool Functions for LLM Agent

  @doc """
  Control LED (called by LLM Agent).
  """
  def tool_led_control(args) when is_map(args) do
    state = Map.get(args, :state) || Map.get(args, "state", "on")
    Logger.info("UART LED Tool: Setting LED to '#{state}'")

    case state do
      "on" ->
        case led_on() do
          :ok -> {:ok, "LED turned on"}
          {:error, reason} -> {:error, "Failed to turn LED on: #{inspect(reason)}"}
        end

      "off" ->
        case led_off() do
          :ok -> {:ok, "LED turned off"}
          {:error, reason} -> {:error, "Failed to turn LED off: #{inspect(reason)}"}
        end

      _ ->
        {:error, "Invalid state. Use 'on' or 'off'"}
    end
  end

  @doc """
  Get LED status (called by LLM Agent).
  """
  def tool_led_status(_args) do
    Logger.info("UART LED Tool: Getting LED status")

    case led_status() do
      {:ok, :on} -> {:ok, "LED is currently ON"}
      {:ok, :off} -> {:ok, "LED is currently OFF"}
      {:error, reason} -> {:error, "Failed to get LED status: #{inspect(reason)}"}
    end
  end

  @doc """
  Read light sensor (called by LLM Agent).
  """
  def tool_read_light(args) when is_map(args) do
    format = Map.get(args, :format) || Map.get(args, "format", "detailed")
    Logger.info("UART Light Sensor Tool: Reading light sensor")

    case read_light_sensor() do
      {:ok, adc_value} ->
        if format == "raw" do
          {:ok, "Light sensor ADC value: #{adc_value}"}
        else
          percentage = Float.round(adc_value / 1023 * 100, 1)
          voltage = Float.round(adc_value / 1023 * 5.0, 2)
          description = get_light_description(adc_value)

          {:ok,
           "Light Level: #{description}\nRaw ADC: #{adc_value}/1023\nPercentage: #{percentage}%\nVoltage: #{voltage}V"}
        end

      {:error, reason} ->
        {:error, "Failed to read light sensor: #{inspect(reason)}"}
    end
  end

  @doc """
  Blink LED with configurable duration (called by LLM Agent).
  """
  def tool_led_blink(args) when is_map(args) do
    duration_ms = Map.get(args, :duration_ms) || Map.get(args, "duration_ms", 1000)
    count = Map.get(args, :count) || Map.get(args, "count", 1)
    interval_ms = Map.get(args, :interval_ms) || Map.get(args, "interval_ms", 500)

    Logger.info(
      "UART LED Tool: Blinking LED #{count} times, duration=#{duration_ms}ms, interval=#{interval_ms}ms"
    )

    case blink_led(count, duration_ms, interval_ms) do
      :ok -> {:ok, "LED blinked #{count} times (#{duration_ms}ms on, #{interval_ms}ms off)"}
      {:error, reason} -> {:error, "Failed to blink LED: #{inspect(reason)}"}
    end
  end

  # Server Callbacks
  @impl true
  def init(_opts) do
    state = %{
      device: nil,
      connected: false
    }

    # Try to connect immediately
    send(self(), :connect)

    {:ok, state}
  end

  @impl true
  def handle_call({:write, _data}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:write, data}, _from, state) do
    case Circuits.UART.write(@uart_name, data) do
      :ok ->
        {:reply, :ok, state}

      {:error, :ebadf} ->
        Logger.warning("UART: Write failed (bad file descriptor), attempting reconnection")
        Circuits.UART.close(@uart_name)
        send(self(), :connect)
        {:reply, {:error, :not_connected}, %{state | connected: false, device: nil}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:read, _timeout}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:read, timeout}, _from, state) do
    case Circuits.UART.read(@uart_name, timeout) do
      {:ok, data} ->
        {:reply, {:ok, data}, state}

      {:error, :ebadf} ->
        Logger.warning("UART: Read failed (bad file descriptor), attempting reconnection")
        Circuits.UART.close(@uart_name)
        send(self(), :connect)
        {:reply, {:error, :not_connected}, %{state | connected: false, device: nil}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:led_on, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:led_on, _from, state) do
    case Circuits.UART.write(@uart_name, "1") do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:led_off, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:led_off, _from, state) do
    case Circuits.UART.write(@uart_name, "0") do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:led_status, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:led_status, _from, state) do
    with :ok <- Circuits.UART.write(@uart_name, "?") do
      Process.sleep(50)

      case Circuits.UART.read(@uart_name, 500) do
        {:ok, response} ->
          case String.trim(response) do
            "1" -> {:reply, {:ok, :on}, state}
            "0" -> {:reply, {:ok, :off}, state}
            _ -> {:reply, {:error, :unexpected_response}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:read_light_sensor, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:read_light_sensor, _from, state) do
    with :ok <- Circuits.UART.write(@uart_name, "L") do
      Process.sleep(50)

      case Circuits.UART.read(@uart_name, 500) do
        {:ok, response} ->
          case Integer.parse(String.trim(response)) do
            {adc_value, _} when adc_value >= 0 and adc_value <= 1023 ->
              {:reply, {:ok, adc_value}, state}

            _ ->
              {:reply, {:error, :invalid_reading}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:blink_led, _count, _duration_ms, _interval_ms}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:blink_led, count, duration_ms, interval_ms}, _from, state) do
    # Format: B<count>,<duration_ms>,<interval_ms>\n
    command = "B#{count},#{duration_ms},#{interval_ms}\n"

    case Circuits.UART.write(@uart_name, command) do
      :ok -> {:reply, :ok, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:connect, state) do
    case find_and_open_device() do
      {:ok, device} ->
        Logger.info("UART connected to #{device}")

        # Register tools with LLM Agent when connected
        register_with_agent()

        # Start health check
        Process.send_after(self(), :uart_health_check, 5000)

        {:noreply, %{state | device: device, connected: true}}

      {:error, reason} ->
        Logger.warning(
          "UART connection failed: #{inspect(reason)}, retrying in #{@reconnect_interval}ms"
        )

        Process.send_after(self(), :connect, @reconnect_interval)
        {:noreply, %{state | connected: false}}
    end
  end

  # Periodic health check for UART connection
  def handle_info(:uart_health_check, state) do
    if state.connected do
      # Try a simple write to check if connection is alive
      case Circuits.UART.write(@uart_name, "") do
        :ok ->
          # Connection is good, schedule next check
          Process.send_after(self(), :uart_health_check, 5000)
          {:noreply, state}

        {:error, _reason} ->
          # Connection lost, attempt reconnection
          Logger.warning("UART: Connection lost, attempting reconnection")
          Circuits.UART.close(@uart_name)
          Process.send_after(self(), :connect, @reconnect_interval)
          {:noreply, %{state | device: nil, connected: false}}
      end
    else
      {:noreply, state}
    end
  end

  def stop(pid) do
    GenServer.stop(pid)
    GenServer.stop(@uart_name)
  end

  # Private Functions
  defp find_and_open_device do
    case find_device() do
      nil ->
        {:error, :no_device_found}

      device ->
        case Circuits.UART.open(@uart_name, "/dev/#{device}", speed: @speed, active: false) do
          :ok -> {:ok, device}
          error -> {:error, error}
        end
    end
  end

  defp find_device do
    Circuits.UART.enumerate()
    |> Map.keys()
    |> Enum.find(&String.match?(&1, @device_regex))
  end

  # Register this module's tools with the LLM Agent
  defp register_with_agent do
    # Register LED control tool
    HelloNerves.LLMAgent.register_tool(
      "led_control",
      "Control the GREEN LED connected to the Arduino via UART. This is a single-color green LED that can only be turned on or off (no color changes available).",
      [
        state: [
          type: :string,
          required: true,
          doc: "LED state: 'on' to turn on the green LED, 'off' to turn it off"
        ]
      ],
      {__MODULE__, :tool_led_control}
    )

    Logger.info("UART: Registered led_control tool with LLM Agent")

    # Register LED status tool
    HelloNerves.LLMAgent.register_tool(
      "led_status",
      "Check the current status of the green LED connected to the Arduino (whether it's on or off).",
      [],
      {__MODULE__, :tool_led_status}
    )

    Logger.info("UART: Registered led_status tool with LLM Agent")

    # Register light sensor tool
    HelloNerves.LLMAgent.register_tool(
      "read_light_sensor",
      "Read the light sensor value from the Arduino. Returns light level with description, raw ADC value (0-1023), percentage, and voltage.",
      [
        format: [
          type: :string,
          default: "detailed",
          doc: "Response format: 'detailed' for full info, 'raw' for just ADC value"
        ]
      ],
      {__MODULE__, :tool_read_light}
    )

    Logger.info("UART: Registered read_light_sensor tool with LLM Agent")

    # Register LED blink tool
    HelloNerves.LLMAgent.register_tool(
      "led_blink",
      "Blink the green LED connected to the Arduino via UART with configurable timing. Allows control of blink count, duration of each blink, and interval between blinks.",
      [
        count: [
          type: :integer,
          default: 1,
          doc: "Number of times to blink the green LED (default: 1)"
        ],
        duration_ms: [
          type: :integer,
          default: 1000,
          doc: "Duration each LED blink should last in milliseconds (default: 1000)"
        ],
        interval_ms: [
          type: :integer,
          default: 500,
          doc: "Time interval between blinks in milliseconds (default: 500)"
        ]
      ],
      {__MODULE__, :tool_led_blink}
    )

    Logger.info("UART: Registered led_blink tool with LLM Agent")
  end

  # Get descriptive text for light level
  defp get_light_description(adc_value) when adc_value < 100, do: "Very Dark"
  defp get_light_description(adc_value) when adc_value < 300, do: "Dark"
  defp get_light_description(adc_value) when adc_value < 500, do: "Dim"
  defp get_light_description(adc_value) when adc_value < 700, do: "Normal"
  defp get_light_description(adc_value) when adc_value < 900, do: "Bright"
  defp get_light_description(_adc_value), do: "Very Bright"
end
