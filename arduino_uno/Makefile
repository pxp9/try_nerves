.PHONY: clean

all: _build/avr/.flashed

_build/avr:
	mkdir -p _build/avr

_build/avr/main.elf: src/arduino.c | _build/avr
	avr-gcc -O3 -mmcu=atmega328p -o _build/avr/main.elf src/arduino.c

_build/avr/main.hex: _build/avr/main.elf
	avr-objcopy -O ihex -R .eeprom _build/avr/main.elf _build/avr/main.hex

_build/avr/.flashed: _build/avr/main.hex
	sudo avrdude -c arduino -p atmega328p -P $(shell \ls /dev/ttyACM*) -U flash:w:_build/avr/main.hex:i
	touch _build/avr/.flashed

clean:
	rm -rf _build/avr
