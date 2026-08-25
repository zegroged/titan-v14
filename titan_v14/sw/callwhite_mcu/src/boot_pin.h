/**
 * @file boot_pin.h
 * @brief ★ P3 #33: Boot PIN/Şifre Sistemi + #34: Duress PIN
 *
 * Boot'ta PIN zorunlu. Yanlış girişte kademeli lockout,
 * 10 yanlışta FPGA zeroize. Duress PIN girilirse sahte status ekranı
 * gösterilir ve arka planda sessiz zeroize yapılır.
 *
 * PIN depolama: SHA-256 hash BKP register'da (plaintext yok).
 * Bağımlılık: sha256.h, config.h
 */
#ifndef BOOT_PIN_H
#define BOOT_PIN_H

#include "sha256.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/*============================================================================
 * Constants
 *============================================================================*/
#define PIN_MIN_LENGTH 4
#define PIN_MAX_LENGTH 8
#define PIN_HASH_SIZE 32         /* SHA-256 = 32 bytes */
#define PIN_MAX_ATTEMPTS 10      /* 10 yanlış = zeroize */
#define PIN_LOCKOUT_TIER1 3      /* 3 yanlış → 30s lockout */
#define PIN_LOCKOUT_TIER2 5      /* 5 yanlış → 5min lockout */
#define PIN_LOCKOUT_MS_T1 30000  /* 30 saniye */
#define PIN_LOCKOUT_MS_T2 300000 /* 5 dakika */

/*============================================================================
 * Types
 *============================================================================*/
typedef enum {
  PIN_OK,     /* Doğru PIN — boot devam */
  PIN_WRONG,  /* Yanlış PIN — sayaç artır */
  PIN_DURESS, /* Duress PIN — sahte ekran + sessiz kill */
  PIN_LOCKED, /* Lockout süresi aktif — giriş engelli */
  PIN_ZEROIZE /* 10 yanlış — cihaz imha */
} pin_result_t;

typedef struct {
  uint8_t pin_hash[PIN_HASH_SIZE];    /* SHA-256 of real PIN */
  uint8_t duress_hash[PIN_HASH_SIZE]; /* SHA-256 of duress PIN */
  uint8_t fail_count;                 /* Persistent in BKP register */
  uint32_t lockout_until;             /* Tick when lockout expires */
  bool pin_set;                       /* Has a PIN been configured? */
  bool duress_set;                    /* Has a duress PIN been configured? */
  bool authenticated;                 /* Boot PIN verified OK */
} boot_pin_state_t;

static boot_pin_state_t bps = {.fail_count = 0,
                               .lockout_until = 0,
                               .pin_set = false,
                               .duress_set = false,
                               .authenticated = false};

/*============================================================================
 * Internal: Real SHA-256 PIN hashing (via sha256.h)
 *============================================================================*/
static inline void pin_sha256(const char *input, uint8_t len,
                              uint8_t out[PIN_HASH_SIZE]) {
  sha256((const uint8_t *)input, (uint32_t)len, out);
}

/*============================================================================
 * Internal: Constant-time comparison (side-channel resistant)
 *============================================================================*/
static inline bool pin_ct_compare(const uint8_t *a, const uint8_t *b,
                                  uint8_t len) {
  volatile uint8_t diff = 0;
  for (uint8_t i = 0; i < len; i++) {
    diff |= a[i] ^ b[i];
  }
  return (diff == 0);
}

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize boot PIN subsystem.
 *        Reads fail_count from BKP register.
 *        If fail_count >= PIN_MAX_ATTEMPTS → immediate zeroize.
 */
static inline void boot_pin_init(void) {
  bps.fail_count = (uint8_t)(RTC->BKP0R & 0xFF);
  bps.authenticated = false;

  if (bps.fail_count >= PIN_MAX_ATTEMPTS) {
    GPIOC->BSRR = (1U << 13);
    while (1) {
      __NOP();
    }
  }

  uint32_t first_word = RTC->BKP1R;
  bps.pin_set = (first_word != 0x00000000 && first_word != 0xFFFFFFFF);

  if (bps.pin_set) {
    for (int i = 0; i < 8; i++) {
      uint32_t val = (&RTC->BKP1R)[i];
      bps.pin_hash[i * 4 + 0] = (uint8_t)(val >> 24);
      bps.pin_hash[i * 4 + 1] = (uint8_t)(val >> 16);
      bps.pin_hash[i * 4 + 2] = (uint8_t)(val >> 8);
      bps.pin_hash[i * 4 + 3] = (uint8_t)(val);
    }

    uint32_t duress_first = RTC->BKP9R;
    bps.duress_set = (duress_first != 0x00000000 && duress_first != 0xFFFFFFFF);
    if (bps.duress_set) {
      for (int i = 0; i < 8; i++) {
        uint32_t val = (&RTC->BKP9R)[i];
        bps.duress_hash[i * 4 + 0] = (uint8_t)(val >> 24);
        bps.duress_hash[i * 4 + 1] = (uint8_t)(val >> 16);
        bps.duress_hash[i * 4 + 2] = (uint8_t)(val >> 8);
        bps.duress_hash[i * 4 + 3] = (uint8_t)(val);
      }
    }
  }
}

static inline bool boot_pin_is_locked(uint32_t tick) {
  if (bps.lockout_until == 0)
    return false;
  if (tick >= bps.lockout_until) {
    bps.lockout_until = 0;
    return false;
  }
  return true;
}

static inline pin_result_t boot_pin_verify(const char *pin, uint8_t len) {
  if (len < PIN_MIN_LENGTH || len > PIN_MAX_LENGTH) {
    return PIN_WRONG;
  }

  uint8_t entered_hash[PIN_HASH_SIZE];
  pin_sha256(pin, len, entered_hash);

  /* ★ P3 #34: Check duress PIN FIRST (constant-time) */
  if (bps.duress_set) {
    if (pin_ct_compare(entered_hash, bps.duress_hash, PIN_HASH_SIZE)) {
      bps.authenticated = false;
      memset(entered_hash, 0, PIN_HASH_SIZE);
      return PIN_DURESS;
    }
  }

  /* Check real PIN (constant-time) */
  if (pin_ct_compare(entered_hash, bps.pin_hash, PIN_HASH_SIZE)) {
    bps.fail_count = 0;
    RTC->BKP0R = 0;
    bps.authenticated = true;
    memset(entered_hash, 0, PIN_HASH_SIZE);
    return PIN_OK;
  }

  /* Wrong PIN */
  memset(entered_hash, 0, PIN_HASH_SIZE);
  bps.fail_count++;
  RTC->BKP0R = bps.fail_count;

  if (bps.fail_count >= PIN_MAX_ATTEMPTS) {
    GPIOC->BSRR = (1U << 13);
    while (1) {
      __NOP();
    }
    return PIN_ZEROIZE;
  }

  uint32_t tick = HAL_GetTick();
  if (bps.fail_count >= PIN_LOCKOUT_TIER2) {
    bps.lockout_until = tick + PIN_LOCKOUT_MS_T2;
  } else if (bps.fail_count >= PIN_LOCKOUT_TIER1) {
    bps.lockout_until = tick + PIN_LOCKOUT_MS_T1;
  }

  return PIN_WRONG;
}

static inline bool boot_pin_set(const char *pin, uint8_t len,
                                const char *current) {
  if (len < PIN_MIN_LENGTH || len > PIN_MAX_LENGTH)
    return false;

  if (bps.pin_set && current != NULL) {
    uint8_t cur_hash[PIN_HASH_SIZE];
    pin_sha256(current, (uint8_t)strlen(current), cur_hash);
    if (!pin_ct_compare(cur_hash, bps.pin_hash, PIN_HASH_SIZE)) {
      memset(cur_hash, 0, PIN_HASH_SIZE);
      return false;
    }
    memset(cur_hash, 0, PIN_HASH_SIZE);
  }

  pin_sha256(pin, len, bps.pin_hash);
  for (int i = 0; i < 8; i++) {
    uint32_t val = ((uint32_t)bps.pin_hash[i * 4 + 0] << 24) |
                   ((uint32_t)bps.pin_hash[i * 4 + 1] << 16) |
                   ((uint32_t)bps.pin_hash[i * 4 + 2] << 8) |
                   ((uint32_t)bps.pin_hash[i * 4 + 3]);
    (&RTC->BKP1R)[i] = val;
  }
  bps.pin_set = true;
  bps.fail_count = 0;
  RTC->BKP0R = 0;
  return true;
}

static inline bool boot_pin_set_duress(const char *pin, uint8_t len) {
  if (len < PIN_MIN_LENGTH || len > PIN_MAX_LENGTH)
    return false;
  if (!bps.pin_set)
    return false;

  uint8_t candidate[PIN_HASH_SIZE];
  pin_sha256(pin, len, candidate);

  if (pin_ct_compare(candidate, bps.pin_hash, PIN_HASH_SIZE)) {
    memset(candidate, 0, PIN_HASH_SIZE);
    return false;
  }

  memcpy(bps.duress_hash, candidate, PIN_HASH_SIZE);
  memset(candidate, 0, PIN_HASH_SIZE);

  for (int i = 0; i < 8; i++) {
    uint32_t val = ((uint32_t)bps.duress_hash[i * 4 + 0] << 24) |
                   ((uint32_t)bps.duress_hash[i * 4 + 1] << 16) |
                   ((uint32_t)bps.duress_hash[i * 4 + 2] << 8) |
                   ((uint32_t)bps.duress_hash[i * 4 + 3]);
    (&RTC->BKP9R)[i] = val;
  }
  bps.duress_set = true;
  return true;
}

#endif /* BOOT_PIN_H */
