/**
 * @file cobs_framing.h
 * @brief COBS Encode/Decode — Symmetric with Rust hidra_net::cobs
 *
 * MCU tarafinda Rust ile birebir ayni algoritma.
 * 0x00 delimiter ile frame siniri belirlenir.
 */
#ifndef CALLWHITE_COBS_FRAMING_H
#define CALLWHITE_COBS_FRAMING_H

#include "config.h"
#include <stddef.h>
#include <stdint.h>


typedef enum {
  COBS_OK = 0,
  COBS_ERR_EMPTY,
  COBS_ERR_UNEXPECTED_ZERO,
  COBS_ERR_OVERFLOW,
  COBS_ERR_INVALID,
} cobs_status_t;

/**
 * COBS encode: input -> 0x00-free output.
 * @param input    Source data
 * @param in_len   Source length
 * @param output   Destination buffer (must be >= in_len + in_len/254 + 2)
 * @param out_len  [out] Actual encoded length
 * @return COBS_OK on success
 */
cobs_status_t cobs_encode(const uint8_t *input, size_t in_len, uint8_t *output,
                          size_t *out_len);

/**
 * COBS decode: 0x00-free input -> original data.
 * @param input    COBS encoded data (without 0x00 delimiter)
 * @param in_len   Encoded length
 * @param output   Destination buffer
 * @param out_len  [out] Actual decoded length
 * @return COBS_OK on success
 */
cobs_status_t cobs_decode(const uint8_t *input, size_t in_len, uint8_t *output,
                          size_t *out_len);

/**
 * Frame accumulator: collects UART bytes, yields complete COBS frames.
 */
typedef struct {
  uint8_t buffer[COBS_MAX_FRAME_SIZE];
  size_t count;
} cobs_accumulator_t;

/** Initialize accumulator */
void cobs_acc_init(cobs_accumulator_t *acc);

/**
 * Feed one byte to accumulator.
 * @param acc       Accumulator
 * @param byte      Input byte
 * @param frame_out [out] Complete frame buffer (if delimiter received)
 * @param frame_len [out] Frame length (0 if no complete frame)
 * @return COBS_OK, or COBS_ERR_OVERFLOW if frame too large
 */
cobs_status_t cobs_acc_feed(cobs_accumulator_t *acc, uint8_t byte,
                            const uint8_t **frame_out, size_t *frame_len);

/** Reset accumulator state */
void cobs_acc_reset(cobs_accumulator_t *acc);

/** Init COBS module */
void cobs_framing_init(void);

#endif /* CALLWHITE_COBS_FRAMING_H */
