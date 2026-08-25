/**
 * @file spi_ascon.h
 * @brief ★ P1 #23: SPI ASCON-128 Link Encryption (MCU ↔ FPGA)
 *
 * MCU ve FPGA arasındaki SPI hatlarını ASCON-128-AEAD ile şifreler.
 * NIST Lightweight Cryptography Competition (2023) kazananı.
 *
 * Üretimde: MCU OTP + FPGA eFUSE'a aynı "Hardware Link Key" yazılır.
 * Her SPI frame: ASCON-128-AEAD(link_key, frame_counter, cmd+payload)
 *
 * Neden AES değil:
 *   - AES core FPGA'da comm_protocol için zaten meşgul
 *   - ASCON paralel çalışır (~300 LUT FPGA, ~2KB MCU)
 *   - AEAD: hem şifreleme hem bütünlük tek operasyonda
 *
 * Saldırı vektörü V19: PCB SPI probing → key/command sızıntısı.
 */
#ifndef SPI_ASCON_H
#define SPI_ASCON_H

#include "config.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * ASCON-128 Parameters
 *============================================================================*/
#define ASCON_KEY_SIZE 16   /* 128-bit key */
#define ASCON_NONCE_SIZE 16 /* 128-bit nonce */
#define ASCON_TAG_SIZE 16   /* 128-bit authentication tag */
#define ASCON_RATE 8        /* ASCON-128 rate (bytes per block) */

/* Maximum SPI frame payload (before ASCON overhead) */
#define SPI_MAX_PAYLOAD 64
/* Maximum encrypted frame: payload + tag */
#define SPI_MAX_ENCRYPTED (SPI_MAX_PAYLOAD + ASCON_TAG_SIZE)

/*============================================================================
 * ASCON-128 State (permutation state: 320 bits = 5 × 64-bit words)
 *============================================================================*/
typedef struct {
  uint64_t x[5];
} ascon_state_t;

/*============================================================================
 * Link Encryption State
 *============================================================================*/
typedef struct {
  uint8_t link_key[ASCON_KEY_SIZE]; /* Hardware link key (from OTP) */
  uint32_t tx_counter;              /* Monotonic TX frame counter */
  uint32_t rx_counter;              /* Expected RX frame counter */
  bool enabled;                     /* Encryption active flag */
  bool initialized;
} spi_ascon_state_t;

static spi_ascon_state_t spi_link = {
    .tx_counter = 0, .rx_counter = 0, .enabled = false, .initialized = false};

/*============================================================================
 * ASCON-128 Permutation (Reference Implementation)
 *============================================================================*/

/* 64-bit rotation */
static inline uint64_t ascon_rotr(uint64_t x, int n) {
  return (x >> n) | (x << (64 - n));
}

/** ASCON round function */
static inline void ascon_round(ascon_state_t *s, uint8_t rc) {
  /* Addition of round constant */
  s->x[2] ^= rc;

  /* Substitution layer (5-bit S-box applied to columns) */
  s->x[0] ^= s->x[4];
  s->x[4] ^= s->x[3];
  s->x[2] ^= s->x[1];
  uint64_t t[5];
  for (int i = 0; i < 5; i++)
    t[i] = ~s->x[i] & s->x[(i + 1) % 5];
  for (int i = 0; i < 5; i++)
    s->x[i] ^= t[(i + 1) % 5];
  s->x[1] ^= s->x[0];
  s->x[0] ^= s->x[4];
  s->x[3] ^= s->x[2];
  s->x[2] = ~s->x[2];

  /* Linear diffusion layer */
  s->x[0] ^= ascon_rotr(s->x[0], 19) ^ ascon_rotr(s->x[0], 28);
  s->x[1] ^= ascon_rotr(s->x[1], 61) ^ ascon_rotr(s->x[1], 39);
  s->x[2] ^= ascon_rotr(s->x[2], 1) ^ ascon_rotr(s->x[2], 6);
  s->x[3] ^= ascon_rotr(s->x[3], 10) ^ ascon_rotr(s->x[3], 17);
  s->x[4] ^= ascon_rotr(s->x[4], 7) ^ ascon_rotr(s->x[4], 41);
}

/** ASCON p^a (a rounds) permutation */
static inline void ascon_permute(ascon_state_t *s, int rounds) {
  static const uint8_t rc[12] = {0xf0, 0xe1, 0xd2, 0xc3, 0xb4, 0xa5,
                                 0x96, 0x87, 0x78, 0x69, 0x5a, 0x4b};
  for (int i = 12 - rounds; i < 12; i++)
    ascon_round(s, rc[i]);
}

/*============================================================================
 * Byte ↔ uint64 Helpers (big-endian)
 *============================================================================*/
static inline uint64_t ascon_load64(const uint8_t *p) {
  uint64_t r = 0;
  for (int i = 0; i < 8; i++)
    r = (r << 8) | p[i];
  return r;
}

static inline void ascon_store64(uint8_t *p, uint64_t x) {
  for (int i = 7; i >= 0; i--) {
    p[i] = (uint8_t)(x & 0xFF);
    x >>= 8;
  }
}

/*============================================================================
 * ASCON-128 AEAD Encrypt
 *============================================================================*/

/**
 * @brief ASCON-128 authenticated encryption.
 * @param key       16-byte key
 * @param nonce     16-byte nonce (must be unique per message)
 * @param ad        Associated data (authenticated but not encrypted)
 * @param ad_len    AD length
 * @param pt        Plaintext
 * @param pt_len    Plaintext length
 * @param ct        Output ciphertext (pt_len bytes)
 * @param tag       Output 16-byte authentication tag
 */
static inline void ascon128_encrypt(const uint8_t key[16],
                                    const uint8_t nonce[16], const uint8_t *ad,
                                    uint32_t ad_len, const uint8_t *pt,
                                    uint32_t pt_len, uint8_t *ct,
                                    uint8_t tag[16]) {
  ascon_state_t s;
  uint64_t K0 = ascon_load64(key);
  uint64_t K1 = ascon_load64(key + 8);
  uint64_t N0 = ascon_load64(nonce);
  uint64_t N1 = ascon_load64(nonce + 8);

  /* Initialization */
  s.x[0] = 0x80400c0600000000ULL; /* IV for ASCON-128 */
  s.x[1] = K0;
  s.x[2] = K1;
  s.x[3] = N0;
  s.x[4] = N1;
  ascon_permute(&s, 12);
  s.x[3] ^= K0;
  s.x[4] ^= K1;

  /* Process associated data */
  if (ad_len > 0) {
    uint32_t i;
    for (i = 0; i + 8 <= ad_len; i += 8) {
      s.x[0] ^= ascon_load64(ad + i);
      ascon_permute(&s, 6);
    }
    /* Last block (padded) */
    uint8_t pad[8] = {0};
    uint32_t rem = ad_len - i;
    memcpy(pad, ad + i, rem);
    pad[rem] = 0x80;
    s.x[0] ^= ascon_load64(pad);
    ascon_permute(&s, 6);
  }
  s.x[4] ^= 1; /* Domain separation */

  /* Encrypt plaintext */
  uint32_t i;
  for (i = 0; i + 8 <= pt_len; i += 8) {
    s.x[0] ^= ascon_load64(pt + i);
    ascon_store64(ct + i, s.x[0]);
    ascon_permute(&s, 6);
  }
  /* Last block */
  uint8_t pad[8] = {0};
  uint32_t rem = pt_len - i;
  memcpy(pad, pt + i, rem);
  pad[rem] = 0x80;
  s.x[0] ^= ascon_load64(pad);
  ascon_store64(pad, s.x[0]);
  memcpy(ct + i, pad, rem);

  /* Finalization */
  s.x[1] ^= K0;
  s.x[2] ^= K1;
  ascon_permute(&s, 12);
  s.x[3] ^= K0;
  s.x[4] ^= K1;

  /* Output tag */
  ascon_store64(tag, s.x[3]);
  ascon_store64(tag + 8, s.x[4]);
}

/*============================================================================
 * SPI Frame Format
 *
 *   [frame_counter: 4B][cmd: 1B][payload_len: 1B][payload: N][tag: 16B]
 *
 * Nonce derivation: nonce = link_key XOR zero-padded(frame_counter)
 * AD (associated data): frame_counter || cmd
 *============================================================================*/

/**
 * @brief Encrypt a SPI frame for transmission.
 *
 * @param cmd        SPI command byte
 * @param payload    Plaintext payload
 * @param pay_len    Payload length (max SPI_MAX_PAYLOAD)
 * @param out        Output buffer (must be >= pay_len + 22)
 * @return Total frame size, or 0 on error
 */
static inline uint16_t spi_ascon_encrypt_frame(uint8_t cmd,
                                               const uint8_t *payload,
                                               uint8_t pay_len, uint8_t *out) {
  if (!spi_link.enabled || pay_len > SPI_MAX_PAYLOAD) {
    /* Passthrough if encryption not enabled */
    out[0] = cmd;
    out[1] = pay_len;
    memcpy(out + 2, payload, pay_len);
    return 2 + pay_len;
  }

  /* Build nonce from counter */
  uint8_t nonce[ASCON_NONCE_SIZE] = {0};
  memcpy(nonce, spi_link.link_key, ASCON_NONCE_SIZE);
  nonce[12] ^= (uint8_t)(spi_link.tx_counter >> 24);
  nonce[13] ^= (uint8_t)(spi_link.tx_counter >> 16);
  nonce[14] ^= (uint8_t)(spi_link.tx_counter >> 8);
  nonce[15] ^= (uint8_t)(spi_link.tx_counter);

  /* Associated data: counter + cmd */
  uint8_t ad[5];
  ad[0] = (uint8_t)(spi_link.tx_counter >> 24);
  ad[1] = (uint8_t)(spi_link.tx_counter >> 16);
  ad[2] = (uint8_t)(spi_link.tx_counter >> 8);
  ad[3] = (uint8_t)(spi_link.tx_counter);
  ad[4] = cmd;

  /* Frame header */
  out[0] = ad[0];
  out[1] = ad[1];
  out[2] = ad[2];
  out[3] = ad[3];
  out[4] = cmd;
  out[5] = pay_len;

  /* Encrypt */
  uint8_t tag[ASCON_TAG_SIZE];
  ascon128_encrypt(spi_link.link_key, nonce, ad, 5, payload, pay_len, out + 6,
                   tag);

  /* Append tag */
  memcpy(out + 6 + pay_len, tag, ASCON_TAG_SIZE);

  spi_link.tx_counter++;
  return 6 + pay_len + ASCON_TAG_SIZE;
}

/**
 * @brief Initialize SPI ASCON link encryption.
 * @param link_key  16-byte hardware link key (from MCU OTP)
 */
static inline void spi_ascon_init(const uint8_t link_key[16]) {
  memcpy(spi_link.link_key, link_key, ASCON_KEY_SIZE);
  spi_link.tx_counter = 0;
  spi_link.rx_counter = 0;
  spi_link.enabled = true;
  spi_link.initialized = true;
}

/**
 * @brief Disable SPI encryption (development mode).
 */
static inline void spi_ascon_disable(void) { spi_link.enabled = false; }

#endif /* SPI_ASCON_H */
