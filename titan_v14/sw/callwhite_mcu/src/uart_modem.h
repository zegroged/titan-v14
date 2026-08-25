/**
 * @file uart_modem.h
 * @brief Modem UART Driver — USART2 + HW Flow Control
 */
#ifndef CALLWHITE_UART_MODEM_H
#define CALLWHITE_UART_MODEM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>


void uart_modem_init(void);
void uart_modem_poll(void);
bool uart_modem_send(const uint8_t *data, size_t len);
size_t uart_modem_recv(uint8_t *buf, size_t max_len);
void uart_modem_set_baud(uint32_t baud);

#endif
