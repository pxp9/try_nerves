defmodule HelloNerves.LCD1602 do
  @moduledoc """
  Driver for I2C LCD1602 display using PCF8574 I/O expander.
  """

  use GenServer
  import Bitwise
  require Logger

  # LCD Commands
  @lcd_clear_display 0x01
  @lcd_return_home 0x02
  @lcd_entry_mode_set 0x04
  @lcd_display_control 0x08
  @lcd_cursor_shift 0x10
  @lcd_function_set 0x20
  @lcd_set_cgram_addr 0x40
  @lcd_set_ddram_addr 0x80

  # Flags for display entry mode
  @lcd_entry_right 0x00
  @lcd_entry_left 0x02
  @lcd_entry_shift_increment 0x01
  @lcd_entry_shift_decrement 0x00

  # Flags for display on/off control
  @lcd_display_on 0x04
  @lcd_display_off 0x00
  @lcd_cursor_on 0x02
  @lcd_cursor_off 0x00
  @lcd_blink_on 0x01
  @lcd_blink_off 0x00

  # Flags for function set
  @lcd_8bit_mode 0x10
  @lcd_4bit_mode 0x00
  @lcd_2line 0x08
  @lcd_1line 0x00
  @lcd_5x10dots 0x04
  @lcd_5x8dots 0x00

  # Backlight
  @lcd_backlight 0x08
  @lcd_nobacklight 0x00

  # Enable bit
  @en 0b00000100
  # Read/Write bit
  @rw 0b00000010
  # Register select bit
  @rs 0b00000001

  # Health check interval in milliseconds
  @health_check_interval 5_000

  defstruct [
    :i2c_ref,
    :address,
    :backlight,
    :bus,
    :initialized,
    :current_text,
    :scroll_timer,
    :scroll_position,
    :text_lines,
    :health_check_timer,
    :connected
  ]

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Initialize the LCD display.
  Options:
    - :bus - I2C bus name (default: "i2c-1")
    - :address - I2C address (default: 0x27, alternative: 0x3F)
  """
  def init(opts) do
    bus = Keyword.get(opts, :bus, "i2c-1")
    address = Keyword.get(opts, :address, 0x27)

    case Circuits.I2C.open(bus) do
      {:ok, i2c_ref} ->
        state = %__MODULE__{
          i2c_ref: i2c_ref,
          address: address,
          backlight: @lcd_backlight,
          bus: bus,
          initialized: false,
          current_text: "",
          scroll_timer: nil,
          scroll_position: 0,
          text_lines: [],
          health_check_timer: nil,
          connected: true
        }

        # Always perform full initialization if bus is connected
        Logger.info("Initializing LCD display...")
        initialize_lcd(state)

        # Mark as initialized
        state = %{state | initialized: true}

        # Schedule periodic health check
        health_timer = Process.send_after(self(), :health_check, @health_check_interval)
        state = %{state | health_check_timer: health_timer}

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to open I2C bus: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @doc """
  Write text to the LCD with smart handling:
  - Text <= 16 chars: displays on one line
  - Text <= 32 chars: splits across two lines (16 chars each)
  - Text > 32 chars: splits into 16-char lines and scrolls vertically

  For long text, the text is split into 16-character lines and displayed
  two lines at a time. The display scrolls down through the lines,
  making it easy to read naturally (top to bottom).
  The display automatically clears before writing.
  """
  def write(text) do
    GenServer.call(__MODULE__, {:write, text})
  end

  @doc """
  Stop any active text scrolling.
  """
  def stop_scroll do
    GenServer.call(__MODULE__, :stop_scroll)
  end

  @doc """
  Clear the display.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Set cursor position (row: 0-1, col: 0-15).
  """
  def set_cursor(row, col) do
    GenServer.call(__MODULE__, {:set_cursor, row, col})
  end

  @doc """
  Turn backlight on or off.
  """
  def backlight(on?) do
    GenServer.call(__MODULE__, {:backlight, on?})
  end

  @doc """
  Reinitialize the LCD display. Useful for debugging or recovery.
  """
  def reinit do
    GenServer.call(__MODULE__, :reinit)
  end

  @doc """
  Check if the LCD is initialized.
  """
  def initialized? do
    GenServer.call(__MODULE__, :initialized?)
  end

  @doc """
  Check if the LCD is connected.
  """
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  ## GenServer Callbacks

  def handle_call({:write, text}, _from, state) do
    if not state.initialized do
      Logger.warning("Writing to uninitialized LCD - this may not work correctly")
    end

    if not state.connected do
      Logger.warning("LCD is disconnected, write operation skipped")
      {:reply, {:error, :disconnected}, state}
    else
      # Cancel any existing scroll timer
      if state.scroll_timer do
        Process.cancel_timer(state.scroll_timer)
      end

      # Smart text handling based on length
      case handle_smart_write(state, text) do
        {:ok, new_state} ->
          {:reply, :ok, new_state}

        {:error, _reason} = error ->
          # Mark as disconnected
          Logger.error("Failed to write to LCD, marking as disconnected")
          {:reply, error, %{state | connected: false}}
      end
    end
  end

  def handle_call(:clear, _from, state) do
    # Cancel any scroll timer
    if state.scroll_timer do
      Process.cancel_timer(state.scroll_timer)
    end

    write_command(state, @lcd_clear_display)

    {:reply, :ok,
     %{state | current_text: "", scroll_timer: nil, scroll_position: 0, text_lines: []}}
  end

  def handle_call({:set_cursor, row, col}, _from, state) do
    # Row offsets: row 0 starts at 0x00, row 1 starts at 0x40
    row_offsets = [0x00, 0x40]
    offset = Enum.at(row_offsets, row, 0x00)
    write_command(state, @lcd_set_ddram_addr ||| col + offset)
    {:reply, :ok, state}
  end

  def handle_call({:backlight, on?}, _from, state) do
    new_backlight = if on?, do: @lcd_backlight, else: @lcd_nobacklight
    new_state = %{state | backlight: new_backlight}
    # Write backlight state to expander (data bits = 0)
    expander_write(new_state, 0)
    {:reply, :ok, new_state}
  end

  def handle_call(:reinit, _from, state) do
    Logger.info("Manual LCD reinitialization requested")

    # Cancel any scroll timer
    if state.scroll_timer do
      Process.cancel_timer(state.scroll_timer)
    end

    initialize_lcd(state)

    new_state = %{
      state
      | initialized: true,
        current_text: "",
        scroll_timer: nil,
        scroll_position: 0,
        text_lines: []
    }

    {:reply, :ok, new_state}
  end

  def handle_call(:initialized?, _from, state) do
    {:reply, state.initialized, state}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  def handle_call(:stop_scroll, _from, state) do
    if state.scroll_timer do
      Process.cancel_timer(state.scroll_timer)
    end

    {:reply, :ok, %{state | scroll_timer: nil, scroll_position: 0, text_lines: []}}
  end

  def handle_info({:info, :restart}, state) do
    {:noreply, state}
  end

  def handle_info(:scroll_text, state) do
    if not state.connected do
      # Stop scrolling if disconnected
      {:noreply, %{state | scroll_timer: nil}}
    else
      new_position = state.scroll_position + 1
      line_count = length(state.text_lines)

      new_position =
        if new_position >= line_count do
          Process.sleep(1000)
          0
        else
          new_position
        end

      case display_lines_at_position(state, state.text_lines, new_position) do
        :ok ->
          timer = Process.send_after(self(), :scroll_text, 500)
          {:noreply, %{state | scroll_timer: timer, scroll_position: new_position}}

        {:error, _reason} ->
          # Display failed, mark as disconnected and stop scrolling
          Logger.error("Scroll display failed, marking LCD as disconnected")
          {:noreply, %{state | scroll_timer: nil, connected: false}}
      end
    end
  end

  def handle_info(:health_check, state) do
    # Check if the I2C device is present
    device_present = Circuits.I2C.device_present?(state.i2c_ref, state.address)

    case device_present do
      true ->
        # Device is responding
        if not state.connected do
          Logger.info("LCD reconnected!")
          # Try to reinitialize
          initialize_lcd(state)
        end

        # Schedule next health check
        timer = Process.send_after(self(), :health_check, @health_check_interval)
        {:noreply, %{state | connected: true, health_check_timer: timer}}

      false ->
        # Device is not responding
        if state.connected do
          Logger.warning("LCD disconnected")
        end

        # Schedule next health check (will keep trying to reconnect)
        timer = Process.send_after(self(), :health_check, @health_check_interval)
        {:noreply, %{state | connected: false, health_check_timer: timer}}
    end
  end

  defp handle_smart_write(state, text) do
    lines = split_into_lines(text)
    line_count = length(lines)

    result =
      cond do
        line_count == 1 ->
          with :ok <- write_command(state, @lcd_clear_display),
               :ok <- write_command(state, @lcd_return_home),
               :ok <- write_string(state, Enum.at(lines, 0)) do
            :ok
          end

        line_count == 2 ->
          with :ok <- write_command(state, @lcd_clear_display),
               :ok <- write_command(state, @lcd_return_home),
               :ok <- write_string(state, Enum.at(lines, 0)),
               :ok <- write_command(state, @lcd_set_ddram_addr ||| 0x40),
               :ok <- write_string(state, Enum.at(lines, 1)) do
            :ok
          end

        true ->
          display_lines_at_position(state, lines, 0)
      end

    case result do
      :ok ->
        timer = if line_count > 2, do: Process.send_after(self(), :scroll_text, 2000), else: nil

        {:ok,
         %{state | current_text: text, scroll_timer: timer, scroll_position: 0, text_lines: lines}}

      {:error, _reason} = error ->
        error
    end
  end

  defp split_into_lines(text) do
    words = String.split(text, " ", trim: false)

    {lines, current_line} =
      Enum.reduce(words, {[], ""}, fn word, {lines, current_line} ->
        separator = if current_line == "", do: "", else: " "
        potential_line = current_line <> separator <> word
        potential_length = String.length(potential_line)

        cond do
          String.length(word) > 16 ->
            updated_lines =
              if current_line != "",
                do: [String.pad_trailing(current_line, 16) | lines],
                else: lines

            word_chunks = split_long_word(word)
            {word_chunks ++ updated_lines, ""}

          potential_length <= 16 ->
            {lines, potential_line}

          true ->
            {[String.pad_trailing(current_line, 16) | lines], word}
        end
      end)

    final_lines =
      if current_line != "", do: [String.pad_trailing(current_line, 16) | lines], else: lines

    Enum.reverse(final_lines)
  end

  defp split_long_word(word) do
    word
    |> String.graphemes()
    |> Enum.chunk_every(16)
    |> Enum.map(fn chars ->
      chars
      |> Enum.join("")
      |> String.pad_trailing(16, " ")
    end)
    |> Enum.reverse()
  end

  defp display_lines_at_position(state, lines, position) do
    line_count = length(lines)

    line1 = Enum.at(lines, rem(position, line_count))
    line2 = Enum.at(lines, rem(position + 1, line_count))

    with :ok <- write_command(state, @lcd_return_home),
         :ok <- write_string(state, line1),
         :ok <- write_command(state, @lcd_set_ddram_addr ||| 0x40),
         :ok <- write_string(state, line2) do
      :ok
    end
  end

  defp initialize_lcd(state) do
    Process.sleep(50)

    expander_write(state, state.backlight)
    Process.sleep(100)

    write_4bits(state, 0x03 <<< 4)
    Process.sleep(5)

    write_4bits(state, 0x03 <<< 4)
    Process.sleep(1)

    write_4bits(state, 0x03 <<< 4)
    Process.sleep(1)

    write_4bits(state, 0x02 <<< 4)

    write_command(state, @lcd_function_set ||| @lcd_4bit_mode ||| @lcd_2line ||| @lcd_5x8dots)

    write_command(
      state,
      @lcd_display_control ||| @lcd_display_on ||| @lcd_cursor_off ||| @lcd_blink_off
    )

    write_command(state, @lcd_clear_display)

    write_command(state, @lcd_entry_mode_set ||| @lcd_entry_left ||| @lcd_entry_shift_decrement)

    write_command(state, @lcd_return_home)
  end

  defp write_command(state, cmd) do
    case write_byte(state, cmd, 0) do
      :ok ->
        command_delay(cmd)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp command_delay(cmd) when cmd == @lcd_clear_display or cmd == @lcd_return_home do
    Process.sleep(2)
  end

  defp command_delay(_cmd), do: :ok

  defp write_data(state, data) do
    write_byte(state, data, @rs)
  end

  defp write_byte(state, data, mode) do
    high_bits = data &&& 0xF0
    low_bits = data <<< 4 &&& 0xF0

    with :ok <- write_4bits(state, high_bits ||| mode),
         :ok <- write_4bits(state, low_bits ||| mode) do
      :ok
    end
  end

  defp write_4bits(state, data) do
    with :ok <- expander_write(state, data),
         :ok <- pulse_enable(state, data) do
      :ok
    end
  end

  defp pulse_enable(state, data) do
    with :ok <- expander_write(state, data ||| @en) do
      Process.sleep(1)
      expander_write(state, data &&& ~~~@en)
      Process.sleep(1)
      :ok
    end
  end

  defp expander_write(state, data) do
    output = data ||| state.backlight
    i2c_write(state, output)
  end

  defp i2c_write(state, data) do
    case Circuits.I2C.write(state.i2c_ref, state.address, <<data>>) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("I2C write failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp write_string(state, text) do
    chars = String.to_charlist(text)

    Enum.reduce_while(chars, :ok, fn char, _acc ->
      case write_data(state, char) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
