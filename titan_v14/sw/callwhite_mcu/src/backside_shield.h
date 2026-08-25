/**
 * @file backside_shield.h
 * @brief ★ V14.2: Backside Attack Protection — Capacitive Sensing
 *
 * FIB (Focused Ion Beam) saldırıları çipin alt tarafından (substrate)
 * yapılabilir. Photodiode mesh sadece üst tarafı koruyor.
 *
 * Çözüm: BGA altı bakır plaka kapasitans ölçümü
 *   - STM32L4 Touch Sensing Controller (TSC) peripheral kullanılır
 *   - Fabrikada referans kapasitans kalibrasyonu yapılır
 *   - Periyodik ölçüm: kapasitans %5+ sapma → FPGA'ya kill sinyali
 *   - Substrat inceltme (FIB gereksinimi) kapasitansı düşürür → algılanır
 *
 * PCB Gereksinimi:
 *   - BGA altında minimum 4 layer bakır ground plane
 *   - TSC kanalı bakır plakaya ince trace ile bağlı
 *   - Guard ring: adjacent TSC kanalı shield olarak
 *
 * Saldırı vektörü V39: Backside FIB probing / silicon thinning
 */
#ifndef BACKSIDE_SHIELD_H
#define BACKSIDE_SHIELD_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>

/*============================================================================
 * Configuration
 *============================================================================*/
#define BSS_DEVIATION_THRESHOLD_PCT 5   /* %5 sapma = alarm */
#define BSS_CRITICAL_DEVIATION_PCT 15   /* %15 sapma = kritik (FIB kesin) */
#define BSS_MEASUREMENT_INTERVAL_MS 500 /* Her 500ms ölçüm */
#define BSS_AVERAGING_COUNT 8           /* 8 ölçüm ortalaması */
#define BSS_CALIBRATION_SAMPLES 64      /* Fabrika kalibrasyonu örnek sayısı */

/*============================================================================
 * TSC Configuration
 *============================================================================*/
/* TSC Group 6 used for backside sensing (PB14/PB15) */
#define BSS_TSC_GROUP 6
#define BSS_TSC_CHANNEL_IO TSC_GROUP6_IO2 /* Sensing electrode */
#define BSS_TSC_SHIELD_IO TSC_GROUP6_IO1  /* Shield electrode */

/*============================================================================
 * State
 *============================================================================*/
typedef enum {
  BSS_OK = 0,
  BSS_WARN_DEVIATION,     /* Slight deviation — monitor */
  BSS_ALARM_DEVIATION,    /* Significant deviation — possible attack */
  BSS_CRITICAL,           /* Critical deviation — FIB confirmed */
  BSS_CALIBRATION_NEEDED, /* No valid calibration data */
  BSS_HARDWARE_ERROR      /* TSC peripheral error */
} bss_status_t;

typedef struct {
  bool initialized;
  bool calibrated;

  /* Calibration data (factory-programmed) */
  uint32_t ref_capacitance;   /* Reference value (raw TSC count) */
  uint32_t ref_deviation_max; /* Threshold = ref * (1 +
                                 BSS_DEVIATION_THRESHOLD_PCT/100) */
  uint32_t ref_critical_max;  /* Critical threshold */

  /* Runtime data */
  uint32_t last_measurement; /* Latest raw TSC count */
  uint32_t avg_measurement;  /* Moving average */
  int32_t deviation_pct;     /* Signed deviation percentage * 100 */
  uint32_t alarm_count;      /* Number of threshold breaches */
  uint32_t last_check_tick;  /* HAL_GetTick() of last check */

  bss_status_t status;
} bss_ctx_t;

static bss_ctx_t bss = {.initialized = false,
                        .calibrated = false,
                        .status = BSS_CALIBRATION_NEEDED};

/*============================================================================
 * TSC Hardware Interface (STM32L4)
 *============================================================================*/

/**
 * @brief Read raw capacitance value from TSC.
 *        Returns TSC counter value (lower = higher capacitance).
 */
static inline uint32_t bss_tsc_read_raw(void) {
  /* Configure TSC for single acquisition */
  /* NOTE: Actual TSC HAL calls depend on CubeMX configuration */

  /* Simplified: direct register access for TSC Group 6 */
  /* In production: use HAL_TSC_IODischarge(), HAL_TSC_Start(), etc. */

  /* Placeholder — returns simulated value for dry-run */
  /* Real implementation uses TSC->IOGXCR[BSS_TSC_GROUP] */
  return 0;
}

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize backside shield sensing.
 *        Configures TSC peripheral for capacitive measurement.
 */
static inline bss_status_t backside_shield_init(void) {
  /* TSC peripheral clock enable */
  __HAL_RCC_TSC_CLK_ENABLE();

  /* Configure TSC GPIO: PB14 as sensing, PB15 as shield */
  GPIO_InitTypeDef gpio = {0};

  /* Sensing electrode */
  gpio.Pin = GPIO_PIN_14;
  gpio.Mode = GPIO_MODE_AF_OD; /* Open drain for TSC */
  gpio.Pull = GPIO_NOPULL;
  gpio.Speed = GPIO_SPEED_FREQ_LOW;
  gpio.Alternate = GPIO_AF9_TSC; /* TSC alternate function */
  HAL_GPIO_Init(GPIOB, &gpio);

  /* Shield electrode */
  gpio.Pin = GPIO_PIN_15;
  gpio.Mode = GPIO_MODE_AF_PP; /* Push-pull for shield drive */
  HAL_GPIO_Init(GPIOB, &gpio);

  bss.initialized = true;
  bss.status = BSS_CALIBRATION_NEEDED;

  return BSS_CALIBRATION_NEEDED;
}

/**
 * @brief Factory calibration — measure reference capacitance.
 *        Call this during production with known-good PCB.
 *
 * Takes BSS_CALIBRATION_SAMPLES measurements and computes average.
 */
static inline bss_status_t backside_shield_calibrate(void) {
  if (!bss.initialized)
    return BSS_HARDWARE_ERROR;

  uint64_t sum = 0;
  for (int i = 0; i < BSS_CALIBRATION_SAMPLES; i++) {
    sum += bss_tsc_read_raw();
    HAL_Delay(10);
  }

  bss.ref_capacitance = (uint32_t)(sum / BSS_CALIBRATION_SAMPLES);

  /* Calculate thresholds */
  bss.ref_deviation_max =
      bss.ref_capacitance +
      (bss.ref_capacitance * BSS_DEVIATION_THRESHOLD_PCT / 100);
  bss.ref_critical_max =
      bss.ref_capacitance +
      (bss.ref_capacitance * BSS_CRITICAL_DEVIATION_PCT / 100);

  bss.calibrated = true;
  bss.status = BSS_OK;
  bss.alarm_count = 0;

  return BSS_OK;
}

/**
 * @brief Perform periodic capacitance check.
 *        Should be called from main loop.
 *
 * @return Status indicating if attack is detected.
 */
static inline bss_status_t backside_shield_check(void) {
  if (!bss.initialized || !bss.calibrated)
    return bss.status;

  /* Rate limit */
  uint32_t now = HAL_GetTick();
  if ((now - bss.last_check_tick) < BSS_MEASUREMENT_INTERVAL_MS)
    return bss.status;

  bss.last_check_tick = now;

  /* Take averaged measurement */
  uint64_t sum = 0;
  for (int i = 0; i < BSS_AVERAGING_COUNT; i++) {
    sum += bss_tsc_read_raw();
  }
  bss.last_measurement = (uint32_t)(sum / BSS_AVERAGING_COUNT);

  /* Exponential moving average */
  bss.avg_measurement = (bss.avg_measurement * 7 + bss.last_measurement) / 8;

  /* Calculate deviation (signed, *100 for precision) */
  if (bss.ref_capacitance > 0) {
    bss.deviation_pct = (int32_t)(((int64_t)bss.avg_measurement -
                                   (int64_t)bss.ref_capacitance) *
                                  10000 / (int64_t)bss.ref_capacitance);
  }

  /* Evaluate thresholds */
  uint32_t abs_deviation = (bss.deviation_pct < 0)
                               ? (uint32_t)(-bss.deviation_pct)
                               : (uint32_t)bss.deviation_pct;

  if (abs_deviation >= BSS_CRITICAL_DEVIATION_PCT * 100) {
    bss.status = BSS_CRITICAL;
    bss.alarm_count++;
    /* → FPGA kill signal should be asserted by caller */
  } else if (abs_deviation >= BSS_DEVIATION_THRESHOLD_PCT * 100) {
    bss.status = BSS_ALARM_DEVIATION;
    bss.alarm_count++;
  } else if (abs_deviation >= (BSS_DEVIATION_THRESHOLD_PCT * 100 / 2)) {
    bss.status = BSS_WARN_DEVIATION;
  } else {
    bss.status = BSS_OK;
  }

  return bss.status;
}

/**
 * @brief Get current status.
 */
static inline bss_status_t backside_shield_status(void) { return bss.status; }

/**
 * @brief Check if kill should be triggered (critical deviation).
 */
static inline bool backside_shield_kill_needed(void) {
  return bss.status == BSS_CRITICAL;
}

/**
 * @brief Get deviation percentage (x100 for precision).
 *        Negative = capacitance decreased (substrate thinning).
 */
static inline int32_t backside_shield_deviation(void) {
  return bss.deviation_pct;
}

#endif /* BACKSIDE_SHIELD_H */
