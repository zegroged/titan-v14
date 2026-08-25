/**
 * @file cryo_kill.h
 * @brief ★ P6 #67: Cryo Kill — Cold Boot Attack Savunması
 *
 * MCU dahili sıcaklık sensörü ile anormal soğuma tespiti.
 * Cold boot attack: cihazı dondurarak RAM'deki anahtarları
 * uzun süre koruma → fiziksel okuma.
 *
 * Eşik: <-10°C → emergency wipe (pvd_kill.h ile aynı prosedür)
 *
 * Normal çalışma aralığı: -20°C ~ +85°C (STM32 endüstriyel)
 * Ama <-10°C ortam sıcaklığı normalden çok düşük ve
 * kasıtlı soğutma sinyali olabilir.
 */
#ifndef CRYO_KILL_H
#define CRYO_KILL_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>


/*============================================================================
 * Configuration
 *============================================================================*/
#define CRYO_THRESHOLD_C (-10)      /* Kill threshold (Celsius) */
#define CRYO_CHECK_INTERVAL_MS 5000 /* Check every 5 seconds */
#define CRYO_CONFIRM_COUNT 3        /* 3 consecutive low reads = attack */

/* STM32L4 internal temp sensor calibration (factory values) */
#define TEMP_CAL1_ADDR ((uint16_t *)0x1FFF75A8UL) /* TS_CAL1 @ 30°C */
#define TEMP_CAL2_ADDR ((uint16_t *)0x1FFF75CAUL) /* TS_CAL2 @ 110°C */
#define TEMP_CAL1_TEMP 30
#define TEMP_CAL2_TEMP 110

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  bool initialized;
  int16_t current_temp_c; /* Current temperature */
  uint32_t last_check_tick;
  uint8_t low_temp_count; /* Consecutive low readings */
  bool cryo_detected;     /* Attack confirmed */
} cryo_ctx_t;

static cryo_ctx_t cryo = {.initialized = false,
                          .current_temp_c = 25,
                          .last_check_tick = 0,
                          .low_temp_count = 0,
                          .cryo_detected = false};

/*============================================================================
 * Internal
 *============================================================================*/

/**
 * @brief Read internal temperature sensor via ADC.
 * @param adc_raw  ADC raw value from temperature channel
 * @return Temperature in Celsius
 */
static inline int16_t cryo_read_temp(uint16_t adc_raw) {
  /* Linear interpolation using factory calibration */
  uint16_t cal1 = *TEMP_CAL1_ADDR;
  uint16_t cal2 = *TEMP_CAL2_ADDR;

  if (cal2 == cal1)
    return 25; /* Fallback */

  int32_t temp = TEMP_CAL1_TEMP + ((int32_t)(adc_raw - cal1) *
                                   (TEMP_CAL2_TEMP - TEMP_CAL1_TEMP)) /
                                      (int32_t)(cal2 - cal1);

  return (int16_t)temp;
}

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize cryo kill monitoring.
 */
static inline void cryo_kill_init(void) {
  cryo.initialized = true;
  cryo.last_check_tick = HAL_GetTick();
  cryo.low_temp_count = 0;
  cryo.cryo_detected = false;
}

/**
 * @brief Poll temperature sensor for cold attack.
 * @param adc_raw  Raw ADC reading from temp sensor channel
 * @param tick     Current system tick
 */
static inline void cryo_kill_poll(uint16_t adc_raw, uint32_t tick) {
  if (!cryo.initialized)
    return;
  if (tick - cryo.last_check_tick < CRYO_CHECK_INTERVAL_MS)
    return;

  cryo.last_check_tick = tick;
  cryo.current_temp_c = cryo_read_temp(adc_raw);

  if (cryo.current_temp_c < CRYO_THRESHOLD_C) {
    cryo.low_temp_count++;

    if (cryo.low_temp_count >= CRYO_CONFIRM_COUNT) {
      cryo.cryo_detected = true;
      /* EMERGENCY WIPE — same procedure as PVD kill */
      /* pvd_emergency_wipe() should be called here */
      /* For now: set flag, main loop handles */
    }
  } else {
    cryo.low_temp_count = 0; /* Reset on normal reading */
  }
}

/**
 * @brief Check if cryo attack was detected.
 */
static inline bool cryo_kill_triggered(void) { return cryo.cryo_detected; }

/**
 * @brief Get current MCU temperature (Celsius).
 */
static inline int16_t cryo_get_temp(void) { return cryo.current_temp_c; }

#endif /* CRYO_KILL_H */
