/**
 * @file device_provision.h
 * @brief ★ P1 #16: Per-Device Configuration & Provisioning
 *
 * Üretimde her cihaza özel konfigürasyon SPI üzerinden yüklenir:
 *   - MQTT broker listesi ve failover sırası
 *   - Topic rotation seed (SHA-256 basis)
 *   - Device UUID (96-bit UID + random salt hash)
 *   - Fleet group ID
 *
 * Saldırı vektörü V30: Tüm cihazlar aynı config → tek MQTT broker hedef.
 */
#ifndef DEVICE_PROVISION_H
#define DEVICE_PROVISION_H

#include "config.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * Device Configuration Structure
 *============================================================================*/
#define MAX_BROKERS 3
#define BROKER_URL_LEN 64
#define DEVICE_UUID_LEN 16 /* 128-bit UUID */
#define FLEET_ID_LEN 8

typedef struct __attribute__((packed)) {
  /* Magic + version for validation */
  uint32_t magic;   /* 0x44455650 = 'DEVP' */
  uint16_t version; /* Config format version */
  uint16_t flags;   /* Reserved */

  /* Device identity */
  uint8_t device_uuid[DEVICE_UUID_LEN];
  uint8_t fleet_id[FLEET_ID_LEN];

  /* MQTT broker list (failover order) */
  struct {
    char url[BROKER_URL_LEN];
    uint16_t port;
    uint16_t reserved;
  } brokers[MAX_BROKERS];

  /* Topic rotation seed (per-device) */
  uint8_t topic_seed[32]; /* SHA-256 input for topic derivation */

  /* Checksum */
  uint32_t crc32;
} device_config_t;

#define DEVICE_CONFIG_MAGIC 0x44455650

/*============================================================================
 * State
 *============================================================================*/
static device_config_t dev_config;
static bool dev_config_loaded = false;

/*============================================================================
 * Flash Storage Location
 *============================================================================*/
/* Device config stored in last sector of Bank 1 (protected area) */
#define DEV_CONFIG_FLASH_ADDR 0x0FE000 /* W25Q16 address */

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Load device configuration from SPI flash.
 * @return true if valid config found
 */
static inline bool device_provision_load(void) {
  /* TODO: SPI Flash read from DEV_CONFIG_FLASH_ADDR */
  /* TODO: Verify CRC32 */
  /* TODO: Verify magic == DEVICE_CONFIG_MAGIC */

  /* Placeholder: config not loaded */
  dev_config_loaded = false;
  return false;
}

/**
 * @brief Get current device UUID.
 * @param out  Buffer to receive 16-byte UUID
 * @return true if config is loaded
 */
static inline bool device_get_uuid(uint8_t *out) {
  if (!dev_config_loaded)
    return false;
  memcpy(out, dev_config.device_uuid, DEVICE_UUID_LEN);
  return true;
}

/**
 * @brief Get MQTT broker URL for given index.
 * @param index  Broker index (0 = primary, 1-2 = failover)
 * @return Broker URL string, or NULL if not configured
 */
static inline const char *device_get_broker(uint8_t index) {
  if (!dev_config_loaded || index >= MAX_BROKERS)
    return NULL;
  if (dev_config.brokers[index].url[0] == '\0')
    return NULL;
  return dev_config.brokers[index].url;
}

/**
 * @brief Get MQTT broker port for given index.
 */
static inline uint16_t device_get_broker_port(uint8_t index) {
  if (!dev_config_loaded || index >= MAX_BROKERS)
    return 0;
  return dev_config.brokers[index].port;
}

/**
 * @brief Get topic rotation seed.
 * @param out  Buffer to receive 32-byte seed
 */
static inline bool device_get_topic_seed(uint8_t *out) {
  if (!dev_config_loaded)
    return false;
  memcpy(out, dev_config.topic_seed, 32);
  return true;
}

/**
 * @brief Check if device is provisioned.
 */
static inline bool device_is_provisioned(void) { return dev_config_loaded; }

#endif /* DEVICE_PROVISION_H */
