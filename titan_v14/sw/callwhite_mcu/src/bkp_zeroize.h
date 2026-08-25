/**
 * @file bkp_zeroize.h
 * @brief ★ P6 #65: BKP Hardware Zeroization
 *
 * RTC Backup Register'larını donanımsal sıfırlama.
 *
 * Özellikler:
 *   - Tamper pin ile otomatik tetikleme
 *   - Write-back verify (yaz + geri oku + kontrol)
 *   - Triple-write pattern (0x00, 0xFF, 0x00) for SRAM remnance
 *   - ISR-safe (interrupt context'te çalışabilir)
 */
#ifndef BKP_ZEROIZE_H
#define BKP_ZEROIZE_H

#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>

/*============================================================================
 * Configuration
 *============================================================================*/
#define BKP_REG_COUNT 32 /* STM32L476 has 32 backup registers */

typedef enum {
  ZERO_OK = 0,
  ZERO_VERIFY_FAIL, /* Write-back verify failed */
  ZERO_NOT_INITIALIZED
} zeroize_result_t;

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  bool initialized;
  uint32_t zeroize_count; /* How many times zeroized */
  bool last_verify_ok;    /* Last zeroize verified clean */
} bkp_zero_ctx_t;

static bkp_zero_ctx_t bkp_z = {
    .initialized = false, .zeroize_count = 0, .last_verify_ok = false};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize BKP zeroization.
 */
static inline void bkp_zeroize_init(void) {
  bkp_z.initialized = true;
  bkp_z.zeroize_count = 0;
  bkp_z.last_verify_ok = false;
}

/**
 * @brief Zeroize all BKP registers with triple-write verify.
 *
 * Pattern: 0x00000000 → 0xFFFFFFFF → 0x00000000
 * This defeats SRAM data remnance attacks.
 *
 * @return ZERO_OK if all registers verified clean
 */
static inline zeroize_result_t bkp_zeroize_all(void) {
  if (!bkp_z.initialized)
    return ZERO_NOT_INITIALIZED;

  volatile uint32_t *bkp = &RTC->BKP0R;

  /* Pass 1: Clear all */
  for (int i = 0; i < BKP_REG_COUNT; i++) {
    bkp[i] = 0x00000000;
  }

  /* Pass 2: Write all-ones (destroy remnance patterns) */
  for (int i = 0; i < BKP_REG_COUNT; i++) {
    bkp[i] = 0xFFFFFFFF;
  }

  /* Pass 3: Final clear */
  for (int i = 0; i < BKP_REG_COUNT; i++) {
    bkp[i] = 0x00000000;
  }

  /* Verify: read back and check all zero */
  bool verify_ok = true;
  for (int i = 0; i < BKP_REG_COUNT; i++) {
    if (bkp[i] != 0x00000000) {
      verify_ok = false;
    }
  }

  bkp_z.last_verify_ok = verify_ok;
  bkp_z.zeroize_count++;

  return verify_ok ? ZERO_OK : ZERO_VERIFY_FAIL;
}

/**
 * @brief Zeroize a single BKP register with verify.
 * @param reg_index  Register index (0..31)
 */
static inline zeroize_result_t bkp_zeroize_single(uint8_t reg_index) {
  if (reg_index >= BKP_REG_COUNT)
    return ZERO_VERIFY_FAIL;

  volatile uint32_t *reg = (&RTC->BKP0R) + reg_index;

  *reg = 0x00000000;
  *reg = 0xFFFFFFFF;
  *reg = 0x00000000;

  return (*reg == 0x00000000) ? ZERO_OK : ZERO_VERIFY_FAIL;
}

/**
 * @brief Check if BKP registers are clean (all zero).
 */
static inline bool bkp_is_clean(void) {
  volatile uint32_t *bkp = &RTC->BKP0R;
  for (int i = 0; i < BKP_REG_COUNT; i++) {
    if (bkp[i] != 0x00000000)
      return false;
  }
  return true;
}

/**
 * @brief Tamper interrupt handler — auto-zeroize.
 *        Call from TAMP_STAMP_IRQHandler.
 */
static inline void bkp_tamper_irq(void) { bkp_zeroize_all(); }

#endif /* BKP_ZEROIZE_H */
