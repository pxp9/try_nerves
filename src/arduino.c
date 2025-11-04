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

// USART Receive Complete Interrupt Handler
ISR(USART_RX_vect) {
  char received = UDR0;  // Read received byte

  if (received == '1') {
    sbi(PORTB, PB5);  // Turn LED ON
  } else if (received == '0') {
    cbi(PORTB, PB5);  // Turn LED OFF
  }
}

void usart_init(unsigned int ubrr_val) {
  // Set baud rate
  UBRR0H = (unsigned char)(ubrr_val>> 8);
  UBRR0L = (unsigned char)ubrr_val;

  // Enable receiver and receive interrupt
  msbi(UCSR0B, RXEN0, RXCIE0);

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
