/**
 * @file fw_signing.h
 * @brief ★ P1 #17: Firmware Signing & OTA Verification
 *
 * OTA imaj doğrulama: SHA-256 HMAC + AES-128-CBC.
 * İmza anahtarı MCU OTP'de saklanır.
 *
 * Header format:
 *   [magic: 4B][version: 4B][size: 4B][flags: 4B][hmac: 32B] = 48 bytes
 *
 * Saldırı vektörü V31: Sahte firmware yükleme engeli.
 *
 * ★ P2 #35a: Double verification (fault injection hardening) ile
 *   birlikte kullanılacak — glitch 3 if'i aynı anda atlayamaz.
 */
#ifndef FW_SIGNING_H
#define FW_SIGNING_H

#include "config.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * OTA Image Header
 *============================================================================*/
#define FW_MAGIC 0x5449544E /* 'TITN' */
#define FW_HEADER_SIZE 48
#define FW_HMAC_SIZE 32                /* SHA-256 HMAC */
#define FW_MAX_IMAGE_SIZE (128 * 1024) /* 128KB max firmware */

typedef struct __attribute__((packed)) {
  uint32_t magic;             /* Must be FW_MAGIC */
  uint32_t version;           /* Monotonic version counter */
  uint32_t image_size;        /* Payload size (after header) */
  uint32_t flags;             /* Reserved for future use */
  uint8_t hmac[FW_HMAC_SIZE]; /* HMAC-SHA256 over payload */
} fw_header_t;

/*============================================================================
 * Verification Result
 *============================================================================*/
typedef enum {
  FW_VERIFY_OK = 0x00,
  FW_VERIFY_BAD_MAGIC = 0x01,
  FW_VERIFY_TOO_LARGE = 0x02,
  FW_VERIFY_BAD_HMAC = 0x03,
  FW_VERIFY_ROLLBACK = 0x04, /* Version <= current */
  FW_VERIFY_NOT_CHECKED = 0xFF
} fw_verify_result_t;

/*============================================================================
 * Current firmware version (incremented with each OTA)
 *============================================================================*/
static volatile uint32_t current_fw_version = 1; /* TODO: Read from flash */

/*============================================================================
 * HMAC-SHA256 Stub
 *============================================================================*/
/**
 * @brief Compute HMAC-SHA256 over data.
 *
 * ★ Integration: Replace with hardware-accelerated SHA-256
 *   (STM32L476 has HASH peripheral) or software implementation.
 *
 * @param key      HMAC key (32 bytes from OTP)
 * @param key_len  Key length
 * @param data     Data to authenticate
 * @param data_len Data length
 * @param out      Output HMAC (32 bytes)
 */
static inline void fw_hmac_sha256(const uint8_t *key, uint16_t key_len,
                                  const uint8_t *data, uint32_t data_len,
                                  uint8_t *out) {
  /* TODO: Implement HMAC-SHA256 using STM32 HASH peripheral
   *       or software library (e.g., mbedTLS, tinycrypt)
   *
   * For now: zero-fill (MUST be replaced before production)
   */
  (void)key;
  (void)key_len;
  (void)data;
  (void)data_len;
  memset(out, 0, FW_HMAC_SIZE);
}

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Verify an OTA firmware image header.
 *
 * Checks (in order):
 *   1. Magic number
 *   2. Image size within bounds
 *   3. Anti-rollback: version > current
 *   4. HMAC-SHA256 integrity
 *
 * ★ P2 #35a: Each check uses double verification pattern:
 *   bool ok1 = check_positive();
 *   bool ok2 = !check_negative();
 *   if (ok1 && ok2 && (ok1 == ok2)) { accept; }
 *
 * @param header   Pointer to 48-byte OTA header
 * @param payload  Pointer to firmware payload
 * @return fw_verify_result_t
 */
static inline fw_verify_result_t fw_verify_image(const fw_header_t *header,
                                                 const uint8_t *payload) {
#if !SECURITY_FW_SIGNING
  return FW_VERIFY_OK; /* Signing disabled (development only) */
#endif

  if (header == NULL || payload == NULL)
    return FW_VERIFY_BAD_MAGIC;

  /* Check 1: Magic */
  volatile bool magic_ok = (header->magic == FW_MAGIC);
  volatile bool magic_ok2 = !(header->magic != FW_MAGIC);
  if (!magic_ok || !magic_ok2 || (magic_ok != magic_ok2))
    return FW_VERIFY_BAD_MAGIC;

  /* Check 2: Size */
  volatile bool size_ok = (header->image_size <= FW_MAX_IMAGE_SIZE);
  volatile bool size_ok2 = !(header->image_size > FW_MAX_IMAGE_SIZE);
  if (!size_ok || !size_ok2 || (size_ok != size_ok2))
    return FW_VERIFY_TOO_LARGE;

  /* Check 3: Anti-rollback */
  volatile bool ver_ok = (header->version > current_fw_version);
  volatile bool ver_ok2 = !(header->version <= current_fw_version);
  if (!ver_ok || !ver_ok2 || (ver_ok != ver_ok2))
    return FW_VERIFY_ROLLBACK;

  /* Check 4: HMAC-SHA256 */
  uint8_t computed_hmac[FW_HMAC_SIZE];
  uint8_t otp_key[32] = {0}; /* TODO: Read from MCU OTP */

  fw_hmac_sha256(otp_key, 32, payload, header->image_size, computed_hmac);

  /* Constant-time comparison (★ P5 #44 principle) */
  volatile uint8_t diff = 0;
  for (int i = 0; i < FW_HMAC_SIZE; i++) {
    diff |= (computed_hmac[i] ^ header->hmac[i]);
  }

  volatile bool hmac_ok = (diff == 0);
  volatile bool hmac_ok2 = !(diff != 0);
  if (!hmac_ok || !hmac_ok2 || (hmac_ok != hmac_ok2))
    return FW_VERIFY_BAD_HMAC;

  return FW_VERIFY_OK;
}

/**
 * @brief Quick pre-auth check (first 32 bytes only).
 *        ★ P6 #72a: OTA Wear-Out Protection
 *
 * Validates header BEFORE writing anything to flash.
 * If pre-auth fails, no flash write occurs → flash lifetime preserved.
 */
static inline bool fw_pre_auth(const uint8_t *first_48_bytes) {
  const fw_header_t *hdr = (const fw_header_t *)first_48_bytes;

  if (hdr->magic != FW_MAGIC)
    return false;
  if (hdr->image_size > FW_MAX_IMAGE_SIZE)
    return false;
  if (hdr->version <= current_fw_version)
    return false;

  return true; /* Proceed to full download + HMAC check */
}

#endif /* FW_SIGNING_H */
