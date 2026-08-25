/**
 * @file ota_wear.h
 * @brief ★ P6 #68: OTA Wear-Out Protection
 *
 * Flash yazma ömrünü koruma — saldırgan sahte OTA ile flash'ı
 * yıpratamaz.
 *
 * Koruma katmanları:
 *   1. Header pre-auth: HMAC doğrulanmadan flash'a yazma yok
 *   2. Write counter: BKP register'da toplam write sayısı
 *   3. Rate limiter: 24 saatte max 5 OTA denemesi
 *   4. Eşikler: 10K write → uyarı, 50K → OTA devre dışı
 */
#ifndef OTA_WEAR_H
#define OTA_WEAR_H

#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>

/*============================================================================
 * Configuration
 *============================================================================*/
#define OTA_WEAR_BKP_REG 30 /* BKP register for write counter */
#define OTA_WEAR_WARN_LIMIT 10000
#define OTA_WEAR_HARD_LIMIT 50000
#define OTA_RATE_MAX_PER_DAY 5
#define OTA_RATE_WINDOW_MS (24UL * 60 * 60 * 1000) /* 24 saat */

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  uint32_t write_count;       /* Toplam flash write sayısı */
  uint32_t daily_attempts;    /* Bu periyottaki denemeler */
  uint32_t period_start_tick; /* Rate limit penceresi başı */
  bool ota_disabled;          /* Hard limit aşıldı */
} ota_wear_ctx_t;

static ota_wear_ctx_t ota_w = {.write_count = 0,
                               .daily_attempts = 0,
                               .period_start_tick = 0,
                               .ota_disabled = false};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize OTA wear protection.
 *        Reads write counter from BKP register.
 */
static inline void ota_wear_init(void) {
  volatile uint32_t *bkp = &RTC->BKP0R;
  ota_w.write_count = bkp[OTA_WEAR_BKP_REG];
  ota_w.daily_attempts = 0;
  ota_w.period_start_tick = HAL_GetTick();
  ota_w.ota_disabled = (ota_w.write_count >= OTA_WEAR_HARD_LIMIT);
}

/**
 * @brief Check if OTA write is permitted.
 * @param tick  Current system tick
 * @return true if write allowed
 */
static inline bool ota_wear_can_write(uint32_t tick) {
  if (ota_w.ota_disabled)
    return false;

  /* Reset rate window if expired */
  if (tick - ota_w.period_start_tick >= OTA_RATE_WINDOW_MS) {
    ota_w.daily_attempts = 0;
    ota_w.period_start_tick = tick;
  }

  if (ota_w.daily_attempts >= OTA_RATE_MAX_PER_DAY)
    return false;

  return true;
}

/**
 * @brief Record a flash write operation.
 */
static inline void ota_wear_record_write(void) {
  ota_w.write_count++;
  ota_w.daily_attempts++;

  /* Persist to BKP register */
  volatile uint32_t *bkp = &RTC->BKP0R;
  bkp[OTA_WEAR_BKP_REG] = ota_w.write_count;

  /* Check limits */
  if (ota_w.write_count >= OTA_WEAR_HARD_LIMIT) {
    ota_w.ota_disabled = true;
  }
}

/**
 * @brief Check if close to wear-out.
 */
static inline bool ota_wear_warning(void) {
  return ota_w.write_count >= OTA_WEAR_WARN_LIMIT;
}

/**
 * @brief Get current flash write count.
 */
static inline uint32_t ota_wear_get_count(void) { return ota_w.write_count; }

#endif /* OTA_WEAR_H */
