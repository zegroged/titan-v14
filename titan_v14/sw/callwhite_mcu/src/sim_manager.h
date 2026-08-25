/**
 * @file sim_manager.h
 * @brief ★ P2 #30: SIM PIN Zorunlu + #35 Fault Injection Hardening
 *
 * SIM kart PIN koruması zorunlu hale getirilir.
 * ★ #35: Tüm güvenlik kararlarında double/triple-check pattern.
 */
#ifndef CALLWHITE_SIM_MANAGER_H
#define CALLWHITE_SIM_MANAGER_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/*============================================================================
 * SIM State
 *============================================================================*/
typedef enum {
  SIM_STATE_UNKNOWN,
  SIM_STATE_NOT_INSERTED,
  SIM_STATE_PIN_REQUIRED,
  SIM_STATE_PUK_REQUIRED,
  SIM_STATE_READY,
  SIM_STATE_ERROR,
} sim_state_t;

typedef struct {
  sim_state_t state;
  uint8_t pin_attempts_left;
  bool pin_verified;
  bool pin_verified_2; /* ★ #35: double-verify */
} sim_data_t;

static sim_data_t sim_data = {.state = SIM_STATE_UNKNOWN,
                              .pin_attempts_left = 3,
                              .pin_verified = false,
                              .pin_verified_2 = false};

/*============================================================================
 * ★ P2 #35: Fault Injection Hardening Macros
 *
 * Glitch saldırısı tek branch atlar ama iki farklı check'i atlamaz.
 *============================================================================*/
#define SECURITY_DOUBLE_CHECK(cond, fail_action)                               \
  do {                                                                         \
    volatile bool __c1 = (cond);                                               \
    volatile bool __c2 = (cond);                                               \
    if (!__c1 || !__c2) {                                                      \
      fail_action;                                                             \
    }                                                                          \
  } while (0)

#define SECURITY_DELAY_NOPS()                                                  \
  do {                                                                         \
    __asm volatile("nop");                                                     \
    __asm volatile("nop");                                                     \
    __asm volatile("nop");                                                     \
    __asm volatile("nop");                                                     \
  } while (0)

#define SECURITY_TRIPLE_CHECK(cond, fail_action)                               \
  do {                                                                         \
    volatile bool __c1 = (cond);                                               \
    SECURITY_DELAY_NOPS();                                                     \
    volatile bool __c2 = (cond);                                               \
    SECURITY_DELAY_NOPS();                                                     \
    volatile bool __c3 = (cond);                                               \
    if (!__c1 || !__c2 || !__c3) {                                             \
      fail_action;                                                             \
    }                                                                          \
  } while (0)

/*============================================================================
 * API
 *============================================================================*/

void sim_manager_init(void);
sim_state_t sim_get_state(void);
bool sim_enter_pin(const char *pin);
bool sim_is_present(void);

/** Parse AT+CPIN? response */
static inline void sim_parse_cpin(const char *resp) {
  if (strstr(resp, "+CPIN: READY") != NULL) {
    sim_data.state = SIM_STATE_READY;
    sim_data.pin_verified = true;
    sim_data.pin_verified_2 = true;
  } else if (strstr(resp, "+CPIN: SIM PIN") != NULL) {
    sim_data.state = SIM_STATE_PIN_REQUIRED;
  } else if (strstr(resp, "+CPIN: SIM PUK") != NULL) {
    sim_data.state = SIM_STATE_PUK_REQUIRED;
  } else if (strstr(resp, "ERROR") != NULL) {
    sim_data.state = SIM_STATE_NOT_INSERTED;
  }
}

/** ★ #35: Secure check with fault injection resistance */
static inline bool sim_is_ready_secure(void) {
  volatile bool c1 = (sim_data.state == SIM_STATE_READY);
  SECURITY_DELAY_NOPS();
  volatile bool c2 = (sim_data.state == SIM_STATE_READY);
  volatile bool c3 = sim_data.pin_verified;
  return c1 && c2 && c3;
}

/** Format AT+CPIN=<pin> command */
static inline uint8_t sim_format_pin_cmd(const char *pin, char *out) {
  uint8_t len = 0;
  const char *prefix = "AT+CPIN=";
  while (*prefix)
    out[len++] = *prefix++;
  while (*pin && len < 24)
    out[len++] = *pin++;
  out[len++] = '\r';
  out[len] = '\0';
  return len;
}

#endif /* CALLWHITE_SIM_MANAGER_H */
