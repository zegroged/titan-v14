/**
 * @file cobs_framing.c
 * @brief COBS Encode/Decode Implementation — Symmetric with Rust
 */

#include "cobs_framing.h"
#include <string.h>

/*============================================================================
 * COBS ENCODE
 *============================================================================*/
cobs_status_t cobs_encode(const uint8_t *input, size_t in_len, uint8_t *output,
                          size_t *out_len) {
  size_t read_idx = 0;
  size_t write_idx = 0;

  while (read_idx < in_len) {
    /* Find next 0x00 or 254-byte boundary */
    size_t block_start = read_idx;
    while (read_idx < in_len && input[read_idx] != 0x00 &&
           (read_idx - block_start) < 254) {
      read_idx++;
    }

    size_t block_len = read_idx - block_start;

    /* Write code byte */
    output[write_idx++] = (uint8_t)(block_len + 1);

    /* Write data block */
    memcpy(&output[write_idx], &input[block_start], block_len);
    write_idx += block_len;

    /* If we stopped at 0x00, skip it */
    if (read_idx < in_len && input[read_idx] == 0x00) {
      read_idx++;
    }
  }

  /* Trailing code byte if input empty or ends with 0x00 */
  if (in_len == 0 || input[in_len - 1] == 0x00) {
    output[write_idx++] = 0x01;
  }

  *out_len = write_idx;
  return COBS_OK;
}

/*============================================================================
 * COBS DECODE
 *============================================================================*/
cobs_status_t cobs_decode(const uint8_t *input, size_t in_len, uint8_t *output,
                          size_t *out_len) {
  if (in_len == 0) {
    return COBS_ERR_EMPTY;
  }

  size_t read_idx = 0;
  size_t write_idx = 0;

  while (read_idx < in_len) {
    uint8_t code = input[read_idx];

    if (code == 0x00) {
      return COBS_ERR_UNEXPECTED_ZERO;
    }

    read_idx++;
    size_t data_count = code - 1;

    if (read_idx + data_count > in_len) {
      return COBS_ERR_INVALID;
    }

    for (size_t i = 0; i < data_count; i++) {
      if (input[read_idx + i] == 0x00) {
        return COBS_ERR_UNEXPECTED_ZERO;
      }
      output[write_idx++] = input[read_idx + i];
    }

    read_idx += data_count;

    /* Insert 0x00 if code < 0xFF and more data follows */
    if (code < 0xFF && read_idx < in_len) {
      output[write_idx++] = 0x00;
    }
  }

  *out_len = write_idx;
  return COBS_OK;
}

/*============================================================================
 * FRAME ACCUMULATOR
 *============================================================================*/
void cobs_acc_init(cobs_accumulator_t *acc) { acc->count = 0; }

cobs_status_t cobs_acc_feed(cobs_accumulator_t *acc, uint8_t byte,
                            const uint8_t **frame_out, size_t *frame_len) {
  *frame_out = NULL;
  *frame_len = 0;

  if (byte == COBS_DELIMITER) {
    if (acc->count > 0) {
      *frame_out = acc->buffer;
      *frame_len = acc->count;
      acc->count = 0;
    }
    return COBS_OK;
  }

  if (acc->count >= COBS_MAX_FRAME_SIZE) {
    acc->count = 0; /* Discard oversized frame */
    return COBS_ERR_OVERFLOW;
  }

  acc->buffer[acc->count++] = byte;
  return COBS_OK;
}

void cobs_acc_reset(cobs_accumulator_t *acc) { acc->count = 0; }

void cobs_framing_init(void) { /* No global state to init */ }
