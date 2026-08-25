/**
 * @file oled_ui.h
 * @brief ★ P1 #19: OLED UI Screens — Status, PIN, Message
 *
 * Durum ekranları + mesaj görüntüleme + PIN girişi.
 * Bağımlılık: oled_ssd1306.h, oled_font.h
 */
#ifndef OLED_UI_H
#define OLED_UI_H

#include "oled_font.h"
#include "oled_ssd1306.h"
#include <stdio.h>

/*============================================================================
 * UI Screen IDs
 *============================================================================*/
typedef enum {
  UI_SCREEN_BOOT,     /* Boot splash */
  UI_SCREEN_PIN,      /* PIN entry */
  UI_SCREEN_STATUS,   /* Main status */
  UI_SCREEN_MESSAGE,  /* Message compose/view */
  UI_SCREEN_ALERT,    /* Security alert */
  UI_SCREEN_RECOVERY, /* Recovery mode */
} ui_screen_t;

/*============================================================================
 * UI State
 *============================================================================*/
typedef struct {
  ui_screen_t current_screen;
  uint32_t auto_clear_tick; /* Tick for auto-clear countdown */
  bool stealth_mode;        /* Minimum contrast */
  int8_t rssi_dbm;          /* Signal strength */
  uint8_t battery_pct;      /* Battery percentage */
  bool sim_ok;
  bool network_ok;
  uint32_t tx_count;
  uint32_t rx_count;
  uint32_t last_activity_tick; /* ★ P3 #35: Last keypress tick */
  uint8_t stealth_level;       /* ★ P3 #35: 0=full, 1=dim, 2=min, 3=off */
  uint32_t scrub_tick;         /* ★ P3 #35: Next pixel scrub time */
  bool scrub_inverted;         /* Current scrub phase */
} ui_state_t;

static ui_state_t ui = {.current_screen = UI_SCREEN_BOOT,
                        .auto_clear_tick = 0,
                        .stealth_mode = false,
                        .rssi_dbm = -999,
                        .battery_pct = 0,
                        .sim_ok = false,
                        .network_ok = false,
                        .tx_count = 0,
                        .rx_count = 0,
                        .last_activity_tick = 0,
                        .stealth_level = 0,
                        .scrub_tick = 0,
                        .scrub_inverted = false};

/*============================================================================
 * Screen Renderers
 *============================================================================*/

/**
 * Boot splash screen:
 *   ┌──────────────────────┐
 *   │    ★ TITAN V15       │
 *   │   SECURE TERMINAL    │
 *   │                      │
 *   │    Initializing...   │
 *   └──────────────────────┘
 */
static inline void ui_draw_boot(void) {
  oled_clear();
  oled_font_draw_string(oled.framebuffer, 16, 1, "* TITAN V15 *");
  oled_font_draw_string(oled.framebuffer, 10, 3, "SECURE TERMINAL");
  oled_font_draw_string(oled.framebuffer, 16, 5, "Starting...");
  oled_flush();
}

/**
 * PIN entry screen:
 *   ┌──────────────────────┐
 *   │ ★ TITAN V15          │
 *   │ PIN: ____            │
 *   │                      │
 *   │ [*]=OK  [B]=DEL      │
 *   └──────────────────────┘
 */
static inline void ui_draw_pin(const char *pin_mask, uint8_t pin_len) {
  char line[22];
  oled_clear();
  oled_font_draw_string(oled.framebuffer, 0, 0, "* TITAN V15");

  /* PIN mask: show dots for entered digits */
  snprintf(line, sizeof(line), "PIN: ");
  for (uint8_t i = 0; i < pin_len && i < 8; i++)
    line[5 + i] = '*';
  for (uint8_t i = pin_len; i < 8; i++)
    line[5 + i] = '_';
  line[13] = '\0';
  oled_font_draw_string(oled.framebuffer, 0, 2, line);

  oled_font_draw_string(oled.framebuffer, 0, 5, "[*]=OK");
  oled_font_draw_string(oled.framebuffer, 60, 5, "[B]=DEL");
  oled_flush();
}

/**
 * Main status screen:
 *   ┌──────────────────────┐
 *   │ ★ TITAN V15          │
 *   │ 4G -85dBm   BAT:78% │
 *   │ SIM: OK    NET: OK  │
 *   │ TX: 142    RX: 89   │
 *   └──────────────────────┘
 */
static inline void ui_draw_status(void) {
  char line[22];
  oled_clear();

  oled_font_draw_string(oled.framebuffer, 0, 0, "* TITAN V15");

  snprintf(line, sizeof(line), "4G %ddBm  BAT:%d%%", ui.rssi_dbm,
           ui.battery_pct);
  oled_font_draw_string(oled.framebuffer, 0, 2, line);

  snprintf(line, sizeof(line), "SIM:%s  NET:%s", ui.sim_ok ? "OK" : "--",
           ui.network_ok ? "OK" : "--");
  oled_font_draw_string(oled.framebuffer, 0, 4, line);

  snprintf(line, sizeof(line), "TX:%-5lu RX:%-5lu", (unsigned long)ui.tx_count,
           (unsigned long)ui.rx_count);
  oled_font_draw_string(oled.framebuffer, 0, 6, line);

  oled_flush();
}

/**
 * Security alert screen (inverted, high visibility):
 */
static inline void ui_draw_alert(const char *title, const char *detail) {
  oled_clear();
  oled_invert(true);
  oled_font_draw_string(oled.framebuffer, 0, 1, "!! UYARI !!");
  oled_font_draw_string(oled.framebuffer, 0, 3, title);
  if (detail)
    oled_font_draw_string(oled.framebuffer, 0, 5, detail);
  oled_flush();
}

/**
 * @brief Initialize OLED UI (call after oled_init).
 */
static inline void oled_ui_init(void) {
  ui.current_screen = UI_SCREEN_BOOT;
  ui.last_activity_tick = HAL_GetTick();
  ui.scrub_tick = ui.last_activity_tick + 60000U; /* First scrub in 60s */
  ui_draw_boot();
}

/*============================================================================
 * ★ P3 #35: Stealth Mode (4 levels) + Pixel Scrubbing
 *============================================================================*/

/* Contrast values for each stealth level */
static const uint8_t stealth_contrast[4] = {
    0xCF, /* Level 0: Normal */
    0x40, /* Level 1: Dim */
    0x01, /* Level 2: Minimum (barely visible) */
    0x00  /* Level 3: Off (display blank) */
};

/**
 * @brief Cycle stealth level: 0 → 1 → 2 → 3 → 0.
 *        Call on long-press KEY_D (2 sec).
 */
static inline void ui_stealth_cycle(void) {
  ui.stealth_level = (ui.stealth_level + 1) % 4;
  ui.stealth_mode = (ui.stealth_level > 0);
  oled_set_contrast(stealth_contrast[ui.stealth_level]);
}

/**
 * @brief Signal user activity (keypress, touch, etc.).
 *        Resets auto-dim timer.
 * @param tick  Current HAL tick
 */
static inline void ui_activity_ping(uint32_t tick) {
  ui.last_activity_tick = tick;
  /* If auto-dimmed, restore to configured stealth level */
  oled_set_contrast(stealth_contrast[ui.stealth_level]);
}

/**
 * @brief Pixel scrubbing — prevents OLED burn-in.
 *        Every 60s: invert → wait 200ms → revert.
 *        Call from main loop.
 * @param tick  Current HAL tick
 */
static inline void ui_pixel_scrub(uint32_t tick) {
  if (tick >= ui.scrub_tick) {
    if (!ui.scrub_inverted) {
      /* Phase 1: Invert */
      oled_invert(true);
      ui.scrub_inverted = true;
      ui.scrub_tick = tick + 200; /* Revert after 200ms */
    } else {
      /* Phase 2: Revert */
      oled_invert(false);
      ui.scrub_inverted = false;
      ui.scrub_tick = tick + 60000U; /* Next scrub in 60s */
    }
  }

  /* Auto-dim: if no activity for 30s, drop to minimum contrast */
  if (ui.stealth_level < 2 && (tick - ui.last_activity_tick) >= 30000U) {
    oled_set_contrast(0x01); /* Auto-dim to minimum */
  }
}

/**
 * @brief Clear sensitive content after timeout.
 * @param current_tick  Current HAL tick
 */
static inline void ui_auto_clear_check(uint32_t current_tick) {
  if (ui.auto_clear_tick > 0 && current_tick >= ui.auto_clear_tick) {
    ui.auto_clear_tick = 0;
    ui_draw_status(); /* Return to status screen */
  }
}

/**
 * @brief ★ P3 #34: Draw duress fake screen.
 *        Shows normal-looking status while silent kill proceeds.
 */
static inline void ui_draw_duress_fake(void) {
  /* Show a convincing "normal" status screen */
  oled_clear();
  oled_invert(false);
  oled_font_draw_string(oled.framebuffer, 0, 0, "* TITAN V15");
  oled_font_draw_string(oled.framebuffer, 0, 2, "4G -72dBm BAT:85%");
  oled_font_draw_string(oled.framebuffer, 0, 4, "SIM:OK  NET:OK");
  oled_font_draw_string(oled.framebuffer, 0, 6, "TX:0     RX:0");
  oled_flush();
}

#endif /* OLED_UI_H */
