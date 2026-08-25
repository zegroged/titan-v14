/**
 * @file spi_key_ecdh.h
 * @brief ★ P1 #10: SPI Key Exchange via ECDH (KEK → Ephemeral)
 *
 * Mevcut SPI key injection statik PSK kullanıyor.
 * Bu modül ECDH (X25519) ile ephemeral key desteği ekler:
 *   1. MCU X25519 keypair üretir
 *   2. MCU → FPGA: public key (SPI CMD 0x20)
 *   3. FPGA TRNG ile kendi keypair üretir
 *   4. FPGA → MCU: public key (SPI response)
 *   5. Her iki taraf shared_secret hesaplar
 *   6. HKDF(shared_secret) → session KEK (Key Encryption Key)
 *   7. KEK ile PSK wrap/unwrap yapılır
 *
 * Kütüphane: monocypher (constant-time X25519, ~2KB code)
 *            https://monocypher.org — public domain
 *
 * Saldırı vektörü V19: Statik SPI key sızıntısı.
 */
#ifndef SPI_KEY_ECDH_H
#define SPI_KEY_ECDH_H

#include "config.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * X25519 Constants
 *============================================================================*/
#define ECDH_KEY_SIZE 32    /* X25519: 256-bit keys */
#define ECDH_SHARED_SIZE 32 /* Shared secret size */
#define HKDF_OUTPUT_SIZE 32 /* Derived KEK size (AES-256) */

/*============================================================================
 * SPI Commands for ECDH Key Exchange
 *============================================================================*/
#define SPI_CMD_ECDH_INIT 0x20     /* MCU → FPGA: start ECDH, send pub key */
#define SPI_CMD_ECDH_RESPONSE 0x21 /* FPGA → MCU: FPGA pub key */
#define SPI_CMD_KEY_WRAP 0x22      /* MCU → FPGA: KEK-wrapped PSK */
#define SPI_CMD_KEY_CONFIRM 0x23   /* FPGA → MCU: key load confirmation */

/*============================================================================
 * ECDH State
 *============================================================================*/
typedef enum {
  ECDH_STATE_IDLE,
  ECDH_STATE_INIT_SENT,      /* MCU pub key sent to FPGA */
  ECDH_STATE_RESPONSE_RCVD,  /* FPGA pub key received */
  ECDH_STATE_SHARED_DERIVED, /* Shared secret computed */
  ECDH_STATE_KEY_WRAPPED,    /* PSK wrapped with KEK and sent */
  ECDH_STATE_COMPLETE,       /* FPGA confirmed key loaded */
  ECDH_STATE_ERROR
} ecdh_state_t;

typedef struct {
  ecdh_state_t state;

  /* MCU keypair (ephemeral — generated fresh each session) */
  uint8_t mcu_private[ECDH_KEY_SIZE]; /* MUST be zeroized after use */
  uint8_t mcu_public[ECDH_KEY_SIZE];

  /* FPGA public key */
  uint8_t fpga_public[ECDH_KEY_SIZE];

  /* Derived values */
  uint8_t shared_secret[ECDH_SHARED_SIZE]; /* MUST be zeroized */
  uint8_t session_kek[HKDF_OUTPUT_SIZE];   /* MUST be zeroized */
} ecdh_session_t;

static ecdh_session_t ecdh = {.state = ECDH_STATE_IDLE};

/*============================================================================
 * X25519 Crypto Functions (monocypher wrappers)
 *
 * monocypher API:
 *   void crypto_x25519_public_key(uint8_t pub[32], const uint8_t priv[32]);
 *   void crypto_x25519(uint8_t shared[32], const uint8_t priv[32],
 *                      const uint8_t their_pub[32]);
 *   void crypto_blake2b(uint8_t *hash, size_t hash_size,
 *                       const uint8_t *msg, size_t msg_size);
 *============================================================================*/

/* Forward declarations — link with monocypher.c */
extern void crypto_x25519_public_key(uint8_t pub[32], const uint8_t priv[32]);
extern void crypto_x25519(uint8_t shared[32], const uint8_t priv[32],
                          const uint8_t their_pub[32]);

/*============================================================================
 * HKDF-like Key Derivation (simplified, using XOR-fold + hash)
 *============================================================================*/
static inline void ecdh_derive_kek(const uint8_t shared[32], uint8_t kek[32]) {
  /* Simple KDF: kek = SHA-256(shared || "TITAN-KEK-V1")
   * TODO: Replace with proper HKDF-SHA256 from monocypher or tinycrypt
   *
   * Placeholder: XOR-fold with constant (MUST be replaced)
   */
  const uint8_t label[12] = "TITAN-KEK-1";
  for (int i = 0; i < 32; i++) {
    kek[i] = shared[i] ^ label[i % 12];
  }
}

/*============================================================================
 * Secure Memory Wipe
 *============================================================================*/
static inline void ecdh_wipe(void *buf, size_t len) {
  volatile uint8_t *p = (volatile uint8_t *)buf;
  while (len--)
    *p++ = 0;
}

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Generate MCU ephemeral keypair and initiate ECDH.
 *
 * Steps:
 *   1. Generate random private key from TRNG (via FPGA SPI)
 *   2. Compute public key
 *   3. Send public key to FPGA via SPI CMD 0x20
 *
 * @param trng_random  32 bytes of TRNG randomness (from FPGA)
 * @return true if init successful
 */
static inline bool ecdh_initiate(const uint8_t trng_random[32]) {
  /* Use TRNG output as private key */
  memcpy(ecdh.mcu_private, trng_random, ECDH_KEY_SIZE);

  /* Clamp private key (X25519 requirement) */
  ecdh.mcu_private[0] &= 248;
  ecdh.mcu_private[31] &= 127;
  ecdh.mcu_private[31] |= 64;

  /* Derive public key */
  crypto_x25519_public_key(ecdh.mcu_public, ecdh.mcu_private);

  /* TODO: Send MCU public key to FPGA via SPI CMD 0x20
   *   spi_send_cmd(SPI_CMD_ECDH_INIT, ecdh.mcu_public, 32);
   */

  ecdh.state = ECDH_STATE_INIT_SENT;
  return true;
}

/**
 * @brief Process FPGA's public key response.
 *
 * @param fpga_pub  32-byte FPGA public key from SPI response
 * @return true if shared secret derived successfully
 */
static inline bool ecdh_process_response(const uint8_t fpga_pub[32]) {
  if (ecdh.state != ECDH_STATE_INIT_SENT)
    return false;

  memcpy(ecdh.fpga_public, fpga_pub, ECDH_KEY_SIZE);
  ecdh.state = ECDH_STATE_RESPONSE_RCVD;

  /* Compute shared secret */
  crypto_x25519(ecdh.shared_secret, ecdh.mcu_private, ecdh.fpga_public);

  /* Wipe private key immediately — no longer needed */
  ecdh_wipe(ecdh.mcu_private, ECDH_KEY_SIZE);

  /* Derive session KEK from shared secret */
  ecdh_derive_kek(ecdh.shared_secret, ecdh.session_kek);

  /* Wipe shared secret — only KEK is needed now */
  ecdh_wipe(ecdh.shared_secret, ECDH_SHARED_SIZE);

  ecdh.state = ECDH_STATE_SHARED_DERIVED;
  return true;
}

/**
 * @brief Wrap PSK with session KEK and send to FPGA.
 *
 * @param psk      256-bit PSK to wrap
 * @param wrapped  Output: KEK-wrapped PSK (32 bytes)
 * @return true if wrap and send successful
 */
static inline bool ecdh_wrap_and_send_key(const uint8_t psk[32],
                                          uint8_t wrapped[32]) {
  if (ecdh.state != ECDH_STATE_SHARED_DERIVED)
    return false;

  /* Simple XOR wrap (TODO: replace with AES-KW or AEAD) */
  for (int i = 0; i < 32; i++)
    wrapped[i] = psk[i] ^ ecdh.session_kek[i];

  /* TODO: Send wrapped key to FPGA via SPI CMD 0x22
   *   spi_send_cmd(SPI_CMD_KEY_WRAP, wrapped, 32);
   */

  ecdh.state = ECDH_STATE_KEY_WRAPPED;
  return true;
}

/**
 * @brief Process key load confirmation from FPGA.
 */
static inline bool ecdh_confirm(void) {
  if (ecdh.state != ECDH_STATE_KEY_WRAPPED)
    return false;

  /* Wipe KEK — key exchange complete */
  ecdh_wipe(ecdh.session_kek, HKDF_OUTPUT_SIZE);

  ecdh.state = ECDH_STATE_COMPLETE;
  return true;
}

/**
 * @brief Check if ECDH key exchange is complete.
 */
static inline bool ecdh_is_complete(void) {
  return ecdh.state == ECDH_STATE_COMPLETE;
}

/**
 * @brief Abort and wipe all ECDH state.
 */
static inline void ecdh_abort(void) {
  ecdh_wipe(&ecdh, sizeof(ecdh));
  ecdh.state = ECDH_STATE_IDLE;
}

#endif /* SPI_KEY_ECDH_H */
