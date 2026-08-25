/**
 * @file cpuid_verify.h
 * @brief ★ P1 #14: CPUID Hardware Verification
 *
 * Boot sırasında STM32 DBGMCU_IDCODE ve 96-bit Unique ID doğrular.
 * Beklenen değer OTP veya config'den okunur.
 * Uyumsuzluk → boot reddi + kill tetikleme.
 *
 * Saldırı vektörü V35: Sahte çip (trojan/counterfeit) tespiti.
 */
#ifndef CPUID_VERIFY_H
#define CPUID_VERIFY_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>


/*============================================================================
 * STM32L476 Specific Addresses
 *============================================================================*/
#define STM32_DBGMCU_IDCODE_ADDR 0xE0042000UL
#define STM32_UID_BASE_ADDR 0x1FFF7590UL /* 96-bit Unique Device ID */

/* Expected IDCODE for STM32L476xx (Rev Y) */
#define EXPECTED_IDCODE 0x10076415UL
#define IDCODE_DEVID_MASK 0x00000FFFUL /* Bits[11:0] = DEV_ID */
#define EXPECTED_DEVID 0x0415UL        /* STM32L47x/L48x */

/*============================================================================
 * CPUID Verification Result
 *============================================================================*/
typedef enum {
  CPUID_OK = 0x00,
  CPUID_DEVID_FAIL = 0x01, /* DEV_ID mismatch — wrong MCU family */
  CPUID_UID_FAIL = 0x02,   /* UID mismatch — replaced/counterfeit */
  CPUID_NOT_CHECKED = 0xFF
} cpuid_result_t;

/*============================================================================
 * Stored UID (set during provisioning, zero = skip UID check)
 *============================================================================*/
static const uint32_t expected_uid[3] = {0, 0, 0}; /* TODO: Per-device OTP */

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Verify MCU identity at boot.
 *
 * Checks:
 *   1. DBGMCU_IDCODE DEV_ID field matches STM32L476
 *   2. If expected_uid is non-zero, verify 96-bit UID match
 *
 * @return cpuid_result_t — CPUID_OK if all checks pass
 */
static inline cpuid_result_t cpuid_verify(void) {
  /* Step 1: Read DBGMCU IDCODE */
  volatile uint32_t idcode = *(volatile uint32_t *)STM32_DBGMCU_IDCODE_ADDR;
  uint32_t dev_id = idcode & IDCODE_DEVID_MASK;

  if (dev_id != EXPECTED_DEVID) {
    /* Wrong MCU family — counterfeit or wrong chip */
    return CPUID_DEVID_FAIL;
  }

  /* Step 2: Read 96-bit Unique ID */
  volatile uint32_t *uid = (volatile uint32_t *)STM32_UID_BASE_ADDR;
  uint32_t uid0 = uid[0];
  uint32_t uid1 = uid[1];
  uint32_t uid2 = uid[2];

  /* Skip UID check if expected is all-zero (not provisioned yet) */
  if (expected_uid[0] == 0 && expected_uid[1] == 0 && expected_uid[2] == 0) {
    return CPUID_OK; /* UID not provisioned — skip */
  }

  /* Verify UID match */
  if (uid0 != expected_uid[0] || uid1 != expected_uid[1] ||
      uid2 != expected_uid[2]) {
    return CPUID_UID_FAIL;
  }

  return CPUID_OK;
}

/**
 * @brief Initialize CPUID verification.
 *        Called very early in boot, after tamper_init().
 *        On failure: triggers FPGA kill signal and halts.
 */
static inline void cpuid_verify_init(void) {
#if SECURITY_BOOT_CPUID_CHECK
  cpuid_result_t result = cpuid_verify();

  if (result != CPUID_OK) {
    /* ★ CRITICAL: Hardware mismatch detected
     *   - Assert FPGA kill pin
     *   - Infinite halt (no recovery possible)
     */
    HAL_GPIO_WritePin(GPIOC, PIN_FPGA_KILL, GPIO_PIN_SET);

    __disable_irq();
    while (1) { /* DEAD — counterfeit MCU detected */
    }
  }
#endif
}

#endif /* CPUID_VERIFY_H */
