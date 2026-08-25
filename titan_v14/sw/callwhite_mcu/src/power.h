/**
 * @file power.h
 * @brief Power Management — Battery, LDO, Supercap
 */
#ifndef CALLWHITE_POWER_H
#define CALLWHITE_POWER_H

#include <stdint.h>

typedef enum {
  POWER_NORMAL,
  POWER_LOW_BATTERY,
  POWER_CRITICAL,
  POWER_LAST_GASP, /* Supercap only */
} power_state_t;

void power_init(void);
void power_poll(void);
power_state_t power_get_state(void);
uint16_t power_get_battery_mv(void);
int8_t power_get_battery_temp(void);

#endif
