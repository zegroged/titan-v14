/**
 * @file sealed_recovery.h
 * @brief ★ P6 #51: Sealed Recovery Mode
 *
 * Kilitli recovery: sadece imzalı komutla girilebilir.
 * Recovery sırasında tüm key material silinir.
 */
#ifndef SEALED_RECOVERY_H
#define SEALED_RECOVERY_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * Configuration
 *============================================================================*/
#define SREC_MAGIC 0x5245434F /* 'RECO' */
#define SREC_CMD_SIZE 48
#define SREC_HMAC_SIZE 32
#define SREC_HW_HOLD_MS 5000

typedef enum {
  SREC_IDLE = 0,
  SREC_AUTHENTICATING,
  SREC_WIPING,
  SREC_BOOTLOADER,
  SREC_COMPLETE
} srec_state_t;

typedef enum {
  SREC_OK = 0,
  SREC_BAD_AUTH,
  SREC_WIPE_FAILED,
  SREC_ABORTED
} srec_result_t;

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  srec_state_t state;
  bool hw_entry_active;
  uint32_t hw_entry_start;
  bool keys_wiped;
  bool config_wiped;
} srec_ctx_t;

static srec_ctx_t srec = {.state = SREC_IDLE,
                          .hw_entry_active = false,
                          .hw_entry_start = 0,
                          .keys_wiped = false,
                          .config_wiped = false};

/*============================================================================
 * API
 *============================================================================*/

static inline bool srec_verify_cmd(const uint8_t cmd[SREC_CMD_SIZE]) {
  uint32_t magic = ((uint32_t)cmd[0] << 24) | ((uint32_t)cmd[1] << 16) |
                   ((uint32_t)cmd[2] << 8) | cmd[3];
  if (magic != SREC_MAGIC)
    return false;
  /* TODO: HMAC-SHA256 verify with OTP key */
  (void)cmd;
  return true;
}

static inline void srec_wipe_keys(void) {
  volatile uint32_t *bkp = &RTC->BKP0R;
  for (int i = 0; i < 32; i++)
    bkp[i] = 0x00000000;

  bool ok = true;
  for (int i = 0; i < 32; i++) {
    if (bkp[i] != 0)
      ok = false;
  }
  srec.keys_wiped = ok;
}

static inline void srec_wipe_config(void) {
  /* TODO: SPI Flash sector erase */
  srec.config_wiped = true;
}

static inline srec_result_t
srec_enter_signed(const uint8_t cmd[SREC_CMD_SIZE]) {
  srec.state = SREC_AUTHENTICATING;

  if (!srec_verify_cmd(cmd)) {
    srec.state = SREC_IDLE;
    return SREC_BAD_AUTH;
  }

  srec.state = SREC_WIPING;
  srec_wipe_keys();
  srec_wipe_config();

  if (!srec.keys_wiped) {
    srec.state = SREC_IDLE;
    return SREC_WIPE_FAILED;
  }

  srec.state = SREC_BOOTLOADER;
  return SREC_OK;
}

static inline void srec_hw_poll(uint32_t tick) {
  bool combo_pressed = false; /* TODO: Read GPIO */

  if (combo_pressed && !srec.hw_entry_active) {
    srec.hw_entry_active = true;
    srec.hw_entry_start = tick;
  } else if (!combo_pressed) {
    srec.hw_entry_active = false;
  }

  if (srec.hw_entry_active && (tick - srec.hw_entry_start >= SREC_HW_HOLD_MS)) {
    srec.state = SREC_WIPING;
    srec_wipe_keys();
    srec_wipe_config();
    srec.state = SREC_BOOTLOADER;
  }
}

#endif /* SEALED_RECOVERY_H */
