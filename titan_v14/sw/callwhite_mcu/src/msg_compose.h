/**
 * @file msg_compose.h
 * @brief ★ P4 #40: Mesaj Yazma ve Gönderme (MCU tarafı)
 *
 * Keypad (T9) ile mesaj yazma + UART üzerinden FPGA'ya gönderme.
 * FPGA, mesajı encrypt edip COBS frame'leyerek modem'e iletir.
 *
 * Akış: Keypad → T9 buffer → OLED preview → # ile gönder → UART TX
 *
 * Bağımlılık: keypad.h, oled_ui.h, uart_fpga.h
 */
#ifndef MSG_COMPOSE_H
#define MSG_COMPOSE_H

#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * Constants
 *============================================================================*/
#define MSG_MAX_LENGTH 160    /* SMS-like max length */
#define MSG_SEND_TIMEOUT 5000 /* 5s gönderim timeout */

/*============================================================================
 * Message compose state machine
 *============================================================================*/
typedef enum {
  COMPOSE_IDLE,    /* Mesaj yok — ana ekran */
  COMPOSE_TYPING,  /* T9 ile yazıyor */
  COMPOSE_CONFIRM, /* "Gönder?" onay ekranı */
  COMPOSE_SENDING, /* UART'a gönderiliyor */
  COMPOSE_SENT,    /* Gönderildi — 2s sonra IDLE'a dön */
  COMPOSE_ERROR    /* Gönderim hatası */
} compose_state_t;

typedef struct {
  compose_state_t state;
  char buffer[MSG_MAX_LENGTH + 1]; /* Null-terminated */
  uint8_t cursor;                  /* Current position */
  uint32_t send_tick;              /* Gönderim başlangıç zamanı */
  uint32_t state_change_tick;      /* Son durum değişikliği */
  uint8_t retry_count;             /* Gönderim deneme sayısı */
} msg_compose_state_t;

static msg_compose_state_t mcs = {.state = COMPOSE_IDLE,
                                  .cursor = 0,
                                  .send_tick = 0,
                                  .state_change_tick = 0,
                                  .retry_count = 0};

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize message compose system.
 */
static inline void msg_compose_init(void) {
  mcs.state = COMPOSE_IDLE;
  mcs.cursor = 0;
  mcs.retry_count = 0;
  memset(mcs.buffer, 0, sizeof(mcs.buffer));
}

/**
 * @brief Start composing a new message.
 *        Transitions from IDLE → TYPING.
 */
static inline void msg_compose_start(void) {
  if (mcs.state != COMPOSE_IDLE)
    return;
  mcs.state = COMPOSE_TYPING;
  mcs.cursor = 0;
  mcs.retry_count = 0;
  memset(mcs.buffer, 0, sizeof(mcs.buffer));
}

/**
 * @brief Process a keypress during composition.
 * @param key  Key from keypad ('0'-'9', '*'=backspace, '#'=send)
 */
static inline void msg_compose_key(char key) {
  switch (mcs.state) {
  case COMPOSE_TYPING:
    if (key == '#') {
      if (mcs.cursor > 0) {
        mcs.state = COMPOSE_CONFIRM;
        mcs.state_change_tick = HAL_GetTick();
      }
    } else if (key == '*') {
      if (mcs.cursor > 0) {
        mcs.cursor--;
        mcs.buffer[mcs.cursor] = 0;
      }
    } else if (key >= '0' && key <= '9') {
      if (mcs.cursor < MSG_MAX_LENGTH) {
        mcs.buffer[mcs.cursor++] = key;
        mcs.buffer[mcs.cursor] = 0;
      }
    }
    break;

  case COMPOSE_CONFIRM:
    if (key == '#') {
      mcs.state = COMPOSE_SENDING;
      mcs.send_tick = HAL_GetTick();
    } else if (key == '*') {
      mcs.state = COMPOSE_TYPING;
    }
    break;

  default:
    break;
  }
}

/**
 * @brief Poll message compose state (call from main loop).
 * @param tick  Current HAL tick
 */
static inline void msg_compose_poll(uint32_t tick) {
  switch (mcs.state) {
  case COMPOSE_SENDING: {
    /* UART TX format: [0x01 = MSG_TEXT][len:2][payload:N] */
    uint8_t header[3];
    header[0] = 0x01; /* MSG_TEXT type */
    header[1] = (uint8_t)(mcs.cursor >> 8);
    header[2] = (uint8_t)(mcs.cursor & 0xFF);

    /* Send header + payload via FPGA UART (huart1 from main.c) */
    extern UART_HandleTypeDef huart1;
    HAL_UART_Transmit(&huart1, header, 3, 100);
    HAL_UART_Transmit(&huart1, (uint8_t *)mcs.buffer, mcs.cursor, 500);

    mcs.state = COMPOSE_SENT;
    mcs.state_change_tick = tick;
    break;
  }

  case COMPOSE_SENT:
    if (tick - mcs.state_change_tick >= 2000) {
      mcs.state = COMPOSE_IDLE;
      mcs.cursor = 0;
      memset(mcs.buffer, 0, sizeof(mcs.buffer));
    }
    break;

  case COMPOSE_ERROR:
    if (tick - mcs.state_change_tick >= 3000) {
      if (mcs.retry_count < 3) {
        mcs.retry_count++;
        mcs.state = COMPOSE_SENDING;
      } else {
        mcs.state = COMPOSE_IDLE;
        mcs.cursor = 0;
        memset(mcs.buffer, 0, sizeof(mcs.buffer));
      }
    }
    break;

  default:
    break;
  }
}

/**
 * @brief Cancel composition and return to IDLE.
 */
static inline void msg_compose_cancel(void) {
  mcs.state = COMPOSE_IDLE;
  mcs.cursor = 0;
  memset(mcs.buffer, 0, sizeof(mcs.buffer));
}

/**
 * @brief Get current compose state for UI rendering.
 */
static inline compose_state_t msg_compose_get_state(void) { return mcs.state; }

/**
 * @brief Get current message text for OLED preview.
 */
static inline const char *msg_compose_get_text(void) { return mcs.buffer; }

/**
 * @brief Get current cursor position.
 */
static inline uint8_t msg_compose_get_cursor(void) { return mcs.cursor; }

#endif /* MSG_COMPOSE_H */
