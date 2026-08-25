/**
 * @file uart_firewall.h
 * @brief ★ P1 #22: Modem UART Firewall (Zararlı Modem İzolasyonu)
 *
 * EC25 modem ThreadX RTOS kapalı kutu — hacklenirse UART saldırısı.
 *
 * 3 Katmanlı Koruma:
 *   1. AT Yanıt Whitelist — sadece bilinen yanıtlar kabul
 *   2. Max Response Length — 512 byte sınırı
 *   3. Strike Counter — 10 ihlal → UART kapatılır
 *
 * Saldırı vektörü: Kompromize modem → MCU UART exploitation.
 */
#ifndef UART_FIREWALL_H
#define UART_FIREWALL_H

#include "config.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * AT Response Whitelist
 *============================================================================*/
/* Known safe AT response prefixes.
 * Any response not starting with one of these is rejected.
 */
#define FW_WHITELIST_SIZE 24

static const char *const at_whitelist[FW_WHITELIST_SIZE] = {
    /* Standard AT responses */
    "OK",
    "ERROR",
    "+CME ERROR",
    "+CMS ERROR",
    "CONNECT",
    "NO CARRIER",
    "RING",

    /* Quectel EC25 specific */
    "+CSQ",      /* Signal quality */
    "+CREG",     /* Network registration */
    "+CEREG",    /* EPS registration */
    "+CGREG",    /* GPRS registration */
    "+QIOPEN",   /* Socket open result */
    "+QICLOSE",  /* Socket close */
    "+QIRD",     /* Socket read data */
    "+QIURC",    /* URC: socket events */
    "+QISTATE",  /* Socket state */
    "+QISEND",   /* Send result */
    "+QGMR",     /* Firmware version */
    "+QTEMP",    /* Temperature */
    "+QSSLOPEN", /* SSL socket open */
    "+QSSLRECV", /* SSL receive */
    "+QCFG",     /* Configuration */
    "+QIND",     /* URC: indication */
    "RDY",       /* Modem ready */
};

/*============================================================================
 * Firewall State
 *============================================================================*/
typedef enum {
  FW_STATE_ACTIVE,   /* Normal operation */
  FW_STATE_WARNING,  /* Strike count > 5 */
  FW_STATE_SHUTDOWN, /* Strike limit reached, UART disabled */
} fw_state_t;

typedef struct {
  fw_state_t state;
  uint16_t strike_count;    /* Consecutive invalid responses */
  uint32_t total_rejected;  /* Lifetime rejected count */
  uint32_t total_accepted;  /* Lifetime accepted count */
  uint32_t total_oversized; /* Oversized response count */
  bool uart_disabled;       /* UART RX disabled flag */
} uart_fw_state_t;

static uart_fw_state_t ufw = {.state = FW_STATE_ACTIVE,
                              .strike_count = 0,
                              .total_rejected = 0,
                              .total_accepted = 0,
                              .total_oversized = 0,
                              .uart_disabled = false};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Check if an AT response is in the whitelist.
 * @param response  Null-terminated AT response line
 * @return true if response matches a known safe prefix
 */
static inline bool uart_fw_is_whitelisted(const char *response) {
  if (response == NULL || response[0] == '\0')
    return false;

  /* Skip leading \r\n */
  while (*response == '\r' || *response == '\n')
    response++;

  if (*response == '\0')
    return true; /* Empty line is OK (inter-response spacing) */

  for (int i = 0; i < FW_WHITELIST_SIZE; i++) {
    size_t prefix_len = strlen(at_whitelist[i]);
    if (strncmp(response, at_whitelist[i], prefix_len) == 0)
      return true;
  }

  return false;
}

/**
 * @brief Validate an incoming AT response through the firewall.
 * @param response  Response data buffer
 * @param length    Response length in bytes
 * @return true if response is accepted, false if rejected
 */
static inline bool uart_fw_validate(const char *response, uint16_t length) {
#if !SECURITY_UART_FIREWALL
  return true; /* Firewall disabled */
#endif

  if (ufw.uart_disabled)
    return false; /* UART already shut down */

  /* Check 1: Length limit */
  if (length > UART_FW_MAX_RESPONSE) {
    ufw.total_oversized++;
    ufw.strike_count++;

    if (ufw.strike_count >= UART_FW_STRIKE_LIMIT) {
      ufw.state = FW_STATE_SHUTDOWN;
      ufw.uart_disabled = true;
    } else if (ufw.strike_count > 5) {
      ufw.state = FW_STATE_WARNING;
    }

    ufw.total_rejected++;
    return false;
  }

  /* Check 2: Whitelist match */
  if (!uart_fw_is_whitelisted(response)) {
    ufw.strike_count++;
    ufw.total_rejected++;

    if (ufw.strike_count >= UART_FW_STRIKE_LIMIT) {
      ufw.state = FW_STATE_SHUTDOWN;
      ufw.uart_disabled = true;
      /* TODO: OLED alert: "MODEM UART KAPATILDI!" */
    } else if (ufw.strike_count > 5) {
      ufw.state = FW_STATE_WARNING;
    }

    return false;
  }

  /* Valid response — reset strike counter */
  ufw.strike_count = 0;
  ufw.state = FW_STATE_ACTIVE;
  ufw.total_accepted++;
  return true;
}

/**
 * @brief Initialize UART firewall.
 */
static inline void uart_firewall_init(void) {
  ufw.state = FW_STATE_ACTIVE;
  ufw.strike_count = 0;
  ufw.uart_disabled = false;
}

/**
 * @brief Check if UART is still operational.
 */
static inline bool uart_fw_is_active(void) { return !ufw.uart_disabled; }

/**
 * @brief Force reset the firewall (after modem hard reset).
 */
static inline void uart_fw_reset(void) {
  ufw.state = FW_STATE_ACTIVE;
  ufw.strike_count = 0;
  ufw.uart_disabled = false;
}

#endif /* UART_FIREWALL_H */
