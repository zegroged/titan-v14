/**
 * @file modem_purge.h
 * @brief ★ P6 #55: Modem RAM Purge
 *
 * Modem RAM'deki hassas verileri periyodik temizleme.
 * AT+CFUN=0 → idle → RAM temizle → AT+CFUN=1 restart.
 *
 * Temizlenen veriler:
 *   - IMSI cache
 *   - APN credentials
 *   - TCP session state
 *   - DNS cache
 *   - TLS session tickets
 *
 * Zamanlama:
 *   - Periyodik: her 30 dakika
 *   - Shutdown: zorunlu
 *   - Manuel: operatör komutu ile
 */
#ifndef MODEM_PURGE_H
#define MODEM_PURGE_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>


/*============================================================================
 * Configuration
 *============================================================================*/
#define PURGE_INTERVAL_MS (30 * 60 * 1000) /* 30 dakika */
#define PURGE_CFUN_WAIT_MS 3000            /* AT+CFUN yanıt bekleme */
#define PURGE_RESTART_WAIT_MS 5000         /* Modem restart bekleme */

typedef enum {
  PURGE_IDLE = 0,
  PURGE_DEACTIVATING,  /* AT+CFUN=0 gönderildi */
  PURGE_CLEARING,      /* AT+QPRTPARA=3 (NV clear) */
  PURGE_REACTIVATING,  /* AT+CFUN=1 gönderildi */
  PURGE_WAITING_READY, /* Modem restart bekleniyor */
  PURGE_COMPLETE
} purge_state_t;

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  purge_state_t state;
  uint32_t last_purge_tick;
  uint32_t state_enter_tick;
  uint32_t purge_count; /* Toplam purge sayısı */
  bool force_purge;     /* Manuel tetikleme */
} modem_purge_ctx_t;

static modem_purge_ctx_t mpurge = {.state = PURGE_IDLE,
                                   .last_purge_tick = 0,
                                   .state_enter_tick = 0,
                                   .purge_count = 0,
                                   .force_purge = false};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize modem purge system.
 */
static inline void modem_purge_init(void) {
  mpurge.state = PURGE_IDLE;
  mpurge.last_purge_tick = HAL_GetTick();
  mpurge.purge_count = 0;
  mpurge.force_purge = false;
}

/**
 * @brief Force an immediate modem RAM purge.
 */
static inline void modem_purge_force(void) { mpurge.force_purge = true; }

/**
 * @brief Poll modem purge state machine.
 * @param tick Current system tick
 */
static inline void modem_purge_poll(uint32_t tick) {
  switch (mpurge.state) {
  case PURGE_IDLE: {
    bool timer_expired = (tick - mpurge.last_purge_tick >= PURGE_INTERVAL_MS);
    if (timer_expired || mpurge.force_purge) {
      mpurge.force_purge = false;
      mpurge.state = PURGE_DEACTIVATING;
      mpurge.state_enter_tick = tick;
      /* TODO: Send AT+CFUN=0 via at_engine */
    }
    break;
  }

  case PURGE_DEACTIVATING:
    if (tick - mpurge.state_enter_tick >= PURGE_CFUN_WAIT_MS) {
      mpurge.state = PURGE_CLEARING;
      mpurge.state_enter_tick = tick;
      /* TODO: Send AT+QPRTPARA=3 (clear NV items) */
      /* TODO: Send AT+QPOWD=0 (power off) then AT+CFUN=1 */
    }
    break;

  case PURGE_CLEARING:
    if (tick - mpurge.state_enter_tick >= PURGE_CFUN_WAIT_MS) {
      mpurge.state = PURGE_REACTIVATING;
      mpurge.state_enter_tick = tick;
      /* TODO: Send AT+CFUN=1 */
    }
    break;

  case PURGE_REACTIVATING:
    if (tick - mpurge.state_enter_tick >= PURGE_RESTART_WAIT_MS) {
      mpurge.state = PURGE_COMPLETE;
    }
    break;

  case PURGE_COMPLETE:
    mpurge.last_purge_tick = tick;
    mpurge.purge_count++;
    mpurge.state = PURGE_IDLE;
    break;

  default:
    mpurge.state = PURGE_IDLE;
    break;
  }
}

/**
 * @brief Get purge statistics.
 */
static inline uint32_t modem_purge_count(void) { return mpurge.purge_count; }

/**
 * @brief Emergency purge (shutdown path). Blocking.
 */
static inline void modem_purge_emergency(void) {
  /* Direct AT commands — blocking mode */
  /* TODO: HAL_UART_Transmit "AT+CFUN=0\r\n" */
  HAL_Delay(PURGE_CFUN_WAIT_MS);
  /* TODO: HAL_UART_Transmit "AT+QPRTPARA=3\r\n" */
  HAL_Delay(PURGE_CFUN_WAIT_MS);
}

#endif /* MODEM_PURGE_H */
