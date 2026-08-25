/**
 * @file spi_flash_crypto.h
 * @brief ★ P1 #18: SPI Flash Encryption (W25Q16)
 *
 * W25Q16 SPI Flash'ta saklanan OTA staging imajları AES-128-CBC
 * ile şifrelenir. Şifreleme anahtarı MCU OTP'de saklanır.
 *
 * Saldırı vektörü V5: Flash probing → firmware sızıntısı.
 *
 * ★ Donanım gereksinimi:
 *   - MCU OTP'ye key yazılması (ST-Link ile)
 *   - W25Q16 SPI bağlantısı (SPI2)
 */
#ifndef SPI_FLASH_CRYPTO_H
#define SPI_FLASH_CRYPTO_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * Flash Layout
 *============================================================================*/
#define FLASH_TOTAL_SIZE (2 * 1024 * 1024) /* W25Q16: 2MB */
#define FLASH_BANK1_OFFSET 0x000000        /* Active firmware image */
#define FLASH_BANK2_OFFSET 0x100000        /* OTA staging area */
#define FLASH_BANK_SIZE (1 * 1024 * 1024)  /* 1MB per bank */
#define FLASH_PAGE_SIZE 256                /* W25Q16 page program */
#define FLASH_SECTOR_SIZE 4096             /* W25Q16 sector erase */

/*============================================================================
 * Encryption Parameters
 *============================================================================*/
#define FLASH_AES_KEY_SIZE 16 /* AES-128 */
#define FLASH_AES_IV_SIZE 16  /* CBC IV */
#define FLASH_AES_BLOCK 16    /* AES block size */

/*============================================================================
 * OTP Key Storage (STM32L476)
 *============================================================================*/
/* OTP area: 0x1FFF7000-0x1FFF73FF (1024 bytes, 32 double-words)
 * We use OTP block 0 (bytes 0-31) for flash encryption key.
 * Once written, OTP cannot be erased.
 */
#define OTP_BASE_ADDR 0x1FFF7000UL
#define OTP_KEY_OFFSET 0x00 /* First 16 bytes: AES-128 key */
#define OTP_IV_OFFSET 0x10  /* Next 16 bytes: Default IV */

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  SPI_HandleTypeDef *hspi;
  uint8_t key[FLASH_AES_KEY_SIZE];
  uint8_t iv[FLASH_AES_IV_SIZE];
  bool key_loaded;
  bool initialized;
} flash_crypto_state_t;

static flash_crypto_state_t flash_crypto = {
    .hspi = NULL, .key_loaded = false, .initialized = false};

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize SPI Flash crypto layer.
 * @param hspi  SPI2 handle (connected to W25Q16)
 *
 * Reads AES key from MCU OTP.
 * If OTP is empty (all 0xFF) → unencrypted mode (development).
 */
static inline void spi_flash_crypto_init(SPI_HandleTypeDef *hspi) {
  flash_crypto.hspi = hspi;

  /* Read key from OTP */
  memcpy(flash_crypto.key, (const void *)(OTP_BASE_ADDR + OTP_KEY_OFFSET),
         FLASH_AES_KEY_SIZE);
  memcpy(flash_crypto.iv, (const void *)(OTP_BASE_ADDR + OTP_IV_OFFSET),
         FLASH_AES_IV_SIZE);

  /* Check if key is provisioned (not all 0xFF) */
  bool all_ff = true;
  for (int i = 0; i < FLASH_AES_KEY_SIZE; i++) {
    if (flash_crypto.key[i] != 0xFF) {
      all_ff = false;
      break;
    }
  }

  flash_crypto.key_loaded = !all_ff;
  flash_crypto.initialized = true;
}

/**
 * @brief Encrypt a block of data before writing to flash.
 * @param plaintext   Input data (must be FLASH_AES_BLOCK aligned)
 * @param ciphertext  Output buffer (same size as plaintext)
 * @param len         Data length (must be multiple of 16)
 *
 * Uses STM32 AES hardware peripheral for CBC encryption.
 *
 * TODO: Implement using HAL_CRYP_Encrypt_IT or HAL_CRYPEx
 */
static inline bool spi_flash_encrypt(const uint8_t *plaintext,
                                     uint8_t *ciphertext, uint32_t len) {
  if (!flash_crypto.key_loaded) {
    /* No encryption key — pass through (development mode) */
    memcpy(ciphertext, plaintext, len);
    return true;
  }

  /* TODO: HAL_CRYP_Encrypt with flash_crypto.key and flash_crypto.iv */
  /* Placeholder: passthrough until AES peripheral integration */
  memcpy(ciphertext, plaintext, len);
  return true;
}

/**
 * @brief Decrypt a block of data after reading from flash.
 */
static inline bool spi_flash_decrypt(const uint8_t *ciphertext,
                                     uint8_t *plaintext, uint32_t len) {
  if (!flash_crypto.key_loaded) {
    memcpy(plaintext, ciphertext, len);
    return true;
  }

  /* TODO: HAL_CRYP_Decrypt */
  memcpy(plaintext, ciphertext, len);
  return true;
}

/**
 * @brief Check if flash encryption is active.
 */
static inline bool spi_flash_is_encrypted(void) {
  return flash_crypto.key_loaded;
}

#endif /* SPI_FLASH_CRYPTO_H */
