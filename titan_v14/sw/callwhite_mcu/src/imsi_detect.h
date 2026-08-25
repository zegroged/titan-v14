/**
 * @file imsi_detect.h
 * @brief ★ P2 #37: IMSI Catcher Detection
 *
 * Sahte baz istasyonu (IMSI catcher / Stingray) tespiti:
 *   1. Cell ID değişim hızı kontrolü (hop-too-fast)
 *   2. LAC anomali tespiti (normalde sabit)
 *   3. Sinyal gücü profil analizi (çok güçlü = yakın fake)
 *   4. 2G downgrade tespiti (IMSI catcher en sık 2G zorlar)
 *
 * Saldırı vektörü: Aktif MITM ile konum + metadata sızıntısı.
 */
#ifndef IMSI_DETECT_H
#define IMSI_DETECT_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>

/*============================================================================
 * Detection Thresholds
 *============================================================================*/
#define IMSI_MAX_CELL_CHANGES_PER_MIN 5 /* Normal: 0-2 */
#define IMSI_SUSPICIOUS_RSSI_DBM (-40)  /* Çok güçlü = yakın fake BTS */
#define IMSI_LAC_CHANGE_THRESHOLD 3     /* LAC 3+ kez değişirse */
#define IMSI_HISTORY_SIZE 16            /* Son N cell kaydı */

/*============================================================================
 * Alert Levels
 *============================================================================*/
typedef enum {
  IMSI_LEVEL_NONE = 0,     /* Temiz */
  IMSI_LEVEL_MONITOR = 1,  /* Küçük anomali, izle */
  IMSI_LEVEL_WARNING = 2,  /* Şüpheli — OLED uyarı */
  IMSI_LEVEL_CRITICAL = 3, /* IMSI catcher! → RF kapatılabilir */
} imsi_alert_level_t;

/*============================================================================
 * Cell History Entry
 *============================================================================*/
typedef struct {
  uint32_t cell_id;
  uint16_t lac;
  int8_t rssi_dbm;
  uint32_t timestamp;  /* HAL_GetTick() */
  uint8_t access_tech; /* 0=GSM, 2=UTRAN, 7=LTE */
} cell_entry_t;

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  cell_entry_t history[IMSI_HISTORY_SIZE];
  uint8_t history_idx;
  uint8_t history_count;

  /* Counters (rolling window) */
  uint8_t cell_changes_per_min;
  uint8_t lac_changes;
  uint32_t window_start_tick;

  /* Alert */
  imsi_alert_level_t alert_level;
  uint32_t alert_count; /* Lifetime alerts */
} imsi_state_t;

static imsi_state_t imsi = {.history_idx = 0,
                            .history_count = 0,
                            .cell_changes_per_min = 0,
                            .lac_changes = 0,
                            .window_start_tick = 0,
                            .alert_level = IMSI_LEVEL_NONE,
                            .alert_count = 0};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Record a new cell tower observation.
 *
 * Call this when AT+CREG or AT+CEREG reports a new cell.
 * Typical update: AT+QENG="servingcell" response parser.
 */
static inline void imsi_record_cell(uint32_t cell_id, uint16_t lac,
                                    int8_t rssi_dbm, uint8_t access_tech,
                                    uint32_t tick) {
  /* Reset window if >60s elapsed */
  if (tick - imsi.window_start_tick > 60000) {
    imsi.cell_changes_per_min = 0;
    imsi.lac_changes = 0;
    imsi.window_start_tick = tick;
  }

  /* Check for cell change */
  if (imsi.history_count > 0) {
    uint8_t prev =
        (imsi.history_idx == 0) ? IMSI_HISTORY_SIZE - 1 : imsi.history_idx - 1;

    if (imsi.history[prev].cell_id != cell_id)
      imsi.cell_changes_per_min++;

    if (imsi.history[prev].lac != lac)
      imsi.lac_changes++;
  }

  /* Store in circular buffer */
  imsi.history[imsi.history_idx].cell_id = cell_id;
  imsi.history[imsi.history_idx].lac = lac;
  imsi.history[imsi.history_idx].rssi_dbm = rssi_dbm;
  imsi.history[imsi.history_idx].timestamp = tick;
  imsi.history[imsi.history_idx].access_tech = access_tech;

  imsi.history_idx = (imsi.history_idx + 1) % IMSI_HISTORY_SIZE;
  if (imsi.history_count < IMSI_HISTORY_SIZE)
    imsi.history_count++;

  /* Evaluate threat level */
  imsi_alert_level_t new_level = IMSI_LEVEL_NONE;

  /* Check 1: Cell hopping too fast */
  if (imsi.cell_changes_per_min >= IMSI_MAX_CELL_CHANGES_PER_MIN)
    new_level = IMSI_LEVEL_WARNING;

  /* Check 2: LAC instability */
  if (imsi.lac_changes >= IMSI_LAC_CHANGE_THRESHOLD)
    new_level = (new_level >= IMSI_LEVEL_WARNING) ? IMSI_LEVEL_CRITICAL
                                                  : IMSI_LEVEL_WARNING;

  /* Check 3: Suspiciously strong signal (close fake BTS) */
  if (rssi_dbm > IMSI_SUSPICIOUS_RSSI_DBM)
    new_level = (new_level >= IMSI_LEVEL_WARNING) ? IMSI_LEVEL_CRITICAL
                                                  : IMSI_LEVEL_MONITOR;

  /* Check 4: 2G downgrade (IMSI catchers force 2G) */
  if (access_tech == 0)              /* GSM = 2G */
    new_level = IMSI_LEVEL_CRITICAL; /* 2G kapalı olmalıydı! */

  if (new_level > imsi.alert_level) {
    imsi.alert_level = new_level;
    imsi.alert_count++;
  }

  /* Auto-clear after stable period */
  if (imsi.cell_changes_per_min == 0 && imsi.lac_changes == 0 &&
      rssi_dbm <= IMSI_SUSPICIOUS_RSSI_DBM && access_tech != 0) {
    imsi.alert_level = IMSI_LEVEL_NONE;
  }
}

static inline imsi_alert_level_t imsi_get_alert(void) {
  return imsi.alert_level;
}
static inline uint32_t imsi_get_alert_count(void) { return imsi.alert_count; }

static inline void imsi_detect_init(void) {
  imsi.history_idx = 0;
  imsi.history_count = 0;
  imsi.alert_level = IMSI_LEVEL_NONE;
}

#endif /* IMSI_DETECT_H */
