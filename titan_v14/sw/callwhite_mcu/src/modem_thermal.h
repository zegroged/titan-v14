/**
 * @file modem_thermal.h
 * @brief Modem Thermal Management — AT+QTEMP + NTC
 */
#ifndef CALLWHITE_MODEM_THERMAL_H
#define CALLWHITE_MODEM_THERMAL_H

#include <stdint.h>

typedef enum {
  THERMAL_NORMAL,   /* < 60C */
  THERMAL_THROTTLE, /* 60-70C */
  THERMAL_RF_OFF,   /* 70-80C */
  THERMAL_SHUTDOWN, /* > 80C */
} thermal_state_t;

void modem_thermal_init(void);
void modem_thermal_poll(void);
thermal_state_t modem_thermal_get_state(void);
int16_t modem_thermal_get_temp(void); /* Celsius */

#endif
