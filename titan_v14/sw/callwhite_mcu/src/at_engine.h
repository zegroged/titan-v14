/**
 * @file at_engine.h
 * @brief AT Command Engine — Modem Control State Machine
 */
#ifndef CALLWHITE_AT_ENGINE_H
#define CALLWHITE_AT_ENGINE_H

#include <stdbool.h>
#include <stdint.h>


typedef enum {
  AT_IDLE,
  AT_SENDING,
  AT_WAITING_RESPONSE,
  AT_TIMEOUT,
  AT_ERROR,
} at_state_t;

typedef enum {
  AT_RESP_OK,
  AT_RESP_ERROR,
  AT_RESP_TIMEOUT,
  AT_RESP_URC, /* Unsolicited Result Code */
} at_result_t;

typedef void (*at_callback_t)(at_result_t result, const char *response);

void at_engine_init(void);
void at_engine_poll(void);

/** Send AT command with callback */
at_result_t at_send(const char *cmd, at_callback_t cb, uint32_t timeout_ms);

/** Blocking AT command (waits for response) */
at_result_t at_send_sync(const char *cmd, char *resp_buf, size_t buf_len,
                         uint32_t timeout_ms);

/** Check if engine is busy */
bool at_is_busy(void);

#endif /* CALLWHITE_AT_ENGINE_H */
