/**
 * @file jamming_detect.h
 * @brief RF Jamming Detection — RSSI Anomaly Analysis
 */
#ifndef CALLWHITE_JAMMING_DETECT_H
#define CALLWHITE_JAMMING_DETECT_H

#include <stdint.h>

typedef enum {
  JAMMING_NONE,   /* Normal operation */
  JAMMING_LEVEL1, /* Suspicious — OLED warning */
  JAMMING_LEVEL2, /* Probable — log event */
  JAMMING_LEVEL3, /* Sustained — notify FPGA */
  JAMMING_LEVEL4, /* Critical — RF disable */
} jamming_level_t;

void jamming_detect_init(void);
void jamming_detect_poll(void);
jamming_level_t jamming_get_level(void);

#endif
