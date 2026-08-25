/**
 * @file radio_silence.h
 * @brief ★ V14.2: Radio Silence Mode — Operator-Controlled Modem Shutdown
 *
 * Modem aktifken LTE protokolü gereği lokasyon bilgisi baz istasyonuna sızar.
 * AT filtresi bunu önleyemez. Bu modül operatörün tek tuşla modem RF gücünü
 * tamamen kesebileceği "Radyo Sessizlik" modu sağlar.
 *
 * Mekanizma:
 *   1. GaN FET ile modem güç hattı fiziksel olarak kesilir
 *   2. LED + OLED ile durum gösterilir
 *   3. 4G kesilince otomatik LoRa mesh / Iridium SBD yedek geçiş
 *   4. Keypad shortcut: *#7370# ile hızlı toggle
 *
 * Saldırı vektörü V38: LTE protokol lokasyon sızıntısı (Cell Tower
 * Triangulation)
 */
#ifndef RADIO_SILENCE_H
#define RADIO_SILENCE_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>

/*============================================================================
 * Radio Silence State
 *============================================================================*/
typedef enum {
  RS_INACTIVE = 0, /* Modem active, normal operation */
  RS_ENTERING,     /* Transition: shutting down modem */
  RS_ACTIVE,       /* Modem power cut, radio silent */
  RS_EXITING       /* Transition: bringing modem back */
} radio_silence_state_t;

typedef struct {
  radio_silence_state_t state;
  uint32_t enter_timestamp;     /* HAL_GetTick() when entered */
  uint32_t total_silent_ms;     /* Cumulative radio-off time */
  bool lora_fallback_active;    /* LoRa mesh activated */
  bool iridium_fallback_active; /* Iridium SBD activated */
} radio_silence_ctx_t;

static radio_silence_ctx_t rs_ctx = {.state = RS_INACTIVE,
                                     .enter_timestamp = 0,
                                     .total_silent_ms = 0,
                                     .lora_fallback_active = false,
                                     .iridium_fallback_active = false};

/*============================================================================
 * GaN FET Power Control
 *============================================================================*/

/** Cut modem power via GaN FET — hard RF kill */
static inline void rs_modem_power_cut(void) {
  /* Drive RADIO_SILENCE_PIN LOW → GaN FET OFF → modem power cut */
  HAL_GPIO_WritePin(GPIOC, RADIO_SILENCE_PIN, GPIO_PIN_RESET);

  /* Also assert W_DISABLE to ensure RF frontend is off */
  HAL_GPIO_WritePin(GPIOC, PIN_MODEM_W_DISABLE, GPIO_PIN_SET);
}

/** Restore modem power via GaN FET */
static inline void rs_modem_power_restore(void) {
  /* De-assert W_DISABLE first */
  HAL_GPIO_WritePin(GPIOC, PIN_MODEM_W_DISABLE, GPIO_PIN_RESET);

  /* Drive RADIO_SILENCE_PIN HIGH → GaN FET ON → modem power restored */
  HAL_GPIO_WritePin(GPIOC, RADIO_SILENCE_PIN, GPIO_PIN_SET);
}

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Enter radio silence mode.
 *        Cuts modem power, activates fallback comms, updates OLED.
 */
static inline void radio_silence_enter(void) {
  if (rs_ctx.state != RS_INACTIVE)
    return;

  rs_ctx.state = RS_ENTERING;

  /* Step 1: Cut modem power via GaN FET */
  rs_modem_power_cut();
  HAL_Delay(50); /* Allow FET to fully switch */

  /* Step 2: Record entry time */
  rs_ctx.enter_timestamp = HAL_GetTick();

  /* Step 3: Activate LoRa mesh fallback if available */
  /* NOTE: LoRa driver integration TBD — hardware dependent */
  rs_ctx.lora_fallback_active = false; /* Will be set by LoRa init */

  /* Step 4: Activate Iridium SBD if LoRa unavailable */
  /* NOTE: Iridium 9602 driver integration TBD */
  rs_ctx.iridium_fallback_active = false;

  /* Step 5: Update LED indicator */
  /* LED pattern: steady RED = radio silent */

  rs_ctx.state = RS_ACTIVE;
}

/**
 * @brief Exit radio silence mode.
 *        Restores modem power, waits for network registration.
 */
static inline void radio_silence_exit(void) {
  if (rs_ctx.state != RS_ACTIVE)
    return;

  rs_ctx.state = RS_EXITING;

  /* Calculate total silent time */
  uint32_t now = HAL_GetTick();
  rs_ctx.total_silent_ms += (now - rs_ctx.enter_timestamp);

  /* Step 1: Deactivate fallback comms */
  rs_ctx.lora_fallback_active = false;
  rs_ctx.iridium_fallback_active = false;

  /* Step 2: Restore modem power */
  rs_modem_power_restore();

  /* Step 3: Wait for modem boot (EC25-E typical: 3-5 seconds) */
  HAL_Delay(5000);

  /* Step 4: Send AT wake-up sequence */
  /* AT → OK check handled by modem_monitor module */

  /* Step 5: Wait for network registration
   * AT+CREG? polling will be done by main loop
   */

  /* Step 6: Update LED indicator */
  /* LED pattern: steady GREEN = modem active */

  rs_ctx.state = RS_INACTIVE;
}

/**
 * @brief Toggle radio silence (for keypad shortcut).
 */
static inline void radio_silence_toggle(void) {
  if (rs_ctx.state == RS_ACTIVE) {
    radio_silence_exit();
  } else if (rs_ctx.state == RS_INACTIVE) {
    radio_silence_enter();
  }
  /* Ignore if in transition state */
}

/**
 * @brief Check if radio silence is active.
 */
static inline bool radio_silence_is_active(void) {
  return rs_ctx.state == RS_ACTIVE;
}

/**
 * @brief Get total cumulative radio-off duration in milliseconds.
 */
static inline uint32_t radio_silence_total_ms(void) {
  if (rs_ctx.state == RS_ACTIVE) {
    /* Include current session */
    return rs_ctx.total_silent_ms + (HAL_GetTick() - rs_ctx.enter_timestamp);
  }
  return rs_ctx.total_silent_ms;
}

/**
 * @brief Check keypad sequence for radio silence shortcut.
 *        Sequence: *#7370#
 *
 * @param key  Latest key press character
 * @return     true if sequence completed
 */
static inline bool radio_silence_check_key_combo(char key) {
  static const char combo[] = RADIO_SILENCE_KEY_COMBO;
  static uint8_t combo_idx = 0;

  if (key == combo[combo_idx]) {
    combo_idx++;
    if (combo_idx >= sizeof(combo) - 1) {
      combo_idx = 0;
      radio_silence_toggle();
      return true;
    }
  } else {
    combo_idx = 0;
    /* Check if this key starts the sequence */
    if (key == combo[0])
      combo_idx = 1;
  }
  return false;
}

#endif /* RADIO_SILENCE_H */
