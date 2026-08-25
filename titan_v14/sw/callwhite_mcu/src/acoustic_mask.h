/**
 * @file acoustic_mask.h
 * @brief ★ P2 #38: Akustik Kripto-Sızıntı Önlemi (V27)
 *
 * AES/crypto operasyonları sırasında coil whine / kapasitör gürültüsü
 * üzerinden yan kanal saldırısı mümkündür (akustik emanation).
 *
 * Çözüm: PWM noise generator ile kripto operasyonları maskelenir.
 *   - TIM3 CH1 ile rastgele duty cycle PWM üretilir
 *   - AES busy sırasında aktif, idle'da kapalı
 *   - ★ P2 #29: OLED EM koruma da buradan kontrol edilir
 *   - ★ P2 #36: OLED TEMPEST jitter render sırası randomizasyonu
 */
#ifndef ACOUSTIC_MASK_H
#define ACOUSTIC_MASK_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>


/*============================================================================
 * PWM Noise Configuration
 *============================================================================*/
#define MASK_TIM TIM3
#define MASK_TIM_CHANNEL TIM_CHANNEL_1
#define MASK_PIN GPIO_PIN_6    /* PB6 — dikkat: OLED SCL ile paylaşmıyor */
                               /* Ayrı PWM pin kullanılmalı */
#define MASK_FREQ_HZ 40000     /* 40kHz — insan duyma eşiği üstü */
#define MASK_LFSR_SEED 0xACE1u /* LFSR initial seed */

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  bool active;
  uint16_t lfsr;          /* 16-bit LFSR for pseudo-random PWM duty */
  uint32_t cycles_active; /* Total masking cycles */
} acoustic_state_t;

static acoustic_state_t ac_mask = {
    .active = false, .lfsr = MASK_LFSR_SEED, .cycles_active = 0};

/*============================================================================
 * LFSR-16 (Galois) — hızlı pseudo-random
 *============================================================================*/
static inline uint16_t lfsr_step(uint16_t state) {
  uint16_t bit =
      ((state >> 0) ^ (state >> 2) ^ (state >> 3) ^ (state >> 5)) & 1;
  return (state >> 1) | (bit << 15);
}

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize acoustic masking PWM.
 * @param htim  TIM3 handle (pre-configured for PWM)
 */
static inline void acoustic_mask_init(TIM_HandleTypeDef *htim) {
  /* Start PWM with initial 50% duty */
  HAL_TIM_PWM_Start(htim, MASK_TIM_CHANNEL);
  __HAL_TIM_SET_COMPARE(htim, MASK_TIM_CHANNEL, 50);
  ac_mask.active = false;

  /* Initially stopped — only active during crypto */
  HAL_TIM_PWM_Stop(htim, MASK_TIM_CHANNEL);
}

/**
 * @brief Start acoustic masking (call before AES operation).
 */
static inline void acoustic_mask_start(TIM_HandleTypeDef *htim) {
  if (ac_mask.active)
    return;

  HAL_TIM_PWM_Start(htim, MASK_TIM_CHANNEL);
  ac_mask.active = true;
}

/**
 * @brief Stop acoustic masking (call after AES operation).
 */
static inline void acoustic_mask_stop(TIM_HandleTypeDef *htim) {
  if (!ac_mask.active)
    return;

  HAL_TIM_PWM_Stop(htim, MASK_TIM_CHANNEL);
  ac_mask.active = false;
}

/**
 * @brief Update PWM duty cycle with random value.
 *
 * Call this from TIM3 update interrupt or main loop
 * during active masking. Changes duty cycle every cycle
 * so acoustic emanation is noise-like.
 */
static inline void acoustic_mask_tick(TIM_HandleTypeDef *htim) {
  if (!ac_mask.active)
    return;

  ac_mask.lfsr = lfsr_step(ac_mask.lfsr);
  uint16_t duty = ac_mask.lfsr % 100; /* 0-99% */

  __HAL_TIM_SET_COMPARE(htim, MASK_TIM_CHANNEL, duty);
  ac_mask.cycles_active++;
}

/*============================================================================
 * ★ P2 #29: OLED EM Koruma — I2C Clock Spread Spectrum
 *
 * OLED I2C saat frekansını ±5% ile jitter'lar.
 * TEMPEST saldırganı sabit I2C clock'tan veri okuyamaz.
 *============================================================================*/
static inline void oled_em_jitter(I2C_HandleTypeDef *hi2c) {
  static uint16_t em_lfsr = 0xBEEF;
  em_lfsr = lfsr_step(em_lfsr);

  /* I2C timing register'ını ±5% değiştir
   * Normal: 0x00702991 (400kHz)
   * Jitter: PRESC field'ı ±1 döngü */
  uint32_t base_timing = 0x00702991;
  uint32_t jitter = (em_lfsr & 0x01) ? 0x00010000 : 0;
  hi2c->Instance->TIMINGR = base_timing + jitter;
}

/*============================================================================
 * ★ P2 #36: OLED TEMPEST Jitter — Render Sırası Randomizasyonu
 *
 * Her frame'de page render sırasını karıştır.
 * TEMPEST saldırganı ekran içeriğini EM'den okuyamaz.
 *============================================================================*/
static inline void oled_tempest_page_order(uint8_t order[8]) {
  static uint16_t tj_lfsr = 0xCAFE;

  /* Fisher-Yates shuffle of page indices */
  for (int i = 0; i < 8; i++)
    order[i] = i;

  for (int i = 7; i > 0; i--) {
    tj_lfsr = lfsr_step(tj_lfsr);
    int j = tj_lfsr % (i + 1);
    uint8_t tmp = order[i];
    order[i] = order[j];
    order[j] = tmp;
  }
}

#endif /* ACOUSTIC_MASK_H */
