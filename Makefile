.PHONY: clean

all: _build/avr/.flashed

_build/avr:
	mkdir -p _build/avr

_build/avr/main.elf: src/arduino.c | _build/avr
	avr-gcc -O3 -mmcu=atmega328p -o _build/avr/main.elf src/arduino.c

_build/avr/main.hex: _build/avr/main.elf
	avr-objcopy -O ihex -R .eeprom _build/avr/main.elf _build/avr/main.hex

_build/avr/.flashed: _build/avr/main.hex
	sudo avrdude -c arduino -p atmega328p -P /dev/ttyACM0 -U flash:w:_build/avr/main.hex:i
	touch _build/avr/.flashed

clean:
	rm -rf _build/avr

# Quit screen Ctrl + A, Ctrl + \ 
screen:
	screen /dev/ttyACM0 9600

disk.img:
	qemu-img create -f raw disk.img 1G
	fwup -d disk.img _build/x86_64_dev/nerves/images/hello_nerves.fw

qemu: disk.img
	qemu-system-x86_64 -drive file=disk.img,if=virtio,format=raw -net nic,model=virtio -net user,hostfwd=tcp::10022-:22,hostfwd=tcp::8080-:80 -nographic -serial mon:stdio -m 1024

kill_qemu_x86_64:
	kill -9 $$(pidof qemu-system-x86_64)

kill_qemu_aarch64:
	kill -9 $$(pidof qemu-system-aarch64)
	
