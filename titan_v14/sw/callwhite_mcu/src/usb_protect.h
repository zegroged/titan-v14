/**
 * @file usb_protect.h
 * @brief ★ P6 #69: USB Surge / Overvoltage Protection
 *
 * USB-C VBUS voltaj izleme + koruma.
 *
 * Özellikler:
 *   - ADC ile VBUS voltaj ölçümü
 *   - Over-voltage (>5.5V): USB LDO disable
 *   - Under-voltage (<4.2V): Şarj disable
 *   - Spike detection: 100ms içinde >1V değişim → alarm
 *
 * NOT: config.h'te USB-C D+/D-/CC bağlantısız (#13),
 *      sadece güç hattı bağlı. Bu modül güç hattını korur.
 */
#ifndef USB_PROTECT_H
#define USB_PROTECT_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>


/*============================================================================
 * Configuration
 *============================================================================*/
#define USB_VBUS_OV_MV 5500      /* Over-voltage threshold (mV) */
#define USB_VBUS_UV_MV 4200      /* Under-voltage threshold (mV) */
#define USB_VBUS_NOMINAL_MV 5000 /* Normal VBUS (mV) */
#define USB_SPIKE_DELTA_MV 1000  /* Max allowed change in 100ms */
#define USB_SPIKE_WINDOW_MS 100

/* ADC conversion: 12-bit ADC, VREF=3.3V, voltage divider 2:1 */
#define USB_ADC_TO_MV(adc) ((uint32_t)(adc) * 3300 * 2 / 4095)

/*============================================================================
 * State
 *============================================================================*/
typedef enum {
  USB_STATUS_OK = 0,
  USB_STATUS_OVERVOLTAGE,
  USB_STATUS_UNDERVOLTAGE,
  USB_STATUS_SPIKE,
  USB_STATUS_DISCONNECTED
} usb_status_t;

typedef struct {
  bool initialized;
  usb_status_t status;
  uint32_t vbus_mv;      /* Current VBUS voltage */
  uint32_t prev_vbus_mv; /* Previous reading */
  uint32_t prev_tick;
  uint32_t ov_count;    /* Overvoltage event count */
  uint32_t spike_count; /* Spike event count */
  bool ldo_disabled;    /* LDO shut off due to OV */
  bool charge_disabled; /* Charging disabled */
} usb_protect_ctx_t;

static usb_protect_ctx_t usb_p = {.initialized = false,
                                  .status = USB_STATUS_DISCONNECTED,
                                  .vbus_mv = 0,
                                  .prev_vbus_mv = 0,
                                  .prev_tick = 0,
                                  .ov_count = 0,
                                  .spike_count = 0,
                                  .ldo_disabled = false,
                                  .charge_disabled = false};

/*============================================================================
 * Internal
 *============================================================================*/

/**
 * @brief Disable USB LDO (cut power from VBUS).
 */
static inline void usb_ldo_disable(void) {
  /* TODO: GPIO to LDO enable pin LOW */
  usb_p.ldo_disabled = true;
}

/**
 * @brief Enable USB LDO.
 */
static inline void usb_ldo_enable(void) {
  /* TODO: GPIO to LDO enable pin HIGH */
  usb_p.ldo_disabled = false;
}

/*============================================================================
 * API
 *============================================================================*/

/**
 * @brief Initialize USB protection.
 */
static inline void usb_protect_init(void) {
  usb_p.initialized = true;
  usb_p.status = USB_STATUS_DISCONNECTED;
  usb_p.ov_count = 0;
  usb_p.spike_count = 0;
}

/**
 * @brief Poll USB voltage and check for anomalies.
 * @param adc_raw  Raw ADC reading from VBUS divider
 * @param tick     Current system tick
 */
static inline void usb_protect_poll(uint16_t adc_raw, uint32_t tick) {
  if (!usb_p.initialized)
    return;

  uint32_t mv = USB_ADC_TO_MV(adc_raw);
  usb_p.vbus_mv = mv;

  /* Disconnected check */
  if (mv < 1000) {
    usb_p.status = USB_STATUS_DISCONNECTED;
    return;
  }

  /* Over-voltage check */
  if (mv > USB_VBUS_OV_MV) {
    usb_p.status = USB_STATUS_OVERVOLTAGE;
    usb_p.ov_count++;
    usb_ldo_disable();
    return;
  }

  /* Under-voltage check */
  if (mv < USB_VBUS_UV_MV) {
    usb_p.status = USB_STATUS_UNDERVOLTAGE;
    usb_p.charge_disabled = true;
    return;
  }

  /* Spike detection */
  if (usb_p.prev_tick > 0 && (tick - usb_p.prev_tick <= USB_SPIKE_WINDOW_MS)) {
    uint32_t delta = (mv > usb_p.prev_vbus_mv) ? (mv - usb_p.prev_vbus_mv)
                                               : (usb_p.prev_vbus_mv - mv);
    if (delta > USB_SPIKE_DELTA_MV) {
      usb_p.status = USB_STATUS_SPIKE;
      usb_p.spike_count++;
      usb_ldo_disable();
      usb_p.prev_vbus_mv = mv;
      usb_p.prev_tick = tick;
      return;
    }
  }

  /* All OK — re-enable if previously disabled */
  if (usb_p.ldo_disabled && mv <= USB_VBUS_NOMINAL_MV + 200) {
    usb_ldo_enable();
  }
  if (usb_p.charge_disabled && mv >= USB_VBUS_UV_MV + 100) {
    usb_p.charge_disabled = false;
  }

  usb_p.status = USB_STATUS_OK;
  usb_p.prev_vbus_mv = mv;
  usb_p.prev_tick = tick;
}

/**
 * @brief Get current USB protection status.
 */
static inline usb_status_t usb_protect_status(void) { return usb_p.status; }

#endif /* USB_PROTECT_H */
