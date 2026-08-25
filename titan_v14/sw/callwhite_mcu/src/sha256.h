/**
 * @file sha256.h
 * @brief FIPS 180-4 SHA-256 Implementation (Software)
 *
 * Tam SHA-256 implementasyonu — stub DEĞİL.
 * Referans: NIST FIPS 180-4, Section 6.2
 *
 * Kullanım:
 *   uint8_t hash[32];
 *   sha256(input, input_len, hash);
 */
#ifndef SHA256_H
#define SHA256_H

#include <stdint.h>
#include <string.h>

/*============================================================================
 * SHA-256 Constants (FIPS 180-4, Section 4.2.2)
 *============================================================================*/
static const uint32_t sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

/*============================================================================
 * SHA-256 Helper Macros (FIPS 180-4, Section 4.1.2)
 *============================================================================*/
#define SHA256_ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define SHA256_CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define SHA256_MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define SHA256_EP0(x)                                                          \
  (SHA256_ROTR(x, 2) ^ SHA256_ROTR(x, 13) ^ SHA256_ROTR(x, 22))
#define SHA256_EP1(x)                                                          \
  (SHA256_ROTR(x, 6) ^ SHA256_ROTR(x, 11) ^ SHA256_ROTR(x, 25))
#define SHA256_SIG0(x) (SHA256_ROTR(x, 7) ^ SHA256_ROTR(x, 18) ^ ((x) >> 3))
#define SHA256_SIG1(x) (SHA256_ROTR(x, 17) ^ SHA256_ROTR(x, 19) ^ ((x) >> 10))

/*============================================================================
 * SHA-256 Context
 *============================================================================*/
typedef struct {
  uint32_t state[8];
  uint8_t buffer[64];
  uint64_t bitcount;
  uint8_t buflen;
} sha256_ctx_t;

/*============================================================================
 * Internal: Process one 512-bit block (FIPS 180-4, Section 6.2.2)
 *============================================================================*/
static inline void sha256_transform(sha256_ctx_t *ctx,
                                    const uint8_t block[64]) {
  uint32_t W[64];
  uint32_t a, b, c, d, e, f, g, h;
  uint32_t t1, t2;

  /* Prepare message schedule (Section 6.2.2, step 1) */
  for (int i = 0; i < 16; i++) {
    W[i] = ((uint32_t)block[i * 4 + 0] << 24) |
           ((uint32_t)block[i * 4 + 1] << 16) |
           ((uint32_t)block[i * 4 + 2] << 8) | ((uint32_t)block[i * 4 + 3]);
  }
  for (int i = 16; i < 64; i++) {
    W[i] =
        SHA256_SIG1(W[i - 2]) + W[i - 7] + SHA256_SIG0(W[i - 15]) + W[i - 16];
  }

  /* Initialize working variables (Section 6.2.2, step 2) */
  a = ctx->state[0];
  b = ctx->state[1];
  c = ctx->state[2];
  d = ctx->state[3];
  e = ctx->state[4];
  f = ctx->state[5];
  g = ctx->state[6];
  h = ctx->state[7];

  /* 64 rounds (Section 6.2.2, step 3) */
  for (int i = 0; i < 64; i++) {
    t1 = h + SHA256_EP1(e) + SHA256_CH(e, f, g) + sha256_k[i] + W[i];
    t2 = SHA256_EP0(a) + SHA256_MAJ(a, b, c);
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }

  /* Compute intermediate hash (Section 6.2.2, step 4) */
  ctx->state[0] += a;
  ctx->state[1] += b;
  ctx->state[2] += c;
  ctx->state[3] += d;
  ctx->state[4] += e;
  ctx->state[5] += f;
  ctx->state[6] += g;
  ctx->state[7] += h;
}

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize SHA-256 context.
 *        Initial hash values from FIPS 180-4, Section 5.3.3.
 */
static inline void sha256_init(sha256_ctx_t *ctx) {
  ctx->state[0] = 0x6a09e667;
  ctx->state[1] = 0xbb67ae85;
  ctx->state[2] = 0x3c6ef372;
  ctx->state[3] = 0xa54ff53a;
  ctx->state[4] = 0x510e527f;
  ctx->state[5] = 0x9b05688c;
  ctx->state[6] = 0x1f83d9ab;
  ctx->state[7] = 0x5be0cd19;
  ctx->bitcount = 0;
  ctx->buflen = 0;
}

/**
 * @brief Feed data to SHA-256.
 * @param ctx   SHA-256 context
 * @param data  Input data
 * @param len   Input length in bytes
 */
static inline void sha256_update(sha256_ctx_t *ctx, const uint8_t *data,
                                 uint32_t len) {
  for (uint32_t i = 0; i < len; i++) {
    ctx->buffer[ctx->buflen++] = data[i];
    ctx->bitcount += 8;
    if (ctx->buflen == 64) {
      sha256_transform(ctx, ctx->buffer);
      ctx->buflen = 0;
    }
  }
}

/**
 * @brief Finalize SHA-256 and produce 32-byte digest.
 *        Implements padding per FIPS 180-4, Section 5.1.1.
 * @param ctx   SHA-256 context
 * @param hash  Output buffer (32 bytes)
 */
static inline void sha256_final(sha256_ctx_t *ctx, uint8_t hash[32]) {
  /* Append '1' bit */
  ctx->buffer[ctx->buflen++] = 0x80;

  /* If not enough room for 8-byte length, pad and process */
  if (ctx->buflen > 56) {
    while (ctx->buflen < 64)
      ctx->buffer[ctx->buflen++] = 0x00;
    sha256_transform(ctx, ctx->buffer);
    ctx->buflen = 0;
  }

  /* Pad to 56 bytes */
  while (ctx->buflen < 56)
    ctx->buffer[ctx->buflen++] = 0x00;

  /* Append 64-bit bit count (big-endian) */
  ctx->buffer[56] = (uint8_t)(ctx->bitcount >> 56);
  ctx->buffer[57] = (uint8_t)(ctx->bitcount >> 48);
  ctx->buffer[58] = (uint8_t)(ctx->bitcount >> 40);
  ctx->buffer[59] = (uint8_t)(ctx->bitcount >> 32);
  ctx->buffer[60] = (uint8_t)(ctx->bitcount >> 24);
  ctx->buffer[61] = (uint8_t)(ctx->bitcount >> 16);
  ctx->buffer[62] = (uint8_t)(ctx->bitcount >> 8);
  ctx->buffer[63] = (uint8_t)(ctx->bitcount);
  sha256_transform(ctx, ctx->buffer);

  /* Produce big-endian hash output */
  for (int i = 0; i < 8; i++) {
    hash[i * 4 + 0] = (uint8_t)(ctx->state[i] >> 24);
    hash[i * 4 + 1] = (uint8_t)(ctx->state[i] >> 16);
    hash[i * 4 + 2] = (uint8_t)(ctx->state[i] >> 8);
    hash[i * 4 + 3] = (uint8_t)(ctx->state[i]);
  }

  /* Clear context (security) */
  memset(ctx, 0, sizeof(sha256_ctx_t));
}

/**
 * @brief One-shot SHA-256 convenience function.
 * @param data   Input data
 * @param len    Input length in bytes
 * @param hash   Output buffer (32 bytes)
 */
static inline void sha256(const uint8_t *data, uint32_t len, uint8_t hash[32]) {
  sha256_ctx_t ctx;
  sha256_init(&ctx);
  sha256_update(&ctx, data, len);
  sha256_final(&ctx, hash);
}

#endif /* SHA256_H */
