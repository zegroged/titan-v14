/**
 * @file modem_monitor.h
 * @brief Modem Status Monitor — STATUS/NETLIGHT/RI pins
 *
 * ★ V15 P0-3: AT+QENG KOMUTU KULLANIMAZ!
 *   Cell ID bilgisi konum tespiti için kullanılabilir (Vektör V21).
 *   Bu komut AT whitelist'e ASLA eklenmemelidir.
 *   IMSI catcher algılama (#49) için gerekli veriler
 *   sadece anlık karşılaştırma yapılır, SAKLANMAZ.
 */
#ifndef CALLWHITE_MODEM_MONITOR_H
#define CALLWHITE_MODEM_MONITOR_H

#include <stdbool.h>

typedef enum {
  MODEM_OFF,
  MODEM_BOOTING,
  MODEM_READY,
  MODEM_REGISTERED,
  MODEM_DATA_ACTIVE,
  MODEM_ERROR,
} modem_state_t;

void modem_monitor_init(void);
modem_state_t modem_get_state(void);
bool modem_is_registered(void);
void modem_power_on(void);
void modem_power_off(void);
void modem_reset(void);
void modem_rf_disable(void); /* W_DISABLE# */

#endif
