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

int setup(void) {
  // Set PB5 (Pin 13) as output
  sbi(DDRB, PB5);
  cbi(PORTB, PB5);  // Start with LED OFF

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
