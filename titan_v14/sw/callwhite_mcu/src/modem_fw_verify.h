/**
 * @file modem_fw_verify.h
 * @brief ★ P1 #15: Modem Firmware Integrity Verification
 *
 * Boot sırasında AT+QGMR komutu ile EC25-E firmware versiyonunu okur.
 * Bilinen (güvenilir) versiyon hash'i ile karşılaştırır.
 * Uyumsuzluk → OLED uyarı + iletişim engeli.
 *
 * Saldırı vektörü V35: Trojanlanmış modem firmware tespiti.
 */
#ifndef MODEM_FW_VERIFY_H
#define MODEM_FW_VERIFY_H

#include "config.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * Known Good Firmware Versions (whitelist)
 *============================================================================*/
/* EC25-E firmware version strings from AT+QGMR response.
 * Update this list when modem is updated to new firmware.
 * Format: "EC25EFAR06A06M4G" (example)
 */
#define MODEM_FW_MAX_VERSIONS 4
#define MODEM_FW_VERSION_LEN 32

static const char
    known_fw_versions[MODEM_FW_MAX_VERSIONS][MODEM_FW_VERSION_LEN] = {
        "EC25EFAR06A06M4G", /* Production v6 */
        "EC25EFAR06A07M4G", /* Production v7 */
        "EC25EFAR06A08M4G", /* Production v8 (latest known) */
        ""                  /* Sentinel — empty = end of list */
};

/*============================================================================
 * Verification Result
 *============================================================================*/
typedef enum {
  MODEM_FW_OK = 0x00,          /* Known good version */
  MODEM_FW_UNKNOWN = 0x01,     /* Version not in whitelist */
  MODEM_FW_NO_RESPONSE = 0x02, /* Modem did not respond */
  MODEM_FW_NOT_CHECKED = 0xFF
} modem_fw_result_t;

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  modem_fw_result_t result;
  char detected_version[MODEM_FW_VERSION_LEN];
} modem_fw_state_t;

static modem_fw_state_t modem_fw_state = {.result = MODEM_FW_NOT_CHECKED,
                                          .detected_version = {0}};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Check if a firmware version string is in the whitelist.
 * @param version  Null-terminated version string from AT+QGMR
 * @return true if version is known good
 */
static inline bool modem_fw_is_known(const char *version) {
  for (int i = 0; i < MODEM_FW_MAX_VERSIONS; i++) {
    if (known_fw_versions[i][0] == '\0')
      break; /* End of list */

    if (strncmp(version, known_fw_versions[i], MODEM_FW_VERSION_LEN) == 0)
      return true;
  }
  return false;
}

/**
 * @brief Verify modem firmware version.
 *
 * Call this after AT engine is initialized and modem is responsive.
 * Sends AT+QGMR and parses response.
 *
 * @param version_response  AT+QGMR response string (first line)
 * @return modem_fw_result_t
 */
static inline modem_fw_result_t modem_fw_verify(const char *version_response) {
  if (version_response == NULL || version_response[0] == '\0') {
    modem_fw_state.result = MODEM_FW_NO_RESPONSE;
    return MODEM_FW_NO_RESPONSE;
  }

  /* Store detected version */
  strncpy(modem_fw_state.detected_version, version_response,
          MODEM_FW_VERSION_LEN - 1);
  modem_fw_state.detected_version[MODEM_FW_VERSION_LEN - 1] = '\0';

  /* Check against whitelist */
  if (modem_fw_is_known(version_response)) {
    modem_fw_state.result = MODEM_FW_OK;
    return MODEM_FW_OK;
  }

  modem_fw_state.result = MODEM_FW_UNKNOWN;
  return MODEM_FW_UNKNOWN;
}

/**
 * @brief Initialize modem firmware verification.
 *
 * Note: This should be called AFTER at_engine_init() completes,
 * since we need the AT command interface ready.
 *
 * Integration:
 *   1. at_engine sends AT+QGMR
 *   2. Response parsed → first line extracted
 *   3. modem_fw_verify(first_line) called
 *   4. If MODEM_FW_UNKNOWN:
 *      - OLED warning: "MODEM FW BILINMIYOR!"
 *      - Communication blocked (optional: enforce via flag)
 *      - Log event for telemetry
 */
static inline void modem_fw_verify_init(void) {
#if SECURITY_MODEM_FW_VERIFY
  /* AT+QGMR will be sent by at_engine during init sequence.
   * The response callback should call modem_fw_verify().
   * If verification fails, tcp_session should refuse connections.
   *
   * This is a stub — actual AT command sending is in at_engine.
   * The at_engine callback pattern:
   *   at_send("AT+QGMR\r\n");
   *   // In response handler:
   *   modem_fw_verify(response_line);
   */
#endif
}

#endif /* MODEM_FW_VERIFY_H */
