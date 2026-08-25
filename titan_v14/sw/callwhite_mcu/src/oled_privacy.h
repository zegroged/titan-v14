/**
 * @file oled_privacy.h
 * @brief ★ P6 #62: OLED Privacy Filter
 *
 * Shoulder surfing koruması — OLED ekranı yan bakışa karşı koru.
 *
 * Özellikler:
 *   - Parlaklık azaltma (contrast düşürme)
 *   - İnaktivite timeout sonrası otomatik dim
 *   - Gizlilik seviyesi: 0 (kapalı), 1 (hafif), 2 (güçlü), 3 (ultra)
 *   - Düğme ile seviye geçişi
 *
 * oled_ssd1306.h üzerine inşa edilir.
 */
#ifndef OLED_PRIVACY_H
#define OLED_PRIVACY_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>


/*============================================================================
 * Configuration
 *============================================================================*/
#define PRIVACY_LEVELS 4             /* 0-3 */
#define PRIVACY_DIM_TIMEOUT_MS 15000 /* 15s inaktivite → dim */
#define PRIVACY_OFF_TIMEOUT_MS 60000 /* 60s inaktivite → ekran kapalı */

/* Contrast values per privacy level */
static const uint8_t privacy_contrast[PRIVACY_LEVELS] = {
    0xCF, /* Level 0: Normal (207/255) */
    0x7F, /* Level 1: Hafif dim (127/255) */
    0x3F, /* Level 2: Güçlü dim (63/255) */
    0x0F  /* Level 3: Ultra dim (15/255) — sadece karanlıkta okunur */
};

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  uint8_t level;               /* Current privacy level (0-3) */
  uint32_t last_activity_tick; /* Last user interaction */
  bool dimmed;                 /* Currently dimmed by timeout */
  bool screen_off;             /* Screen off by timeout */
} oled_privacy_ctx_t;

static oled_privacy_ctx_t priv = {
    .level = 0, .last_activity_tick = 0, .dimmed = false, .screen_off = false};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize privacy filter.
 * @param initial_level  Starting privacy level (0-3)
 */
static inline void oled_privacy_init(uint8_t initial_level) {
  if (initial_level >= PRIVACY_LEVELS)
    initial_level = 0;
  priv.level = initial_level;
  priv.last_activity_tick = HAL_GetTick();
  priv.dimmed = false;
  priv.screen_off = false;
}

/**
 * @brief Set privacy level.
 * @param level  0=normal, 1=light, 2=strong, 3=ultra
 * @return Contrast value to apply via oled_set_contrast()
 */
static inline uint8_t oled_privacy_set_level(uint8_t level) {
  if (level >= PRIVACY_LEVELS)
    level = PRIVACY_LEVELS - 1;
  priv.level = level;
  return privacy_contrast[level];
}

/**
 * @brief Cycle to next privacy level (for button toggle).
 * @return New contrast value
 */
static inline uint8_t oled_privacy_cycle(void) {
  priv.level = (priv.level + 1) % PRIVACY_LEVELS;
  return privacy_contrast[priv.level];
}

/**
 * @brief Notify user activity (keypress, touch, etc).
 */
static inline void oled_privacy_activity(uint32_t tick) {
  priv.last_activity_tick = tick;

  /* Restore from dimmed/off state */
  if (priv.screen_off) {
    priv.screen_off = false;
    /* Caller should call oled_display_on() */
  }
  priv.dimmed = false;
}

/**
 * @brief Poll privacy timeout (call from main loop).
 * @param tick  Current system tick
 * @return 0xFF if no change, otherwise contrast value to apply
 */
static inline uint8_t oled_privacy_poll(uint32_t tick) {
  uint32_t idle = tick - priv.last_activity_tick;

  /* Screen off after 60s */
  if (idle >= PRIVACY_OFF_TIMEOUT_MS && !priv.screen_off) {
    priv.screen_off = true;
    /* Caller should call oled_display_off() */
    return 0x00;
  }

  /* Dim after 15s */
  if (idle >= PRIVACY_DIM_TIMEOUT_MS && !priv.dimmed && !priv.screen_off) {
    priv.dimmed = true;
    /* Return minimum visible contrast */
    return 0x01;
  }

  return 0xFF; /* No change */
}

/**
 * @brief Get current effective contrast.
 */
static inline uint8_t oled_privacy_get_contrast(void) {
  if (priv.screen_off)
    return 0x00;
  if (priv.dimmed)
    return 0x01;
  return privacy_contrast[priv.level];
}

/**
 * @brief Check if screen is currently off.
 */
static inline bool oled_privacy_is_off(void) { return priv.screen_off; }

#endif /* OLED_PRIVACY_H */
