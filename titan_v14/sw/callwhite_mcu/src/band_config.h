/**
 * @file band_config.h
 * @brief Band/Operator Configuration — 2G Fallback, Band Lock, Roaming
 */
#ifndef CALLWHITE_BAND_CONFIG_H
#define CALLWHITE_BAND_CONFIG_H

typedef enum {
  NW_MODE_LTE_ONLY, /* AT+QCFG="nwscanmode",3 */
  NW_MODE_LTE_3G,   /* AT+QCFG="nwscanmode",5 (default) */
  NW_MODE_AUTO,     /* AT+QCFG="nwscanmode",0 */
} nw_mode_t;

typedef enum {
  BAND_TR,      /* B1+B3+B7+B8+B20 */
  BAND_EU,      /* Same as TR for now */
  BAND_GLOBAL,  /* All bands */
  BAND_STEALTH, /* B3 only (minimum RF) */
} band_profile_t;

void band_config_init(void);
void band_set_mode(nw_mode_t mode);
void band_set_profile(band_profile_t profile);
void band_lock_operator(const char *mcc_mnc);
void band_enable_roaming(void);

#endif
