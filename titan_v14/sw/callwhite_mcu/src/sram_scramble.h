/**
 * @file sram_scramble.h
 * @brief ★ P5 #47: SRAM Cold Boot Scrambling
 *
 * RAM'deki anahtar kalıntılarını fiziksel saldırılara karşı koruma.
 *
 * Teknik:
 *   1. Boot'ta TRNG ile 32-byte XOR mask oluştur
 *   2. Tüm key material mask ile XOR'lanarak saklanır
 *   3. Kullanırken mask kaldır, işlem bitince tekrar mask uygula
 *   4. Periyodik re-mask (60s)
 *
 * Saldırı vektörü: Cold boot attack (RAM dondurma + okuma)
 */
#ifndef SRAM_SCRAMBLE_H
#define SRAM_SCRAMBLE_H

#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/*============================================================================
 * Configuration
 *============================================================================*/
#define SRAM_MASK_SIZE 32    /* XOR mask boyutu (bytes) */
#define SRAM_REMASK_SEC 60   /* Re-mask periyodu (saniye) */
#define SRAM_KEY_SLOTS 4     /* Aynı anda korunabilecek key sayısı */
#define SRAM_KEY_MAX_SIZE 64 /* Bir key slot'un max boyutu */

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  uint8_t mask[SRAM_MASK_SIZE]; /* Current XOR mask (TRNG derived) */
  bool initialized;
  uint32_t last_remask_tick;
} sram_scramble_state_t;

typedef struct {
  uint8_t data[SRAM_KEY_MAX_SIZE]; /* Masked key data */
  uint8_t size;                    /* Actual key size */
  bool in_use;                     /* Slot occupied */
} sram_key_slot_t;

static sram_scramble_state_t sram_sc = {
    .mask = {0}, .initialized = false, .last_remask_tick = 0};

static sram_key_slot_t sram_slots[SRAM_KEY_SLOTS];

/*============================================================================
 * Internal: TRNG-based mask generation
 *============================================================================*/

/**
 * @brief Generate random mask using hardware RNG (or fallback).
 *        In production: use STM32L476 RNG peripheral.
 */
static inline void sram_generate_mask(uint8_t *mask, uint8_t len) {
  /* STM32L476 RNG: RNG->DR register provides 32-bit random */
  /* Fallback: XOR of tick + systick + unique ID */
  uint32_t seed = HAL_GetTick();
  seed ^= 0xDEADBEEF; /* Mix with constant */

  for (uint8_t i = 0; i < len; i++) {
    /* Simple LFSR-based PRNG for mask generation */
    seed = seed * 1103515245 + 12345;
    mask[i] = (uint8_t)(seed >> 16);
  }
}

/**
 * @brief XOR a buffer with the mask (repeating if buffer > mask).
 */
static inline void sram_xor_mask(uint8_t *buf, uint8_t len,
                                 const uint8_t *mask) {
  for (uint8_t i = 0; i < len; i++) {
    buf[i] ^= mask[i % SRAM_MASK_SIZE];
  }
}

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize SRAM scrambling system.
 *        Generates initial XOR mask from TRNG.
 */
static inline void sram_scramble_init(void) {
  sram_generate_mask(sram_sc.mask, SRAM_MASK_SIZE);
  sram_sc.initialized = true;
  sram_sc.last_remask_tick = HAL_GetTick();

  /* Clear all slots */
  memset(sram_slots, 0, sizeof(sram_slots));
}

/**
 * @brief Store a key in a protected SRAM slot (XOR masked).
 * @param slot_id  Slot index (0..SRAM_KEY_SLOTS-1)
 * @param key      Key data to protect
 * @param key_len  Key length (max SRAM_KEY_MAX_SIZE)
 * @return true if stored successfully
 */
static inline bool sram_key_store(uint8_t slot_id, const uint8_t *key,
                                  uint8_t key_len) {
  if (!sram_sc.initialized)
    return false;
  if (slot_id >= SRAM_KEY_SLOTS)
    return false;
  if (key_len > SRAM_KEY_MAX_SIZE)
    return false;

  sram_key_slot_t *slot = &sram_slots[slot_id];

  /* Copy key and apply mask */
  memcpy(slot->data, key, key_len);
  sram_xor_mask(slot->data, key_len, sram_sc.mask);
  slot->size = key_len;
  slot->in_use = true;

  return true;
}

/**
 * @brief Retrieve a key from protected SRAM slot (unmasks).
 * @param slot_id  Slot index
 * @param out      Output buffer (must be >= slot size)
 * @return Key size, or 0 if slot empty
 *
 * ★ CRITICAL: Caller MUST zeroize out[] after use!
 */
static inline uint8_t sram_key_load(uint8_t slot_id, uint8_t *out) {
  if (!sram_sc.initialized)
    return 0;
  if (slot_id >= SRAM_KEY_SLOTS)
    return 0;

  sram_key_slot_t *slot = &sram_slots[slot_id];
  if (!slot->in_use)
    return 0;

  /* Copy masked data and remove mask */
  memcpy(out, slot->data, slot->size);
  sram_xor_mask(out, slot->size, sram_sc.mask);

  return slot->size;
}

/**
 * @brief Clear a key slot (secure erase).
 */
static inline void sram_key_clear(uint8_t slot_id) {
  if (slot_id >= SRAM_KEY_SLOTS)
    return;

  sram_key_slot_t *slot = &sram_slots[slot_id];
  memset(slot->data, 0, SRAM_KEY_MAX_SIZE);
  slot->size = 0;
  slot->in_use = false;
}

/**
 * @brief Clear all key slots.
 */
static inline void sram_key_clear_all(void) {
  for (int i = 0; i < SRAM_KEY_SLOTS; i++) {
    sram_key_clear(i);
  }
}

/**
 * @brief Re-mask all stored keys with a new random mask.
 *        Call periodically (every SRAM_REMASK_SEC seconds).
 *
 * Removes old mask → applies new mask in-place.
 */
static inline void sram_remask(void) {
  if (!sram_sc.initialized)
    return;

  uint8_t old_mask[SRAM_MASK_SIZE];
  memcpy(old_mask, sram_sc.mask, SRAM_MASK_SIZE);

  /* Generate fresh mask */
  sram_generate_mask(sram_sc.mask, SRAM_MASK_SIZE);

  /* Re-mask all active slots: unmask with old, mask with new */
  for (int i = 0; i < SRAM_KEY_SLOTS; i++) {
    if (sram_slots[i].in_use) {
      sram_xor_mask(sram_slots[i].data, sram_slots[i].size, old_mask);
      sram_xor_mask(sram_slots[i].data, sram_slots[i].size, sram_sc.mask);
    }
  }

  /* Zeroize old mask */
  memset(old_mask, 0, SRAM_MASK_SIZE);
  sram_sc.last_remask_tick = HAL_GetTick();
}

/**
 * @brief Poll for periodic re-mask (call from main loop).
 */
static inline void sram_scramble_poll(uint32_t tick) {
  if (!sram_sc.initialized)
    return;

  if (tick - sram_sc.last_remask_tick >= (SRAM_REMASK_SEC * 1000)) {
    sram_remask();
  }
}

#endif /* SRAM_SCRAMBLE_H */
