#define F_CPU 16000000UL
#define BAUD 9600
#define USART_SPEED F_CPU/16/BAUD-1

#include <avr/io.h>
#include <avr/interrupt.h>
#include <util/delay.h>

#define sbi(port, bit) (port) |= (1 << bit)
#define cbi(port, bit) (port) &= ~(1 << bit)
#define ibi(port, bit) (port) ^= (1 << bit)
#define msbi(port, bit, bit2) (port) = (1 << bit) | (1 << bit2)

// Global variable to track LED state (0 = OFF, 1 = ON)
volatile uint8_t led_state = 0;

// Global variable to store light sensor value (0-1023)
volatile uint16_t light_sensor_value = 0;

// Transmit buffer
#define TX_BUFFER_SIZE 16
volatile char tx_buffer[TX_BUFFER_SIZE];
volatile uint8_t tx_read_idx = 0;
volatile uint8_t tx_write_idx = 0;

// USART transmit function (interrupt-driven)
void usart_transmit(char data) {
  uint8_t next_write_idx = (tx_write_idx + 1) % TX_BUFFER_SIZE;

  // Wait if buffer is full
  while (next_write_idx == tx_read_idx);

  // Add data to buffer
  tx_buffer[tx_write_idx] = data;
  tx_write_idx = next_write_idx;

  // Enable UDRE interrupt to start transmission
  sbi(UCSR0B, UDRIE0);
}

// Transmit a string
void usart_transmit_string(const char* str) {
  while (*str) {
    usart_transmit(*str++);
  }
}

// Transmit a number as ASCII string
void usart_transmit_number(uint16_t num) {
  char buffer[6]; // Max 5 digits + null terminator
  uint8_t i = 0;

  // Handle zero case
  if (num == 0) {
    usart_transmit('0');
    return;
  }

  // Convert number to string (reverse order)
  while (num > 0) {
    buffer[i++] = '0' + (num % 10);
    num /= 10;
  }

  // Transmit in correct order
  while (i > 0) {
    usart_transmit(buffer[--i]);
  }
}

// USART Data Register Empty Interrupt Handler (Transmit)
ISR(USART_UDRE_vect) {
  // If there's data in the buffer
  if (tx_read_idx != tx_write_idx) {
    // Send the next byte
    UDR0 = tx_buffer[tx_read_idx];
    tx_read_idx = (tx_read_idx + 1) % TX_BUFFER_SIZE;
  } else {
    // No more data, disable UDRE interrupt
    cbi(UCSR0B, UDRIE0);
  }
}

// ADC Conversion Complete Interrupt Handler
ISR(ADC_vect) {
  // Read ADC value and store in global variable
  light_sensor_value = ADC;

  // Start next conversion
  sbi(ADCSRA, ADSC);
}

// USART Receive Complete Interrupt Handler
ISR(USART_RX_vect) {
  char received = UDR0;  // Read received byte

  if (received == '1') {
    sbi(PORTB, PB5);  // Turn LED ON
    led_state = 1;
  } else if (received == '0') {
    cbi(PORTB, PB5);  // Turn LED OFF
    led_state = 0;
  } else if (received == '?') {
    // Query LED state - respond with '1' or '0'
    usart_transmit(led_state ? '1' : '0');
  } else if (received == 'L' || received == 'l') {
    // Query light sensor value - respond with number
    usart_transmit_number(light_sensor_value);
  }
}

void usart_init(unsigned int ubrr_val) {
  // Set baud rate
  UBRR0H = (unsigned char)(ubrr_val>> 8);
  UBRR0L = (unsigned char)ubrr_val;

  // Enable receiver, transmitter and receive interrupt
  UCSR0B = (1 << RXEN0) | (1 << TXEN0) | (1 << RXCIE0);

  // Set frame format: 8 data bits, 1 stop bit, no parity
  msbi(UCSR0C, UCSZ01, UCSZ00);

}

void adc_init(void) {
  // Set reference voltage to AVcc (5V)
  ADMUX = (1 << REFS0);

  // Select ADC0 (A0) - already set to 0 by default
  ADMUX &= 0xF0;  // Clear channel selection bits (use ADC0)

  // Enable ADC, ADC interrupt, and set prescaler to 128 (16MHz/128 = 125kHz)
  ADCSRA = (1 << ADEN) | (1 << ADIE) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);

  // Start first conversion (subsequent conversions triggered in ISR)
  sbi(ADCSRA, ADSC);
}

int setup(void) {
  // Set PB5 (Pin 13) as output
  sbi(DDRB, PB5);
  cbi(PORTB, PB5);  // Start with LED OFF

  // Initialize ADC
  adc_init();

  // Initialize USART
  usart_init(USART_SPEED);

  // Enable global interrupts
  sei();

  return 0;
}

int loop(void) {
  // Empty loop - everything handled by interrupts
  return 0;
}

int main(void) {
  setup();

  for(;;) {
   loop();
  }

  return 0;
}
