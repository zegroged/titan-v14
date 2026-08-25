/**
 * @file dead_man.h
 * @brief ★ P3 #36: Nabız Sensörü — Dead Man Switch
 *
 * Operatör cihazı bırakırsa otomatik zeroize.
 *
 * Donanım modu: MAX30102 I2C pulse sensor (isteğe bağlı)
 * Yazılım modu: Keypad + tuş timeout (her zaman aktif fallback)
 *
 * Akış:
 *   Her tuş basımı → timer reset
 *   DEAD_MAN_WARN_SEC tuşa basılmadı → OLED uyarı
 *   DEAD_MAN_KILL_SEC tuşa basılmadı → Zeroize
 *
 * Bağımlılık: config.h, oled_ui.h, tamper.h
 */
#ifndef DEAD_MAN_H
#define DEAD_MAN_H

#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>

/*============================================================================
 * Configuration (override in config.h)
 *============================================================================*/
#ifndef DEAD_MAN_WARN_SEC
#define DEAD_MAN_WARN_SEC 10
#endif
#ifndef DEAD_MAN_KILL_SEC
#define DEAD_MAN_KILL_SEC 15
#endif

/*============================================================================
 * State
 *============================================================================*/
typedef enum {
  DM_IDLE,    /* Devre dışı — PIN ile bypass edildi */
  DM_ACTIVE,  /* Normal — son dokunuş zamanlayıcı çalışıyor */
  DM_WARNING, /* Uyarı ekranda — DEAD_MAN_WARN_SEC aşıldı */
  DM_KILLED   /* Zeroize tetiklendi */
} dm_state_t;

typedef struct {
  dm_state_t state;
  uint32_t last_touch_tick; /* Son tuş basımı / nabız zamanı */
  bool hw_sensor;           /* true = MAX30102 bağlı */
  bool armed;               /* PIN ile aktif edildi mi */
  bool warning_shown;       /* Uyarı OLED'de gösterildi mi */
} dead_man_state_t;

static dead_man_state_t dm = {.state = DM_IDLE,
                              .last_touch_tick = 0,
                              .hw_sensor = false,
                              .armed = false,
                              .warning_shown = false};

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize dead man switch.
 * @param hw_sensor  true = MAX30102 pulse sensor, false = keypad timeout only
 */
static inline void dead_man_init(bool hw_sensor) {
  dm.hw_sensor = hw_sensor;
  dm.state = DM_IDLE;
  dm.armed = false;
  dm.warning_shown = false;

  if (hw_sensor) {
    /* TODO: MAX30102 I2C init (0x57)
     *   - Mode: Heart Rate only
     *   - Sample rate: 50 Hz
     *   - LED current: 6.2mA (low power)
     *   - FIFO almost full interrupt
     */
  }
}

/**
 * @brief Arm the dead man switch (call after successful PIN entry).
 * @param tick  Current HAL tick
 */
static inline void dead_man_arm(uint32_t tick) {
  dm.state = DM_ACTIVE;
  dm.last_touch_tick = tick;
  dm.armed = true;
  dm.warning_shown = false;
}

/**
 * @brief Disarm — used when entering settings or during OTA.
 */
static inline void dead_man_disarm(void) {
  dm.state = DM_IDLE;
  dm.armed = false;
  dm.warning_shown = false;
}

/**
 * @brief Signal touch / activity.
 *        Call on every keypress or pulse sensor heartbeat.
 */
static inline void dead_man_touch(void) {
  dm.last_touch_tick = HAL_GetTick();
  if (dm.state == DM_WARNING) {
    dm.state = DM_ACTIVE;
    dm.warning_shown = false;
  }
}

/**
 * @brief Check dead man switch status.
 * @return true if dead man switch is armed
 */
static inline bool dead_man_is_armed(void) { return dm.armed; }

/**
 * @brief Poll dead man switch (call from main loop every ~100ms).
 * @param tick  Current HAL tick
 */
static inline void dead_man_poll(uint32_t tick) {
  if (!dm.armed || dm.state == DM_IDLE || dm.state == DM_KILLED) {
    return;
  }

  uint32_t elapsed_ms = tick - dm.last_touch_tick;
  uint32_t warn_ms = (uint32_t)DEAD_MAN_WARN_SEC * 1000U;
  uint32_t kill_ms = (uint32_t)DEAD_MAN_KILL_SEC * 1000U;

  if (elapsed_ms >= kill_ms) {
    /* ★ KILL — operatör yok */
    dm.state = DM_KILLED;
    /* FPGA zeroize */
    GPIOC->BSRR = (1U << 13); /* PC13 = FPGA_KILL HIGH */
    /* Halt */
    while (1) {
      __NOP();
    }
  } else if (elapsed_ms >= warn_ms && !dm.warning_shown) {
    /* ★ WARNING — ekranda uyarı göster */
    dm.state = DM_WARNING;
    dm.warning_shown = true;

    uint32_t remaining_sec = (kill_ms - elapsed_ms) / 1000U;
    (void)remaining_sec; /* Used by UI — caller reads dm.state */
  }
}

/**
 * @brief Get remaining seconds before kill.
 * @param tick  Current HAL tick
 * @return Seconds until kill (0 if not armed)
 */
static inline uint32_t dead_man_remaining_sec(uint32_t tick) {
  if (!dm.armed || dm.state == DM_IDLE)
    return 0;
  uint32_t elapsed_ms = tick - dm.last_touch_tick;
  uint32_t kill_ms = (uint32_t)DEAD_MAN_KILL_SEC * 1000U;
  if (elapsed_ms >= kill_ms)
    return 0;
  return (kill_ms - elapsed_ms) / 1000U;
}

#endif /* DEAD_MAN_H */
