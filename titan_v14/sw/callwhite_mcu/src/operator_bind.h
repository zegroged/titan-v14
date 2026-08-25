/**
 * @file operator_bind.h
 * @brief ★ P3 #37: Operatör Bağlama (Operator Binding)
 *
 * Cihaz ilk kullanımda operatöre kilitlenir. Başka kişi kullanamaz.
 *
 * Mekanizma:
 *   1. İlk boot: Operatör PIN + MCU CPUID + UUID → bind_fingerprint
 *   2. Hash OTP/BKP'ye yazılır (geri dönüşsüz)
 *   3. Her boot'ta: PIN hash + CPUID + UUID → karşılaştırma
 *   4. Mismatch → Zeroize
 *
 * Transfer: Mevcut operatör PIN + master key ile (2-of-2 auth).
 *
 * Bağımlılık: sha256.h, boot_pin.h, config.h
 */
#ifndef OPERATOR_BIND_H
#define OPERATOR_BIND_H

#include "sha256.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/*============================================================================
 * Constants
 *============================================================================*/
#define BIND_HASH_SIZE 32       /* SHA-256 */
#define BIND_MASTER_KEY_SIZE 16 /* Master key for transfer */

/*============================================================================
 * Types
 *============================================================================*/
typedef enum {
  BIND_OK,       /* Fingerprint eşleşti — devam */
  BIND_MISMATCH, /* Fingerprint uyuşmuyor — zeroize */
  BIND_VIRGIN    /* İlk kullanım — binding yapılacak */
} bind_result_t;

typedef struct {
  uint8_t bind_hash[BIND_HASH_SIZE]; /* Stored fingerprint */
  bool bound;                        /* Binding yapılmış mı */
  uint32_t cpuid[3];                 /* STM32 96-bit unique ID */
} operator_bind_state_t;

static operator_bind_state_t obs = {.bound = false};

/*============================================================================
 * Internal: Read STM32 96-bit Unique Device ID
 *============================================================================*/
static inline void bind_read_cpuid(uint32_t out[3]) {
  out[0] = *(volatile uint32_t *)(0x1FFF7590U);
  out[1] = *(volatile uint32_t *)(0x1FFF7594U);
  out[2] = *(volatile uint32_t *)(0x1FFF7598U);
}

/*============================================================================
 * Internal: Compute binding fingerprint
 *   fingerprint = SHA-256(pin_hash || CPUID_96bit)
 *============================================================================*/
static inline void bind_compute_fingerprint(const uint8_t pin_hash[32],
                                            const uint32_t cpuid[3],
                                            uint8_t out[BIND_HASH_SIZE]) {
  uint8_t material[44];
  memcpy(material, pin_hash, 32);
  memcpy(material + 32, cpuid, 12);

  /* Real SHA-256 */
  sha256(material, 44, out);
  memset(material, 0, sizeof(material));
}

/*============================================================================
 * Internal: Constant-time comparison
 *============================================================================*/
static inline bool bind_ct_compare(const uint8_t *a, const uint8_t *b,
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

static inline void operator_bind_init(void) {
  bind_read_cpuid(obs.cpuid);

  uint32_t first_word = RTC->BKP17R;
  obs.bound = (first_word != 0x00000000 && first_word != 0xFFFFFFFF);

  if (obs.bound) {
    for (int i = 0; i < 8; i++) {
      uint32_t val = (&RTC->BKP17R)[i];
      obs.bind_hash[i * 4 + 0] = (uint8_t)(val >> 24);
      obs.bind_hash[i * 4 + 1] = (uint8_t)(val >> 16);
      obs.bind_hash[i * 4 + 2] = (uint8_t)(val >> 8);
      obs.bind_hash[i * 4 + 3] = (uint8_t)(val);
    }
  }
}

static inline bind_result_t operator_bind_check(const uint8_t pin_hash[32]) {
  if (!obs.bound) {
    return BIND_VIRGIN;
  }

  uint8_t current[BIND_HASH_SIZE];
  bind_compute_fingerprint(pin_hash, obs.cpuid, current);

  bool match = bind_ct_compare(current, obs.bind_hash, BIND_HASH_SIZE);
  memset(current, 0, BIND_HASH_SIZE);

  return match ? BIND_OK : BIND_MISMATCH;
}

static inline bool operator_bind_set(const uint8_t pin_hash[32]) {
  uint8_t fp[BIND_HASH_SIZE];
  bind_compute_fingerprint(pin_hash, obs.cpuid, fp);

  for (int i = 0; i < 8; i++) {
    uint32_t val = ((uint32_t)fp[i * 4 + 0] << 24) |
                   ((uint32_t)fp[i * 4 + 1] << 16) |
                   ((uint32_t)fp[i * 4 + 2] << 8) | ((uint32_t)fp[i * 4 + 3]);
    (&RTC->BKP17R)[i] = val;
  }

  memcpy(obs.bind_hash, fp, BIND_HASH_SIZE);
  memset(fp, 0, BIND_HASH_SIZE);
  obs.bound = true;
  return true;
}

static inline bool
operator_bind_transfer(const uint8_t old_pin_hash[32],
                       const uint8_t new_pin_hash[32],
                       const uint8_t master_key[BIND_MASTER_KEY_SIZE],
                       const uint8_t expected_key[BIND_MASTER_KEY_SIZE]) {

  if (operator_bind_check(old_pin_hash) != BIND_OK) {
    return false;
  }

  if (!bind_ct_compare(master_key, expected_key, BIND_MASTER_KEY_SIZE)) {
    return false;
  }

  return operator_bind_set(new_pin_hash);
}

#endif /* OPERATOR_BIND_H */
