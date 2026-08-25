/**
 * @file oled_ssd1306.h
 * @brief ★ P1 #19: SSD1306 OLED Display Driver (128×64, I2C)
 *
 * I2C1 üzerinden SSD1306 OLED modülü kontrolü.
 * Framebuffer tabanlı: önce RAM'e çiz, sonra flush.
 *
 * Pin: PB6 (SCL), PB7 (SDA), adres 0x3C
 */
#ifndef OLED_SSD1306_H
#define OLED_SSD1306_H

#include "config.h"
#include "stm32l4xx_hal.h"
#include <stdbool.h>
#include <stdint.h>
#include <string.h>


/*============================================================================
 * Constants
 *============================================================================*/
#define SSD1306_WIDTH OLED_WIDTH                         /* 128 */
#define SSD1306_HEIGHT OLED_HEIGHT                       /* 64 */
#define SSD1306_PAGES (SSD1306_HEIGHT / 8)               /* 8 pages */
#define SSD1306_BUF_SIZE (SSD1306_WIDTH * SSD1306_PAGES) /* 1024 bytes */
#define SSD1306_I2C_ADDR (OLED_I2C_ADDR << 1) /* HAL uses 8-bit addr */

/* SSD1306 Commands */
#define SSD1306_CMD_DISPLAY_OFF 0xAE
#define SSD1306_CMD_DISPLAY_ON 0xAF
#define SSD1306_CMD_SET_CONTRAST 0x81
#define SSD1306_CMD_ENTIRE_ON_RES 0xA4
#define SSD1306_CMD_NORMAL_DISPLAY 0xA6
#define SSD1306_CMD_INVERT_DISPLAY 0xA7
#define SSD1306_CMD_SET_MUX_RATIO 0xA8
#define SSD1306_CMD_SET_OFFSET 0xD3
#define SSD1306_CMD_SET_START_LINE 0x40
#define SSD1306_CMD_SEG_REMAP 0xA1
#define SSD1306_CMD_COM_SCAN_DEC 0xC8
#define SSD1306_CMD_SET_COM_PINS 0xDA
#define SSD1306_CMD_SET_CLK_DIV 0xD5
#define SSD1306_CMD_SET_PRECHARGE 0xD9
#define SSD1306_CMD_SET_VCOM 0xDB
#define SSD1306_CMD_CHARGE_PUMP 0x8D
#define SSD1306_CMD_MEM_ADDR_MODE 0x20
#define SSD1306_CMD_COL_ADDR 0x21
#define SSD1306_CMD_PAGE_ADDR 0x22

/*============================================================================
 * State
 *============================================================================*/
typedef struct {
  I2C_HandleTypeDef *hi2c;
  uint8_t framebuffer[SSD1306_BUF_SIZE];
  bool initialized;
  uint8_t contrast; /* Current contrast 0x00-0xFF */
} oled_state_t;

static oled_state_t oled = {
    .hi2c = NULL, .initialized = false, .contrast = 0xCF /* Default contrast */
};

/*============================================================================
 * Low-Level I2C
 *============================================================================*/
static inline HAL_StatusTypeDef oled_write_cmd(uint8_t cmd) {
  uint8_t buf[2] = {0x00, cmd}; /* Co=0, D/C#=0 (command) */
  return HAL_I2C_Master_Transmit(oled.hi2c, SSD1306_I2C_ADDR, buf, 2, 100);
}

static inline HAL_StatusTypeDef oled_write_data(const uint8_t *data,
                                                uint16_t len) {
  /* Send data prefix + framebuffer in one transaction */
  /* For simplicity, send page by page */
  uint8_t buf[SSD1306_WIDTH + 1];
  buf[0] = 0x40; /* Co=0, D/C#=1 (data) */

  uint16_t offset = 0;
  while (offset < len) {
    uint16_t chunk =
        (len - offset > SSD1306_WIDTH) ? SSD1306_WIDTH : (len - offset);
    memcpy(&buf[1], &data[offset], chunk);
    HAL_I2C_Master_Transmit(oled.hi2c, SSD1306_I2C_ADDR, buf, chunk + 1, 100);
    offset += chunk;
  }
  return HAL_OK;
}

/*============================================================================
 * Public API
 *============================================================================*/

/**
 * @brief Initialize SSD1306 OLED display.
 * @param hi2c  Pointer to initialized I2C handle (I2C1)
 */
static inline void oled_init(I2C_HandleTypeDef *hi2c) {
  oled.hi2c = hi2c;

  HAL_Delay(100); /* Wait for SSD1306 power stabilization */

  /* Init sequence (128×64) */
  oled_write_cmd(SSD1306_CMD_DISPLAY_OFF);
  oled_write_cmd(SSD1306_CMD_SET_CLK_DIV);
  oled_write_cmd(0x80);
  oled_write_cmd(SSD1306_CMD_SET_MUX_RATIO);
  oled_write_cmd(0x3F); /* 64-1 */
  oled_write_cmd(SSD1306_CMD_SET_OFFSET);
  oled_write_cmd(0x00);
  oled_write_cmd(SSD1306_CMD_SET_START_LINE | 0x00);
  oled_write_cmd(SSD1306_CMD_CHARGE_PUMP);
  oled_write_cmd(0x14); /* Enable */
  oled_write_cmd(SSD1306_CMD_MEM_ADDR_MODE);
  oled_write_cmd(0x00);                     /* Horiz */
  oled_write_cmd(SSD1306_CMD_SEG_REMAP);    /* Column 127 = SEG0 */
  oled_write_cmd(SSD1306_CMD_COM_SCAN_DEC); /* COM[N-1] to COM0 */
  oled_write_cmd(SSD1306_CMD_SET_COM_PINS);
  oled_write_cmd(0x12);
  oled_write_cmd(SSD1306_CMD_SET_CONTRAST);
  oled_write_cmd(oled.contrast);
  oled_write_cmd(SSD1306_CMD_SET_PRECHARGE);
  oled_write_cmd(0xF1);
  oled_write_cmd(SSD1306_CMD_SET_VCOM);
  oled_write_cmd(0x40);
  oled_write_cmd(SSD1306_CMD_ENTIRE_ON_RES);
  oled_write_cmd(SSD1306_CMD_NORMAL_DISPLAY);
  oled_write_cmd(SSD1306_CMD_DISPLAY_ON);

  /* Clear framebuffer */
  memset(oled.framebuffer, 0x00, SSD1306_BUF_SIZE);
  oled.initialized = true;

  /* Flush initial blank screen */
  oled_write_cmd(SSD1306_CMD_COL_ADDR);
  oled_write_cmd(0);
  oled_write_cmd(127);
  oled_write_cmd(SSD1306_CMD_PAGE_ADDR);
  oled_write_cmd(0);
  oled_write_cmd(7);
  oled_write_data(oled.framebuffer, SSD1306_BUF_SIZE);
}

/**
 * @brief Flush framebuffer to display.
 */
static inline void oled_flush(void) {
  if (!oled.initialized)
    return;

  oled_write_cmd(SSD1306_CMD_COL_ADDR);
  oled_write_cmd(0);
  oled_write_cmd(127);
  oled_write_cmd(SSD1306_CMD_PAGE_ADDR);
  oled_write_cmd(0);
  oled_write_cmd(7);
  oled_write_data(oled.framebuffer, SSD1306_BUF_SIZE);
}

/**
 * @brief Clear framebuffer (call oled_flush() after).
 */
static inline void oled_clear(void) {
  memset(oled.framebuffer, 0x00, SSD1306_BUF_SIZE);
}

/**
 * @brief Set a single pixel.
 */
static inline void oled_set_pixel(uint8_t x, uint8_t y, bool on) {
  if (x >= SSD1306_WIDTH || y >= SSD1306_HEIGHT)
    return;

  if (on)
    oled.framebuffer[x + (y / 8) * SSD1306_WIDTH] |= (1 << (y & 7));
  else
    oled.framebuffer[x + (y / 8) * SSD1306_WIDTH] &= ~(1 << (y & 7));
}

/**
 * @brief Set display contrast.
 * @param level  0x00 (minimum) to 0xFF (maximum)
 *               Stealth mode: use 0x01
 */
static inline void oled_set_contrast(uint8_t level) {
  oled.contrast = level;
  if (oled.initialized) {
    oled_write_cmd(SSD1306_CMD_SET_CONTRAST);
    oled_write_cmd(level);
  }
}

/**
 * @brief Turn display off (power save, OLED protect).
 */
static inline void oled_display_off(void) {
  oled_write_cmd(SSD1306_CMD_DISPLAY_OFF);
}

/**
 * @brief Turn display on.
 */
static inline void oled_display_on(void) {
  oled_write_cmd(SSD1306_CMD_DISPLAY_ON);
}

/**
 * @brief Invert display (for visual alerts).
 */
static inline void oled_invert(bool invert) {
  oled_write_cmd(invert ? SSD1306_CMD_INVERT_DISPLAY
                        : SSD1306_CMD_NORMAL_DISPLAY);
}

#endif /* OLED_SSD1306_H */
