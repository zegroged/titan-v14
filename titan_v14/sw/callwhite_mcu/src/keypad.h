/**
 * @file keypad.h
 * @brief ★ P1 #20: 4×4 Matrix Keypad Driver with T9 Input
 *
 * GPIO tarama, 20ms debounce, T9 karakter girişi, event queue.
 *
 * Donanım:
 *   ROW (output): PA4-PA7
 *   COL (input, pull-up): PB12-PB15
 *
 * Tuş Haritası:
 *   1(abc) 2(def) 3(ghi)  A(Menü)
 *   4(jkl) 5(mno) 6(pqr)  B(Sil)
 *   7(stu) 8(vwx) 9(yz)   C(Gönder)
 *   *(OK)  0(spc) #       D(Mod)
 */
#ifndef KEYPAD_H
#define KEYPAD_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>


/*============================================================================
 * Constants
 *============================================================================*/
#define KP_ROWS 4
#define KP_COLS 4
#define KP_EVENT_QUEUE 8 /* Max pending key events */

/*============================================================================
 * Key Codes (raw matrix position)
 *============================================================================*/
typedef enum {
  KEY_1 = 0x00,
  KEY_2 = 0x01,
  KEY_3 = 0x02,
  KEY_A = 0x03,
  KEY_4 = 0x10,
  KEY_5 = 0x11,
  KEY_6 = 0x12,
  KEY_B = 0x13,
  KEY_7 = 0x20,
  KEY_8 = 0x21,
  KEY_9 = 0x22,
  KEY_C = 0x23,
  KEY_STAR = 0x30,
  KEY_0 = 0x31,
  KEY_HASH = 0x32,
  KEY_D = 0x33,
  KEY_NONE = 0xFF
} key_code_t;

/* T9 character tables per key */
static const char t9_table[12][5] = {
    /* KEY_1 */ "abc1",
    /* KEY_2 */ "def2",
    /* KEY_3 */ "ghi3",
    /* KEY_4 */ "jkl4",
    /* KEY_5 */ "mno5",
    /* KEY_6 */ "pqr6",
    /* KEY_7 */ "stu7",
    /* KEY_8 */ "vwx8",
    /* KEY_9 */ "yz9",
    /* KEY_STAR */ "*",
    /* KEY_0 */ " 0",
    /* KEY_HASH */ "#",
};

/* Input mode */
typedef enum {
  INPUT_MODE_LOWER,   /* abc */
  INPUT_MODE_UPPER,   /* ABC */
  INPUT_MODE_NUMERIC, /* 123 */
} input_mode_t;

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  /* Debounce */
  key_code_t last_raw;
  uint32_t debounce_tick;
  bool key_pressed;

  /* T9 */
  key_code_t t9_current_key;
  uint8_t t9_index;         /* Current char index in t9_table */
  uint32_t t9_timeout_tick; /* When to confirm character */

  /* Input mode */
  input_mode_t mode;

  /* Event queue (circular) */
  char event_queue[KP_EVENT_QUEUE];
  uint8_t eq_head;
  uint8_t eq_tail;
  uint8_t eq_count;
} keypad_state_t;

static keypad_state_t kp = {.last_raw = KEY_NONE,
                            .debounce_tick = 0,
                            .key_pressed = false,
                            .t9_current_key = KEY_NONE,
                            .t9_index = 0,
                            .t9_timeout_tick = 0,
                            .mode = INPUT_MODE_UPPER,
                            .eq_head = 0,
                            .eq_tail = 0,
                            .eq_count = 0};

/*============================================================================
 * Event Queue
 *============================================================================*/
static inline bool kp_event_push(char c) {
  if (kp.eq_count >= KP_EVENT_QUEUE)
    return false;
  kp.event_queue[kp.eq_head] = c;
  kp.eq_head = (kp.eq_head + 1) % KP_EVENT_QUEUE;
  kp.eq_count++;
  return true;
}

static inline bool kp_event_pop(char *c) {
  if (kp.eq_count == 0)
    return false;
  *c = kp.event_queue[kp.eq_tail];
  kp.eq_tail = (kp.eq_tail + 1) % KP_EVENT_QUEUE;
  kp.eq_count--;
  return true;
}

/*============================================================================
 * GPIO Scanning
 *============================================================================*/

/** @brief Scan the 4×4 matrix. Returns raw key code or KEY_NONE. */
static inline key_code_t kp_scan_matrix(void) {
  const uint16_t row_pins[KP_ROWS] = {PIN_KP_ROW0, PIN_KP_ROW1, PIN_KP_ROW2,
                                      PIN_KP_ROW3};
  const uint16_t col_pins[KP_COLS] = {PIN_KP_COL0, PIN_KP_COL1, PIN_KP_COL2,
                                      PIN_KP_COL3};

  for (uint8_t r = 0; r < KP_ROWS; r++) {
    /* Drive all rows HIGH */
    for (uint8_t i = 0; i < KP_ROWS; i++)
      HAL_GPIO_WritePin(GPIOA, row_pins[i], GPIO_PIN_SET);

    /* Drive current row LOW */
    HAL_GPIO_WritePin(GPIOA, row_pins[r], GPIO_PIN_RESET);

    /* Small settling delay */
    for (volatile int d = 0; d < 10; d++) {
    }

    /* Read columns (active LOW = pressed) */
    for (uint8_t c = 0; c < KP_COLS; c++) {
      if (HAL_GPIO_ReadPin(GPIOB, col_pins[c]) == GPIO_PIN_RESET) {
        /* Restore rows */
        for (uint8_t i = 0; i < KP_ROWS; i++)
          HAL_GPIO_WritePin(GPIOA, row_pins[i], GPIO_PIN_SET);
        return (key_code_t)((r << 4) | c);
      }
    }
  }

  /* Restore rows */
  for (uint8_t i = 0; i < KP_ROWS; i++)
    HAL_GPIO_WritePin(GPIOA, row_pins[i], GPIO_PIN_SET);

  return KEY_NONE;
}

/*============================================================================
 * T9 Character Mapping
 *============================================================================*/
static inline int kp_key_to_t9_index(key_code_t key) {
  switch (key) {
  case KEY_1:
    return 0;
  case KEY_2:
    return 1;
  case KEY_3:
    return 2;
  case KEY_4:
    return 3;
  case KEY_5:
    return 4;
  case KEY_6:
    return 5;
  case KEY_7:
    return 6;
  case KEY_8:
    return 7;
  case KEY_9:
    return 8;
  case KEY_STAR:
    return 9;
  case KEY_0:
    return 10;
  case KEY_HASH:
    return 11;
  default:
    return -1;
  }
}

/*============================================================================
 * Public API
 *============================================================================*/

/** @brief Initialize keypad GPIO (ROW=output, COL=input pull-up). */
static inline void keypad_init(void) {
  GPIO_InitTypeDef gpio = {0};

  __HAL_RCC_GPIOA_CLK_ENABLE();
  __HAL_RCC_GPIOB_CLK_ENABLE();

  /* ROW pins (PA4-PA7): Output Push-Pull */
  gpio.Pin = PIN_KP_ROW0 | PIN_KP_ROW1 | PIN_KP_ROW2 | PIN_KP_ROW3;
  gpio.Mode = GPIO_MODE_OUTPUT_PP;
  gpio.Pull = GPIO_NOPULL;
  gpio.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOA, &gpio);

  /* COL pins (PB12-PB15): Input Pull-Up */
  gpio.Pin = PIN_KP_COL0 | PIN_KP_COL1 | PIN_KP_COL2 | PIN_KP_COL3;
  gpio.Mode = GPIO_MODE_INPUT;
  gpio.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(GPIOB, &gpio);

  /* Set all rows HIGH initially */
  HAL_GPIO_WritePin(GPIOA,
                    PIN_KP_ROW0 | PIN_KP_ROW1 | PIN_KP_ROW2 | PIN_KP_ROW3,
                    GPIO_PIN_SET);
}

/**
 * @brief Poll keypad (call from main loop, ~5ms intervals).
 * @param tick  Current HAL tick (HAL_GetTick())
 *
 * Handles debounce, T9 timeout, and event generation.
 */
static inline void keypad_poll(uint32_t tick) {
  key_code_t raw = kp_scan_matrix();

  /* T9 timeout: if timer expired, confirm current character */
  if (kp.t9_current_key != KEY_NONE && tick >= kp.t9_timeout_tick) {
    int idx = kp_key_to_t9_index(kp.t9_current_key);
    if (idx >= 0) {
      char ch = t9_table[idx][kp.t9_index];
      if (kp.mode == INPUT_MODE_UPPER && ch >= 'a' && ch <= 'z')
        ch -= 32;
      kp_event_push(ch);
    }
    kp.t9_current_key = KEY_NONE;
    kp.t9_index = 0;
  }

  /* Debounce */
  if (raw != kp.last_raw) {
    kp.last_raw = raw;
    kp.debounce_tick = tick;
    return;
  }

  if (tick - kp.debounce_tick < KP_DEBOUNCE_MS)
    return;

  /* Key released */
  if (raw == KEY_NONE) {
    kp.key_pressed = false;
    return;
  }

  /* Key already processed */
  if (kp.key_pressed)
    return;
  kp.key_pressed = true;

  /* Handle special keys */
  switch (raw) {
  case KEY_A:
    kp_event_push('\x01');
    return; /* Menu */
  case KEY_B:
    kp_event_push('\x08');
    return; /* Backspace/Delete */
  case KEY_C:
    kp_event_push('\r');
    return;   /* Send/Enter */
  case KEY_D: /* Mode toggle */
    kp.mode = (input_mode_t)((kp.mode + 1) % 3);
    return;
  default:
    break;
  }

  /* Numeric mode: direct number output */
  if (kp.mode == INPUT_MODE_NUMERIC) {
    int idx = kp_key_to_t9_index(raw);
    if (idx >= 0) {
      const char *tbl = t9_table[idx];
      /* Get the last char (number) in the t9 entry */
      char ch = tbl[0];
      for (int i = 0; tbl[i]; i++)
        ch = tbl[i];
      kp_event_push(ch);
    }
    return;
  }

  /* T9 character cycling */
  int idx = kp_key_to_t9_index(raw);
  if (idx < 0)
    return;

  if (raw == kp.t9_current_key) {
    /* Same key pressed again: cycle to next character */
    kp.t9_index++;
    if (t9_table[idx][kp.t9_index] == '\0')
      kp.t9_index = 0; /* Wrap around */
  } else {
    /* Different key: confirm previous character, start new */
    if (kp.t9_current_key != KEY_NONE) {
      int prev_idx = kp_key_to_t9_index(kp.t9_current_key);
      if (prev_idx >= 0) {
        char ch = t9_table[prev_idx][kp.t9_index];
        if (kp.mode == INPUT_MODE_UPPER && ch >= 'a' && ch <= 'z')
          ch -= 32;
        kp_event_push(ch);
      }
    }
    kp.t9_current_key = raw;
    kp.t9_index = 0;
  }

  kp.t9_timeout_tick = tick + KP_T9_TIMEOUT_MS;
}

#endif /* KEYPAD_H */
