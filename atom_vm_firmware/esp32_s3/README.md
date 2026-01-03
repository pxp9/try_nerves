# AtomVM Firmware for ESP32-S3

Simple AtomVM firmware for ESP32-S3 microcontroller.

## Getting Started

1. Install dependencies:
   ```bash
   mix deps.get
   ```

2. Build the project:
   ```bash
   mix compile
   ```

3. Flash to ESP32-S3:
   ```bash
   mix atomvm.flash
   ```

## Project Structure

- `lib/` - Application code
- `test/` - Test files
- `mix.exs` - Project configuration
