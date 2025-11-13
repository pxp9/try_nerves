# AtomVmFirmware

Firmware project for running Elixir on Raspberry Pi Pico 2W using AtomVM.

## AtomVM workflow

```
  *.erl or *.ex                  *.beam
+-------+                   +-------+
|       |+                  |       |+
|       ||+                 |       ||+
|       |||     -------->   |       |||
|       |||  Erlang/Elixir  |       |||
+-------+||     Compiler    +-------+||
 +-------+|                  +-------+|
  +-------+                   +-------+
     ^                           |
     |                           | packbeam
     |                           |
     |                           v
     |                       +-------+
     |                       |       |
     | test                  |       |
     | debug                 |       |
     | fix                   |       |
     |                       +-------+
     |                        app.avm
     |                           |
     |                           | flash/upload
     |                           |
     |                           v
     +-------------------- Micro-controller
                              device
```

## Complete Setup Guide for Raspberry Pi Pico 2W

This guide covers the complete workflow from building AtomVM runtime to deploying your Elixir application.

### Prerequisites

- CMake (≥3.13)
- ARM/RISC-V toolchain (for Pico 2W RISC-V: `arm-none-eabi-gcc` or RISC-V toolchain) [RISC-V toolchain](https://github.com/raspberrypi/pico-sdk-tools/releases/download/v2.1.1-3/riscv-toolchain-15-x86_64-lin.tar.gz)
- Pico SDK, automatically downloaded by AtomVM
- Erlang/OTP
- Elixir
- Mix build tool
- picotool (for flashing via command line)

### Important Paths

When working with the Pico 2W:
- **BOOTSEL mode mount point**: `/run/media/${USER}/RP2350` (where ${USER} is your username)
- **Serial console**: `/dev/ttyACM*` (when AtomVM is running)

### Step 1: Build AtomVM Runtime for Pico 2W

The AtomVM runtime needs to be compiled and flashed to your Pico 2W first. This only needs to be done once (or when updating AtomVM).

```bash
# Navigate to the RP2 platform directory
cd AtomVM/src/platforms/rp2

# Create a build directory for RISC-V (Pico 2 uses RISC-V cores)
mkdir -p build_riscv
cd build_riscv

# Configure the build for RP2350 (Pico 2)
cmake .. -DPICO_BOARD=pico2_w -DPICO_PLATFORM=rp2350-riscv

# Build the AtomVM runtime
make -j$(nproc)

# The AtomVM.uf2 file will be generated at:
# src/AtomVM.uf2
```

### Step 2: Flash AtomVM Runtime to Pico 2W

You need to flash the AtomVM.uf2 runtime to your Pico 2W. This provides the virtual machine that will run your Elixir code.

#### Method 1: Using picotool (Recommended)

```bash
# Put your Pico 2W into BOOTSEL mode:
# - Hold the BOOTSEL button
# - Press and release the RESET button (or plug in USB)
# - Release the BOOTSEL button

# Flash using picotool
picotool load -f AtomVM/src/platforms/rp2/build_riscv/src/AtomVM.uf2

# Reboot the device
picotool reboot
```

#### Method 2: Using Mass Storage

```bash
# Put your Pico 2W into BOOTSEL mode (same as above)
# The device will mount at: /run/media/${USER}/RP2350

# Copy the UF2 file to the mounted device
cp AtomVM/src/platforms/rp2/build_riscv/src/AtomVM.uf2 /run/media/${USER}/RP2350/

# The device will automatically reboot after copying
```

### Step 3: Build Your Elixir Application

Now that AtomVM is running on the Pico, you can compile and flash your Elixir application.

```bash
# From the atom_vm_firmware directory

# Get dependencies (if not already done)
mix deps.get

# Compile your Elixir application
mix compile

# This will generate .beam files in _build/dev/lib/atom_vm_firmware/ebin/
```

### Step 4: Flash Your Elixir Application to Pico 2W

The application will be packaged into an AVM file and converted to UF2 format, then flashed to the Pico.

#### Quick Method: All-in-One Command

```bash
mix atomvm.pico.flash
```

This command will:
1. Compile your application (if needed)
2. Package it into an AVM file
3. Convert to UF2 format
4. Wait for the device to mount at `/run/media/${USER}/RP2350`
5. Copy the UF2 to the device

The device path is configured in `mix.exs`:
```elixir
atomvm: [
  pico_path: "/run/media/${USER}/RP2350",  # Mount point for Pico 2 in BOOTSEL
  pico_reset: "/dev/ttyACM*",              # Serial device for reset
  family_id: :rp2350_riscv,                # Target family
  app_start: "0x101B0000"                  # Application start address
]
```

#### Manual Method: Step by Step

```bash
# 1. Package your application into an AVM file
mix atomvm.packbeam

# 2. Create the UF2 file
mix atomvm.uf2create

# 3. Put Pico into BOOTSEL mode (it will mount at /run/media/${USER}/RP2350)

# 4. Copy the UF2 file
cp atom_vm_firmware.uf2 /run/media/${USER}/RP2350/

# The device will automatically reboot and start your application
```

### Typical Development Workflow

Once AtomVM is installed, your regular development cycle is:

```bash
# 1. Edit your Elixir code in lib/

# 2. Compile and flash
mix atomvm.pico.flash

# 3. Monitor serial output (if your code uses IO)
# The serial device is at /dev/ttyACM*
screen /dev/ttyACM0 115200
# or
picocom /dev/ttyACM0 -b 115200

# 4. Debug, fix, repeat!
```

### Configuration

The project is configured for Pico 2W with RISC-V architecture in `mix.exs`:

- **Target**: RP2350 (Pico 2) with RISC-V cores
- **BOOTSEL mount path**: `/run/media/${USER}/RP2350`
- **Serial device**: `/dev/ttyACM*` (for monitoring and reset)
- **Application start address**: `0x101B0000` (specific to RP2350)

### Troubleshooting

**Device not mounting:**
- Ensure you're holding BOOTSEL before connecting/resetting
- Check `dmesg` for USB connection messages
- Verify device mounted at `/run/media/${USER}/RP2350`
- If using a different username, update `pico_path` in `mix.exs`

**AtomVM.uf2 not found:**
- Verify you built for the correct architecture (`-DPICO_PLATFORM=rp2350-riscv`)
- Check that the build completed successfully
- Look in `AtomVM/src/platforms/rp2/build_riscv/src/AtomVM.uf2`

**Application not running:**
- Verify AtomVM.uf2 was flashed first
- Check that your application's start module is configured in `mix.exs`
- Connect to serial console at `/dev/ttyACM0` to see error messages

**Serial console issues:**
- Check that the device appears at `/dev/ttyACM*` (use `ls /dev/ttyACM*`)
- Ensure you have permissions to access serial devices (add user to `dialout` group)
- Try unplugging and replugging the device

### Debugging

#### Check if device is connected and in what mode

```bash
# Check USB devices
sudo dmesg | tail -40

# Look for lines like:
# "Pico" - device is running AtomVM
# "RP2350 Boot" - device is in BOOTSEL mode
```

#### Check serial device

```bash
# List serial devices
ls /dev/ttyACM*

# Should show /dev/ttyACM0 when AtomVM is running
```

#### Capture serial output from AtomVM

```bash
# Reboot device and capture output
sudo picotool reboot 2>&1 && sleep 2 && timeout 10 cat /dev/ttyACM0 2>&1

# Or use screen to monitor continuously
screen /dev/ttyACM0 115200

# Or use picocom
picocom /dev/ttyACM0 -b 115200
```

#### Check memory addresses

If you see an error like "This VM is too large (end 0x... >= LIB_AVM 0x...)", the AtomVM binary is overlapping with the library or application address space.

```bash
# Check the AtomVM main.c for current addresses
grep -A2 "define LIB_AVM" AtomVM/src/platforms/rp2/src/main.c

# Should show something like:
# #define LIB_AVM ((void *) 0x10130000)
# #define MAIN_AVM ((void *) 0x101B0000)
```

The `app_start` in `mix.exs` must match `MAIN_AVM` in main.c.

#### Verify UF2 file target address

```bash
# Check the target address in your application UF2
hexdump -C atom_vm_firmware.uf2 | head -2

# Look at bytes 0x0C-0x0F (little-endian):
# For 0x101B0000, you should see: 00 00 1B 10
# For 0x10180000, you should see: 00 00 18 10
```

#### Check if device keeps rebooting to BOOTSEL

```bash
# If the device appears briefly as ttyACM0 then returns to BOOTSEL mode,
# check the serial output for error messages

# Watch dmesg continuously
sudo dmesg -w

# Look for pattern:
# 1. "Pico" device connects (AtomVM starting)
# 2. ttyACM0 appears
# 3. Device disconnects
# 4. "RP2350 Boot" appears (back in BOOTSEL)
# This indicates AtomVM is crashing
```

### Project Structure

```
atom_vm_firmware/
├── AtomVM/                    # AtomVM runtime source (submodule/clone)
│   └── src/platforms/rp2/
│       └── build_riscv/
│           └── src/
│               └── AtomVM.uf2 # Built runtime for Pico 2
├── lib/                       # Your Elixir application code
├── mix.exs                    # Project configuration
├── atom_vm_firmware.avm       # Packaged application
└── atom_vm_firmware.uf2       # Application in UF2 format
```
