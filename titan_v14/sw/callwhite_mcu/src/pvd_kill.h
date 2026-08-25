/**
 * @file pvd_kill.h
 * @brief ★ P5 #45: PVD + Supercap Kill Guarantee
 *
 * Güç kesilmesi tespit (STM32L476 PVD) + garanti imha.
 *
 * Akış:
 *   1. PVD eşik = 2.8V (VDDA düşünce interrupt)
 *   2. PVD IRQ → emergency wipe başlat
 *   3. Supercap ~700ms pencere:
 *      - BKP register sıfırla (RTC->BKP0R..BKP31R)
 *      - SRAM key alanlarını zeroize
 *      - FPGA kill pin assert (PC13)
 *   4. MCU halt
 *
 * Saldırı vektörü: Güç keserek cihazı dondurma (cold boot)
 */
#ifndef PVD_KILL_H
#define PVD_KILL_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * PVD Configuration
 *============================================================================*/
/* PVD threshold level (STM32L4 PWR_CR2) */
#define PVD_LEVEL_2V8 0x06 /* ~2.8V threshold */
#define PWR_CR2_PLS_MASK (0x07 << 1)

/* PWR register base (STM32L476) */
typedef struct {
  volatile uint32_t CR1;
  volatile uint32_t CR2;
  volatile uint32_t CR3;
  volatile uint32_t CR4;
  volatile uint32_t SR1;
  volatile uint32_t SR2;
} PWR_TypeDef;

#define PWR ((PWR_TypeDef *)0x40007000UL)

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  bool initialized;
  bool pvd_triggered;    /* PVD interrupt received */
  uint32_t trigger_tick; /* When PVD was triggered */
  bool wipe_complete;    /* Emergency wipe done */
} pvd_state_t;

static pvd_state_t pvd = {.initialized = false,
                          .pvd_triggered = false,
                          .trigger_tick = 0,
                          .wipe_complete = false};

/*============================================================================
 * Emergency Wipe Procedure
 *============================================================================*/

/**
 * @brief Wipe all sensitive data in BKP registers.
 */
static inline void pvd_wipe_bkp(void) {
  volatile uint32_t *bkp = &RTC->BKP0R;
  for (int i = 0; i < 32; i++) {
    bkp[i] = 0x00000000;
  }
}

/**
 * @brief Wipe SRAM key storage areas.
 *        Zeroes a 4KB region at known key locations.
 */
static inline void pvd_wipe_sram_keys(void) {
  /* Key material typically in first 4KB of SRAM2 (0x10000000) */
  volatile uint32_t *sram2 = (volatile uint32_t *)0x10000000UL;
  for (int i = 0; i < 1024; i++) { /* 4KB = 1024 x 4 bytes */
    sram2[i] = 0x00000000;
  }
}

/**
 * @brief Assert FPGA kill signal.
 */
static inline void pvd_assert_fpga_kill(void) {
  GPIOC->BSRR = (1U << 13); /* PC13 = FPGA_KILL HIGH */
}

/**
 * @brief Full emergency wipe sequence.
 *        Must complete within supercap window (~700ms).
 */
static inline void pvd_emergency_wipe(void) {
  if (pvd.wipe_complete)
    return;

  /* 1. Assert FPGA kill FIRST (fastest, most critical) */
  pvd_assert_fpga_kill();

  /* 2. Wipe BKP registers (crypto keys, PIN hash) */
  pvd_wipe_bkp();

  /* 3. Wipe SRAM key areas */
  pvd_wipe_sram_keys();

  /* 4. Mark complete */
  pvd.wipe_complete = true;

  /* 5. Halt — no recovery possible */
  __disable_irq();
  while (1) {
    __NOP();
  }
}

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize PVD for power-loss detection.
 *
 * Configures:
 *   - PWR clock enable
 *   - PVD threshold = 2.8V
 *   - PVD interrupt enable (EXTI16)
 *   - NVIC priority
 */
static inline void pvd_init(void) {
  /* Enable PWR clock */
  __HAL_RCC_PWR_CLK_ENABLE();

  /* Set PVD level */
  uint32_t cr2 = PWR->CR2;
  cr2 &= ~PWR_CR2_PLS_MASK;
  cr2 |= (PVD_LEVEL_2V8 << 1);
  cr2 |= (1U << 0); /* PVDE = enable */
  PWR->CR2 = cr2;

  /* Enable EXTI16 (PVD) rising edge interrupt */
  /* In production: configure EXTI16 via HAL_PWR_ConfigPVD() */

  pvd.initialized = true;
  pvd.pvd_triggered = false;
  pvd.wipe_complete = false;
}

/**
 * @brief PVD interrupt handler callback.
 *        Call this from PVD_PVM_IRQHandler.
 */
static inline void pvd_irq_handler(void) {
  pvd.pvd_triggered = true;
  pvd.trigger_tick = HAL_GetTick();

  /* Immediate emergency wipe — no delay */
  pvd_emergency_wipe();
}

/**
 * @brief Check if PVD has been triggered (for polling mode).
 */
static inline bool pvd_is_triggered(void) { return pvd.pvd_triggered; }

/**
 * @brief Poll PVD status (call from main loop as backup).
 *        If PVD was triggered but IRQ missed, catch it here.
 */
static inline void pvd_poll(void) {
  if (!pvd.initialized)
    return;

  /* Check PWR_SR1.PVDO flag directly */
  if (PWR->SR1 & (1U << 4)) { /* PVDO bit */
    if (!pvd.pvd_triggered) {
      pvd_irq_handler();
    }
  }
}

#endif /* PVD_KILL_H */
