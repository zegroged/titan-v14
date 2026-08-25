/**
 * @file ota_manager.h
 * @brief ★ P2 #31: OTA Update Manager + #32 Recovery Mode
 *
 * OTA akışı: Download → Verify (fw_signing) → Flash → Reboot
 * Recovery: WDT timeout veya tuş kombinasyonu → safe mode
 *
 * ★ #34: PVD Last-Gasp: Düşük voltajda SRAM key wipe
 * ★ #39: Sealed Recovery: Recovery mode'da key erişimi yok
 */
#ifndef OTA_MANAGER_H
#define OTA_MANAGER_H

#include "config.h"
#include "fw_signing.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/*============================================================================
 * OTA State Machine
 *============================================================================*/
typedef enum {
  OTA_IDLE,
  OTA_DOWNLOADING,   /* MQTT'den imaj indiriliyor */
  OTA_DOWNLOADED,    /* İndirme tamamlandı */
  OTA_VERIFYING,     /* HMAC-SHA256 doğrulama */
  OTA_VERIFIED,      /* İmaj geçerli */
  OTA_FLASHING,      /* SPI Flash'a yazılıyor */
  OTA_FLASHED,       /* Yazma tamamlandı */
  OTA_REBOOTING,     /* Yeniden başlatma */
  OTA_ERROR,         /* Hata (geri dönülebilir) */
  OTA_CRITICAL_ERROR /* Kritik hata (kill tetikle) */
} ota_state_t;

typedef struct {
  ota_state_t state;
  uint32_t bytes_received;
  uint32_t total_bytes;
  uint8_t progress_pct;
  fw_verify_result_t verify_result;
  uint8_t retry_count;
  bool rollback_available; /* Bank swap mevcut */
} ota_state_data_t;

static ota_state_data_t ota = {.state = OTA_IDLE,
                               .bytes_received = 0,
                               .total_bytes = 0,
                               .progress_pct = 0,
                               .verify_result = FW_VERIFY_NOT_CHECKED,
                               .retry_count = 0,
                               .rollback_available = false};

/*============================================================================
 * Recovery Mode (#32 + #39)
 *============================================================================*/
typedef enum {
  RECOVERY_NONE,
  RECOVERY_WATCHDOG, /* WDT timeout → recovery boot */
  RECOVERY_USER,     /* Tuş kombinasyonu (A+D basılı boot) */
  RECOVERY_OTA_FAIL  /* OTA doğrulama hatası → recovery */
} recovery_reason_t;

typedef struct {
  bool active;
  recovery_reason_t reason;
  bool keys_sealed; /* ★ #39: Recovery'de key erişimi yok */
} recovery_state_t;

static recovery_state_t recovery = {
    .active = false,
    .reason = RECOVERY_NONE,
    .keys_sealed = true /* Default: key erişimi kapalı */
};

/*============================================================================
 * PVD Last-Gasp (#34)
 *============================================================================*/

/**
 * @brief PVD interrupt handler — call from PVD_IRQHandler.
 *
 * Düşük voltaj tespitinde:
 *   1. AES key'leri SRAM'den sil
 *   2. Session state'i flash'a sync et
 *   3. OLED "LOW BATTERY" uyarısı
 *   4. Kill signal tetikle
 */
static inline void pvd_last_gasp_handler(void) {
  /* 1. SRAM key wipe (kritik!) */
  /* TODO: volatile memset tüm key buffer'ları */

  /* 2. Session state → flash (eğer supercap yeterse) */
  /* TODO: flash_sync_session() */

  /* 3. Kill signal */
  /* HAL_GPIO_WritePin(GPIOC, PIN_FPGA_KILL, GPIO_PIN_SET); */
}

/*============================================================================
 * OTA API
 *============================================================================*/

/**
 * @brief Start OTA download.
 * @param total_size  Expected image size (from MQTT header)
 * @return true if OTA can start
 */
static inline bool ota_start(uint32_t total_size) {
  if (ota.state != OTA_IDLE && ota.state != OTA_ERROR)
    return false;

  if (total_size > FW_MAX_IMAGE_SIZE + FW_HEADER_SIZE)
    return false;

  ota.state = OTA_DOWNLOADING;
  ota.bytes_received = 0;
  ota.total_bytes = total_size;
  ota.progress_pct = 0;
  ota.retry_count = 0;
  return true;
}

/**
 * @brief Feed downloaded chunk.
 * @param data  Chunk data
 * @param len   Chunk length
 */
static inline void ota_feed_chunk(const uint8_t *data, uint16_t len) {
  if (ota.state != OTA_DOWNLOADING)
    return;

  /* TODO: Write to SPI Flash Bank 2 (staging area) */
  (void)data;

  ota.bytes_received += len;
  ota.progress_pct = (uint8_t)((ota.bytes_received * 100) / ota.total_bytes);

  if (ota.bytes_received >= ota.total_bytes) {
    ota.state = OTA_DOWNLOADED;
  }
}

/**
 * @brief Verify downloaded image.
 * @return fw_verify_result_t
 */
static inline fw_verify_result_t ota_verify(void) {
  if (ota.state != OTA_DOWNLOADED)
    return FW_VERIFY_NOT_CHECKED;

  ota.state = OTA_VERIFYING;

  /* TODO: Read header from Flash Bank 2
   *       Call fw_verify_image(header, payload)
   */
  ota.verify_result = FW_VERIFY_OK; /* STUB */
  ota.state = (ota.verify_result == FW_VERIFY_OK) ? OTA_VERIFIED : OTA_ERROR;

  return ota.verify_result;
}

/**
 * @brief Apply verified update (swap banks + reboot).
 */
static inline void ota_apply(void) {
  if (ota.state != OTA_VERIFIED)
    return;

  ota.state = OTA_FLASHING;
  /* TODO: Mark Bank 2 as active, set reboot flag */

  ota.state = OTA_REBOOTING;
  /* NVIC_SystemReset(); */
}

/**
 * @brief Check if recovery mode should be entered.
 * @param wdt_reset  True if last reset was from WDT
 * @param keyA_held  True if KEY_A was held during boot
 * @param keyD_held  True if KEY_D was held during boot
 */
static inline void recovery_check(bool wdt_reset, bool keyA_held,
                                  bool keyD_held) {
  if (wdt_reset) {
    recovery.active = true;
    recovery.reason = RECOVERY_WATCHDOG;
    recovery.keys_sealed = true; /* ★ #39 */
  } else if (keyA_held && keyD_held) {
    recovery.active = true;
    recovery.reason = RECOVERY_USER;
    recovery.keys_sealed = true; /* ★ #39 */
  }
}

static inline bool recovery_is_active(void) { return recovery.active; }
static inline bool recovery_keys_sealed(void) { return recovery.keys_sealed; }

#endif /* OTA_MANAGER_H */
