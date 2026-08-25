/**
 * @file mcu_watchdog.h
 * @brief ★ P1 #21: TPL5010 External Watchdog Driver
 *
 * TPL5010 harici watchdog ile MCU sağlık kontrolü.
 * WAKE (PC7): TPL5010'dan 1Hz pulse (input, EXTI)
 * DONE (PC8): MCU "yaşıyorum" yanıtı (output)
 *
 * 2 WAKE cevapsız → TPL5010 NRST LOW → MCU hard reset
 * Reset key'i silmez (warm reset), sadece MCU yeniden başlar.
 */
#ifndef MCU_WATCHDOG_H
#define MCU_WATCHDOG_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>


/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  volatile bool wake_pending;   /* WAKE pulse received, needs DONE */
  volatile uint32_t wake_count; /* Total WAKE pulses received */
  volatile uint32_t done_count; /* Total DONE responses sent */
  bool initialized;
} wdt_state_t;

static wdt_state_t wdt = {.wake_pending = false,
                          .wake_count = 0,
                          .done_count = 0,
                          .initialized = false};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize TPL5010 watchdog GPIO.
 *
 * WAKE (PC7): Input, falling edge EXTI interrupt
 * DONE (PC8): Output, default LOW
 */
static inline void mcu_watchdog_init(void) {
  GPIO_InitTypeDef gpio = {0};

  __HAL_RCC_GPIOC_CLK_ENABLE();

  /* WAKE input (PC7) — EXTI falling edge (TPL5010 pulses LOW) */
  gpio.Pin = PIN_WDT_WAKE;
  gpio.Mode = GPIO_MODE_IT_FALLING;
  gpio.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(GPIOC, &gpio);

  /* DONE output (PC8) — default LOW */
  gpio.Pin = PIN_WDT_DONE;
  gpio.Mode = GPIO_MODE_OUTPUT_PP;
  gpio.Pull = GPIO_NOPULL;
  gpio.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOC, &gpio);
  HAL_GPIO_WritePin(GPIOC, PIN_WDT_DONE, GPIO_PIN_RESET);

  /* Enable EXTI interrupt for PC7 */
  HAL_NVIC_SetPriority(EXTI9_5_IRQn, 1, 0);
  HAL_NVIC_EnableIRQ(EXTI9_5_IRQn);

  wdt.initialized = true;
}

/**
 * @brief EXTI callback for WAKE pin (call from HAL_GPIO_EXTI_Callback).
 * @param pin  GPIO pin that triggered the interrupt
 */
static inline void mcu_watchdog_exti_callback(uint16_t pin) {
  if (pin == PIN_WDT_WAKE) {
    wdt.wake_pending = true;
    wdt.wake_count++;
  }
}

/**
 * @brief Send DONE pulse to TPL5010.
 *
 * Call this from main loop when wake_pending is true.
 * The DONE pulse must be >100ns (we use ~1µs).
 */
static inline void mcu_watchdog_done(void) {
  /* Rising edge on DONE pin */
  HAL_GPIO_WritePin(GPIOC, PIN_WDT_DONE, GPIO_PIN_SET);

  /* Hold for ~1µs (at 80MHz, ~80 NOPs) */
  for (volatile int i = 0; i < 80; i++) {
  }

  HAL_GPIO_WritePin(GPIOC, PIN_WDT_DONE, GPIO_PIN_RESET);

  wdt.done_count++;
  wdt.wake_pending = false;
}

/**
 * @brief Poll watchdog (call from main loop).
 *
 * If a WAKE pulse was received, send DONE response.
 * If we don't respond within TPL5010's timeout (~1s),
 * TPL5010 will assert NRST and hard-reset the MCU.
 */
static inline void mcu_watchdog_poll(void) {
  if (!wdt.initialized)
    return;

  if (wdt.wake_pending) {
    mcu_watchdog_done();
  }
}

#endif /* MCU_WATCHDOG_H */
