/**
 * @file uart_fpga.h
 * @brief FPGA UART Driver — USART1 921600 baud + CTS/RTS
 */
#ifndef CALLWHITE_UART_FPGA_H
#define CALLWHITE_UART_FPGA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>


#define FPGA_RX_BUF_SIZE 2048

void uart_fpga_init(void);
void uart_fpga_poll(void);

/** Send raw bytes to FPGA (checks CTS before sending) */
bool uart_fpga_send(const uint8_t *data, size_t len);

/** Get received data (returns bytes available) */
size_t uart_fpga_recv(uint8_t *buf, size_t max_len);

/** Assert CTS to FPGA (stop sending) */
void uart_fpga_cts_assert(void);

/** Deassert CTS to FPGA (resume sending) */
void uart_fpga_cts_deassert(void);

/** Check FPGA RTS state */
bool uart_fpga_rts_active(void);

#endif /* CALLWHITE_UART_FPGA_H */
