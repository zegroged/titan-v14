/**
 * @file secure_element.h
 * @brief ★ P1 #24: ATECC608B Secure Element Driver (I2C)
 *
 * Microchip ATECC608B kripto işlemci — donanımsal anahtar izolasyonu.
 * Anahtar çipten ASLA ÇIKAMAZ — sadece çip-içi crypto operasyonları.
 *
 * Yetenekler:
 *   - 16 adet güvenli key slot (ECC P-256 veya AES-128)
 *   - SHA-256 HMAC donanımsal
 *   - ECDH (P-256) donanımsal
 *   - Monotonic counter (anti-rollback)
 *   - True RNG (ek entropi kaynağı)
 *   - Secure boot digest depolama
 *
 * I2C: PB10 (SCL), PB11 (SDA), adres 0x60 (varsayılan)
 *
 * Saldırı vektörü V35: Sahte bileşen / anahtar sızıntısı.
 */
#ifndef SECURE_ELEMENT_H
#define SECURE_ELEMENT_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * ATECC608B Constants
 *============================================================================*/
#define ATECC_I2C_ADDR 0x60                       /* 7-bit default address */
#define ATECC_I2C_ADDR_8BIT (ATECC_I2C_ADDR << 1) /* HAL 8-bit */
#define ATECC_WAKE_DELAY_US 1500                  /* Wake-up delay */
#define ATECC_CMD_TIMEOUT_MS 50 /* Command execution timeout */
#define ATECC_WORD_SIZE 4       /* Word size for responses */

/* ATECC608B Commands */
#define ATECC_CMD_INFO 0x30
#define ATECC_CMD_READ 0x02
#define ATECC_CMD_WRITE 0x12
#define ATECC_CMD_GENKEY 0x40
#define ATECC_CMD_SIGN 0x41
#define ATECC_CMD_VERIFY 0x45
#define ATECC_CMD_ECDH 0x43
#define ATECC_CMD_SHA 0x47
#define ATECC_CMD_HMAC 0x11
#define ATECC_CMD_NONCE 0x16
#define ATECC_CMD_RANDOM 0x1B
#define ATECC_CMD_COUNTER 0x24
#define ATECC_CMD_LOCK 0x17

/* Key Slots */
#define SLOT_DEVICE_PRIVATE 0 /* Device ECC-P256 private key */
#define SLOT_FLEET_KEY 1      /* Fleet shared symmetric key */
#define SLOT_COMPONENT_IDS 2  /* Golden component ID hashes */
#define SLOT_BOOT_DIGEST 3    /* Secure boot firmware digest */
#define SLOT_HMAC_KEY 4       /* HMAC signing key */
#define SLOT_SPARE_1 5
#define SLOT_SPARE_2 6
#define SLOT_SPARE_3 7

/*============================================================================
 * CRC-16 (ATECC protocol)
 *============================================================================*/
static inline uint16_t atecc_crc16(const uint8_t *data, uint16_t len) {
  uint16_t crc = 0;
  for (uint16_t i = 0; i < len; i++) {
    uint8_t b = data[i];
    for (uint8_t bit = 0; bit < 8; bit++) {
      uint16_t shift = (crc >> 7) ^ (b & 1);
      crc = (crc << 1) & 0xFFFF;
      if (shift & 1)
        crc ^= 0x8005;
      b >>= 1;
    }
  }
  return crc;
}

/*============================================================================
 * State
 *============================================================================*/
typedef enum {
  SE_OK = 0x00,
  SE_ERR_WAKE = 0x01,
  SE_ERR_COMM = 0x02,
  SE_ERR_CRC = 0x03,
  SE_ERR_EXECUTION = 0x04,
  SE_ERR_LOCKED = 0x05,
  SE_NOT_INIT = 0xFF
} se_result_t;

typedef struct {
  I2C_HandleTypeDef *hi2c;
  bool initialized;
  bool data_zone_locked;
  bool config_zone_locked;
  uint8_t serial[9];   /* 9-byte serial number */
  uint8_t revision[4]; /* 4-byte revision */
} se_state_t;

static se_state_t se = {.hi2c = NULL, .initialized = false};

/*============================================================================
 * Low-Level I2C Communication
 *============================================================================*/

/** Wake ATECC608B from sleep (send 0x00 at low speed). */
static inline se_result_t atecc_wake(void) {
  uint8_t zero = 0x00;
  /* Send zero byte at ~100kHz to create wake condition */
  HAL_I2C_Master_Transmit(se.hi2c, 0x00, &zero, 1, 10);
  HAL_Delay(2); /* Wait for wake */

  /* Read 4-byte wake response */
  uint8_t resp[4];
  if (HAL_I2C_Master_Receive(se.hi2c, ATECC_I2C_ADDR_8BIT, resp, 4, 100) !=
      HAL_OK)
    return SE_ERR_WAKE;

  /* Expected: 0x04 0x11 0x33 0x43 */
  if (resp[0] != 0x04 || resp[1] != 0x11)
    return SE_ERR_WAKE;

  return SE_OK;
}

/** Put ATECC608B to sleep. */
static inline void atecc_sleep(void) {
  uint8_t sleep_cmd = 0x01;
  HAL_I2C_Master_Transmit(se.hi2c, ATECC_I2C_ADDR_8BIT, &sleep_cmd, 1, 10);
}

/** Send a command to ATECC608B. */
static inline se_result_t atecc_send_cmd(uint8_t opcode, uint8_t param1,
                                         uint16_t param2, const uint8_t *data,
                                         uint8_t data_len) {
  uint8_t packet[7 + 64]; /* Max packet size */
  uint8_t pkt_len = 7 + data_len;

  /* Build packet:
   * [word_addr][count][opcode][param1][param2L][param2H][data...][crcL][crcH]
   */
  packet[0] = 0x03;        /* Command word address */
  packet[1] = pkt_len - 1; /* Count (everything after word_addr) */
  packet[2] = opcode;
  packet[3] = param1;
  packet[4] = (uint8_t)(param2 & 0xFF);
  packet[5] = (uint8_t)(param2 >> 8);
  if (data_len > 0 && data != NULL)
    memcpy(&packet[6], data, data_len);

  /* CRC over count..data */
  uint16_t crc = atecc_crc16(&packet[1], pkt_len - 3);
  packet[pkt_len - 2] = (uint8_t)(crc & 0xFF);
  packet[pkt_len - 1] = (uint8_t)(crc >> 8);

  if (HAL_I2C_Master_Transmit(se.hi2c, ATECC_I2C_ADDR_8BIT, packet, pkt_len,
                              100) != HAL_OK)
    return SE_ERR_COMM;

  return SE_OK;
}

/** Read response from ATECC608B. */
static inline se_result_t atecc_read_resp(uint8_t *resp, uint8_t *resp_len,
                                          uint16_t timeout_ms) {
  HAL_Delay(timeout_ms);

  uint8_t buf[64];
  if (HAL_I2C_Master_Receive(se.hi2c, ATECC_I2C_ADDR_8BIT, buf, 1, 100) !=
      HAL_OK)
    return SE_ERR_COMM;

  uint8_t count = buf[0];
  if (count < 4 || count > 64)
    return SE_ERR_COMM;

  if (HAL_I2C_Master_Receive(se.hi2c, ATECC_I2C_ADDR_8BIT, buf + 1, count - 1,
                             100) != HAL_OK)
    return SE_ERR_COMM;

  /* Verify CRC */
  uint16_t recv_crc = buf[count - 2] | ((uint16_t)buf[count - 1] << 8);
  uint16_t calc_crc = atecc_crc16(buf, count - 2);
  if (recv_crc != calc_crc)
    return SE_ERR_CRC;

  /* Copy response data (excluding count and CRC) */
  *resp_len = count - 3;
  memcpy(resp, buf + 1, *resp_len);

  return SE_OK;
}

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize ATECC608B secure element.
 * @param hi2c  I2C2 handle (PB10/PB11)
 */
static inline se_result_t secure_element_init(I2C_HandleTypeDef *hi2c) {
  se.hi2c = hi2c;

  /* Wake device */
  se_result_t res = atecc_wake();
  if (res != SE_OK)
    return res;

  /* Read serial number (Info command) */
  res = atecc_send_cmd(ATECC_CMD_INFO, 0x00, 0x0000, NULL, 0);
  if (res != SE_OK) {
    atecc_sleep();
    return res;
  }

  uint8_t info[4];
  uint8_t info_len;
  res = atecc_read_resp(info, &info_len, 5);
  if (res != SE_OK) {
    atecc_sleep();
    return res;
  }

  memcpy(se.revision, info, 4);
  se.initialized = true;

  atecc_sleep();
  return SE_OK;
}

/**
 * @brief Generate 32 bytes of random data from ATECC608B TRNG.
 *        ★ Additional entropy source for MCU operations.
 */
static inline se_result_t secure_element_random(uint8_t out[32]) {
  if (!se.initialized)
    return SE_NOT_INIT;

  se_result_t res = atecc_wake();
  if (res != SE_OK)
    return res;

  res = atecc_send_cmd(ATECC_CMD_RANDOM, 0x00, 0x0000, NULL, 0);
  if (res != SE_OK) {
    atecc_sleep();
    return res;
  }

  uint8_t resp_len;
  res = atecc_read_resp(out, &resp_len, 25);
  atecc_sleep();

  return (resp_len >= 32) ? SE_OK : SE_ERR_EXECUTION;
}

/**
 * @brief Compute HMAC-SHA256 using key in specified slot.
 *        Key never leaves the secure element.
 *
 * @param slot     Key slot (0-7)
 * @param message  Input message
 * @param msg_len  Message length
 * @param hmac     Output 32-byte HMAC
 */
static inline se_result_t secure_element_hmac(uint8_t slot,
                                              const uint8_t *message,
                                              uint16_t msg_len,
                                              uint8_t hmac[32]) {
  if (!se.initialized)
    return SE_NOT_INIT;

  /* ATECC608B HMAC flow:
   * 1. Nonce(message) → load TempKey
   * 2. HMAC(slot) → compute HMAC using internal key
   */
  se_result_t res = atecc_wake();
  if (res != SE_OK)
    return res;

  /* Load message into TempKey via Nonce command */
  res = atecc_send_cmd(ATECC_CMD_NONCE, 0x03, 0x0000, message,
                       (msg_len > 32) ? 32 : msg_len);
  if (res != SE_OK) {
    atecc_sleep();
    return res;
  }

  uint8_t nonce_resp[1];
  uint8_t nonce_len;
  res = atecc_read_resp(nonce_resp, &nonce_len, 10);
  if (res != SE_OK) {
    atecc_sleep();
    return res;
  }

  /* Compute HMAC using slot key */
  res = atecc_send_cmd(ATECC_CMD_HMAC, 0x04, slot, NULL, 0);
  if (res != SE_OK) {
    atecc_sleep();
    return res;
  }

  uint8_t hmac_len;
  res = atecc_read_resp(hmac, &hmac_len, 35);
  atecc_sleep();

  return (hmac_len >= 32) ? SE_OK : SE_ERR_EXECUTION;
}

/**
 * @brief Read monotonic counter value (anti-rollback).
 * @param counter_id  Counter ID (0-1, ATECC608B has 2 counters)
 * @param value       Output counter value
 */
static inline se_result_t secure_element_counter_read(uint8_t counter_id,
                                                      uint32_t *value) {
  if (!se.initialized)
    return SE_NOT_INIT;

  se_result_t res = atecc_wake();
  if (res != SE_OK)
    return res;

  res = atecc_send_cmd(ATECC_CMD_COUNTER, 0x00, counter_id, NULL, 0);
  if (res != SE_OK) {
    atecc_sleep();
    return res;
  }

  uint8_t resp[4];
  uint8_t resp_len;
  res = atecc_read_resp(resp, &resp_len, 10);
  atecc_sleep();

  if (res == SE_OK && resp_len >= 4) {
    *value = resp[0] | (resp[1] << 8) | (resp[2] << 16) | (resp[3] << 24);
  }

  return res;
}

/**
 * @brief Increment monotonic counter (one-way, cannot decrease).
 */
static inline se_result_t secure_element_counter_increment(uint8_t counter_id) {
  if (!se.initialized)
    return SE_NOT_INIT;

  se_result_t res = atecc_wake();
  if (res != SE_OK)
    return res;

  res = atecc_send_cmd(ATECC_CMD_COUNTER, 0x01, counter_id, NULL, 0);
  if (res != SE_OK) {
    atecc_sleep();
    return res;
  }

  uint8_t resp[4];
  uint8_t resp_len;
  res = atecc_read_resp(resp, &resp_len, 10);
  atecc_sleep();

  return res;
}

/**
 * @brief Check if secure element is initialized and responsive.
 */
static inline bool secure_element_is_ready(void) { return se.initialized; }

#endif /* SECURE_ELEMENT_H */
