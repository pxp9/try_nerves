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
  # @lcd_cursor_shift 0x10
  @lcd_function_set 0x20
  @lcd_set_cgram_addr 0x40
  @lcd_set_ddram_addr 0x80

  # Flags for display entry mode
  # @lcd_entry_right 0x00
  @lcd_entry_left 0x02
  # @lcd_entry_shift_increment 0x01
  @lcd_entry_shift_decrement 0x00

  # Flags for display on/off control
  @lcd_display_on 0x04
  # @lcd_display_off 0x00
  @lcd_cursor_on 0x02
  @lcd_cursor_off 0x00
  @lcd_blink_on 0x01
  @lcd_blink_off 0x00

  # Flags for function set
  # @lcd_8bit_mode 0x10
  @lcd_4bit_mode 0x00
  @lcd_2line 0x08
  # @lcd_1line 0x00
  # @lcd_5x10dots 0x04
  @lcd_5x8dots 0x00

  # Backlight
  @lcd_backlight 0x08
  @lcd_nobacklight 0x00

  # Enable bit
  @en 0b00000100
  # Read/Write bit
  # @rw 0b00000010
  # Register select bit
  @rs 0b00000001

  # Health check interval in milliseconds
  @health_check_interval 5_000

  @custom_chars [
    [
      0b00010,
      0b00100,
      0b01110,
      0b00001,
      0b01111,
      0b10001,
      0b01111,
      0b00000
    ],
    [
      0b00010,
      0b00100,
      0b01110,
      0b10001,
      0b11111,
      0b10000,
      0b01110,
      0b00000
    ],
    [
      0b00010,
      0b00100,
      0b00000,
      0b01100,
      0b00100,
      0b00100,
      0b01110,
      0b00000
    ],
    [
      0b00010,
      0b00100,
      0b01110,
      0b10001,
      0b10001,
      0b10001,
      0b01110,
      0b00000
    ],
    [
      0b00010,
      0b00100,
      0b00000,
      0b10001,
      0b10001,
      0b10001,
      0b01111,
      0b00000
    ],
    [
      0b00000,
      0b01010,
      0b11111,
      0b11111,
      0b01110,
      0b00100,
      0b00000,
      0b00000
    ]
  ]

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
    :connected,
    :cursor_visible,
    :cursor_blink
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
          connected: true,
          cursor_visible: false,
          cursor_blink: false
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
  Write a single character to the LCD at the current cursor position.
  Supports UTF-8 characters (e.g., "ñ", "ö") using ROM A02 character mapping.
  Does not clear the display or move the cursor automatically.
  """
  def write_char(char) when is_binary(char) do
    GenServer.call(__MODULE__, {:write_char, char})
  end

  @doc """
  Write a character to the LCD using its hexadecimal ROM code.
  This allows direct access to any character in the LCD's ROM A02 character set.
  Does not clear the display or move the cursor automatically.

  ## Examples

      # Write ñ character (0xEE in ROM A02)
      HelloNerves.LCD1602.write_hex(0xEE)

      # Write degree symbol (0xB0)
      HelloNerves.LCD1602.write_hex(0xB0)
  """
  def write_hex(hex_code) when is_integer(hex_code) and hex_code >= 0x00 and hex_code <= 0xFF do
    GenServer.call(__MODULE__, {:write_hex, hex_code})
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
  Set cursor visibility.
  """
  def cursor(visible?) do
    GenServer.call(__MODULE__, {:cursor, visible?})
  end

  @doc """
  Set cursor blinking.
  """
  def blink(on?) do
    GenServer.call(__MODULE__, {:blink, on?})
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

  @doc """
  Send a raw instruction/command to the LCD.
  This allows direct control of the LCD hardware.

  ## Examples

      # Set CGRAM address to 0x00
      HelloNerves.LCD1602.send_instruction(0x40)

      # Set DDRAM address to 0x00 (home position)
      HelloNerves.LCD1602.send_instruction(0x80)

      # Clear display
      HelloNerves.LCD1602.send_instruction(0x01)
  """
  def send_instruction(instruction) when is_integer(instruction) do
    GenServer.call(__MODULE__, {:send_instruction, instruction})
  end

  @doc """
  Create a custom character in CGRAM.

  ## Parameters
    - location: Character location (0-7). Only locations 0-7 are available.
    - charmap: List of 8 integers (0-255) defining the character pattern.
               Each integer represents a row of 5 pixels (bits 0-4).

  ## Examples

      # Create a heart character at location 0
      heart = [
        0b00000,
        0b01010,
        0b11111,
        0b11111,
        0b01110,
        0b00100,
        0b00000,
        0b00000
      ]
      HelloNerves.LCD1602.create_char(0, heart)

      # Display the custom character (location 0)
      HelloNerves.LCD1602.write_hex(0x00)
  """
  def create_char(location, charmap)
      when is_integer(location) and is_list(charmap) and length(charmap) == 8 do
    GenServer.call(__MODULE__, {:create_char, location, charmap})
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

  def handle_call({:write_char, char}, _from, state) do
    if not state.initialized do
      Logger.warning("Writing to uninitialized LCD - this may not work correctly")
    end

    if not state.connected do
      Logger.warning("LCD is disconnected, write operation skipped")
      {:reply, {:error, :disconnected}, state}
    else
      # Write the character directly at current cursor position
      case write_string(state, char) do
        :ok ->
          {:reply, :ok, state}

        {:error, _reason} = error ->
          Logger.error("Failed to write character to LCD, marking as disconnected")
          {:reply, error, %{state | connected: false}}
      end
    end
  end

  def handle_call({:write_hex, hex_code}, _from, state) do
    if not state.initialized do
      Logger.warning("Writing to uninitialized LCD - this may not work correctly")
    end

    if not state.connected do
      Logger.warning("LCD is disconnected, write operation skipped")
      {:reply, {:error, :disconnected}, state}
    else
      # Write the hex code directly to the LCD
      case write_data(state, hex_code) do
        :ok ->
          {:reply, :ok, state}

        {:error, _reason} = error ->
          Logger.error("Failed to write hex code to LCD, marking as disconnected")
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
    update_display_control(state)

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

  def handle_call({:cursor, visible?}, _from, state) do
    new_state = %{state | cursor_visible: visible?}
    update_display_control(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:blink, on?}, _from, state) do
    new_state = %{state | cursor_blink: on?}
    update_display_control(new_state)
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

  def handle_call({:send_instruction, instruction}, _from, state) do
    if not state.initialized do
      Logger.warning("Sending instruction to uninitialized LCD - this may not work correctly")
    end

    if not state.connected do
      Logger.warning("LCD is disconnected, instruction operation skipped")
      {:reply, {:error, :disconnected}, state}
    else
      case write_command(state, instruction) do
        :ok ->
          {:reply, :ok, state}

        {:error, _reason} = error ->
          Logger.error("Failed to send instruction to LCD, marking as disconnected")
          {:reply, error, %{state | connected: false}}
      end
    end
  end

  def handle_call({:create_char, location, charmap}, _from, state) do
    if not state.initialized do
      Logger.warning("Creating custom char on uninitialized LCD - this may not work correctly")
    end

    if not state.connected do
      Logger.warning("LCD is disconnected, create_char operation skipped")
      {:reply, {:error, :disconnected}, state}
    else
      # Mask location to ensure it's 0-7
      masked_location = location &&& 0x07

      # Set CGRAM address (location << 3 gives the starting address for the character)
      cgram_address = @lcd_set_cgram_addr ||| masked_location <<< 3

      # Write the command to set CGRAM address, then write all 8 bytes
      # After writing to CGRAM, we must set the address back to DDRAM
      result =
        with :ok <- write_command(state, cgram_address),
             :ok <- write_charmap_bytes(state, charmap),
             :ok <- write_command(state, @lcd_set_ddram_addr) do
          :ok
        end

      case result do
        :ok ->
          {:reply, :ok, state}

        {:error, _reason} = error ->
          Logger.error("Failed to create custom character, marking as disconnected")
          {:reply, error, %{state | connected: false}}
      end
    end
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
               :ok <- update_display_control(state),
               :ok <- write_string(state, Enum.at(lines, 0)) do
            :ok
          end

        line_count == 2 ->
          with :ok <- write_command(state, @lcd_clear_display),
               :ok <- update_display_control(state),
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
        potential_length = lcd_display_length(potential_line)

        cond do
          lcd_display_length(word) > 16 ->
            updated_lines =
              if current_line != "",
                do: [pad_line_to_16(current_line) | lines],
                else: lines

            word_chunks = split_long_word(word)
            {word_chunks ++ updated_lines, ""}

          potential_length <= 16 ->
            {lines, potential_line}

          true ->
            {[pad_line_to_16(current_line) | lines], word}
        end
      end)

    final_lines =
      if current_line != "", do: [pad_line_to_16(current_line) | lines], else: lines

    Enum.reverse(final_lines)
  end

  defp split_long_word(word) do
    # Split word into chunks that fit on LCD display (16 chars)
    graphemes = String.graphemes(word)

    graphemes
    |> chunk_by_display_length(16)
    |> Enum.map(&pad_line_to_16/1)
    |> Enum.reverse()
  end

  # Chunk graphemes into strings where each chunk has max display length
  defp chunk_by_display_length(graphemes, max_length) do
    {chunks, current_chunk} =
      Enum.reduce(graphemes, {[], ""}, fn grapheme, {chunks, current_chunk} ->
        potential_chunk = current_chunk <> grapheme

        if lcd_display_length(potential_chunk) <= max_length do
          {chunks, potential_chunk}
        else
          {[current_chunk | chunks], grapheme}
        end
      end)

    final_chunks = if current_chunk != "", do: [current_chunk | chunks], else: chunks
    Enum.reverse(final_chunks)
  end

  # Pad a line to 16 characters using spaces
  defp pad_line_to_16(line) do
    current_length = lcd_display_length(line)
    spaces_needed = max(0, 16 - current_length)
    line <> String.duplicate(" ", spaces_needed)
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

    write_command(state, @lcd_clear_display)

    write_command(state, @lcd_entry_mode_set ||| @lcd_entry_left ||| @lcd_entry_shift_decrement)

    write_command(state, @lcd_return_home)

    # Set display control based on current cursor state
    update_display_control(state)

    # Load custom characters into CGRAM
    load_custom_chars(state)
  end

  # Load all custom characters defined in @custom_chars into CGRAM
  defp load_custom_chars(state) do
    @custom_chars
    |> Enum.with_index()
    |> Enum.each(fn {charmap, location} ->
      # Mask location to ensure it's 0-7
      masked_location = location &&& 0x07

      # Set CGRAM address (location << 3 gives the starting address for the character)
      cgram_address = @lcd_set_cgram_addr ||| masked_location <<< 3

      # Write the command to set CGRAM address, then write all 8 bytes
      write_command(state, cgram_address)
      write_charmap_bytes(state, charmap)
    end)

    # Return cursor to DDRAM after loading custom characters
    write_command(state, @lcd_set_ddram_addr)
  end

  # Update display control based on current cursor settings
  defp update_display_control(state) do
    cursor_flag = if state.cursor_visible, do: @lcd_cursor_on, else: @lcd_cursor_off
    blink_flag = if state.cursor_blink, do: @lcd_blink_on, else: @lcd_blink_off

    write_command(
      state,
      @lcd_display_control ||| @lcd_display_on ||| cursor_flag ||| blink_flag
    )
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
    # Convert UTF-8 string to LCD character codes using ROM A02 mapping
    lcd_codes = utf8_to_lcd_codes(text)

    Enum.reduce_while(lcd_codes, :ok, fn code, _acc ->
      case write_data(state, code) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Write 8 bytes of character map data to CGRAM
  defp write_charmap_bytes(state, charmap) do
    Enum.reduce_while(charmap, :ok, fn byte, _acc ->
      case write_data(state, byte) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Convert UTF-8 string to LCD ROM A02 character codes
  defp utf8_to_lcd_codes(text) do
    text
    |> String.graphemes()
    |> Enum.flat_map(&utf8_char_to_lcd_code/1)
  end

  # Calculate display length for UTF-8 text on LCD
  defp lcd_display_length(text) do
    text |> utf8_to_lcd_codes() |> length()
  end

  defp utf8_char_to_lcd_code(char) when char >= " " and char <= "~" do
    [char |> String.to_charlist() |> hd()]
  end

  # Spanish characters
  defp utf8_char_to_lcd_code("ñ"), do: [0xEE]
  defp utf8_char_to_lcd_code("Ñ"), do: [0xEE]
  defp utf8_char_to_lcd_code("á"), do: [0x00]
  defp utf8_char_to_lcd_code("é"), do: [0x01]
  defp utf8_char_to_lcd_code("í"), do: [0x02]
  defp utf8_char_to_lcd_code("ó"), do: [0x03]
  defp utf8_char_to_lcd_code("ú"), do: [0x04]
  defp utf8_char_to_lcd_code("Á"), do: [0x00]
  defp utf8_char_to_lcd_code("É"), do: [0x01]
  defp utf8_char_to_lcd_code("Í"), do: [0x02]
  defp utf8_char_to_lcd_code("Ó"), do: [0x03]
  defp utf8_char_to_lcd_code(""), do: [0x04]

  # Common symbols
  defp utf8_char_to_lcd_code("°"), do: [0xDF]
  defp utf8_char_to_lcd_code("µ"), do: [0xE4]
  defp utf8_char_to_lcd_code("❤️"), do: [0x05]

  ## Math
  defp utf8_char_to_lcd_code("π"), do: [0xF7]

  # Fallback: for unmapped characters, use ASCII transliteration or '?'
  defp utf8_char_to_lcd_code(_char) do
    # Question mark for unknown characters
    [0x3F]
  end
end
