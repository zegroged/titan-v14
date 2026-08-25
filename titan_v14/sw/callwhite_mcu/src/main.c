/**
 * @file main.c
 * @brief Callwhite MCU Firmware — FreeRTOS Entry Point
 *
 * STM32L476RGT6 firmware for FPGA ↔ Modem bridge.
 * FPGA tarafı: 921600 baud UART (USART1) + CTS/RTS
 * Modem tarafı: 115200→921600 UART (USART2) + AT komutları
 *
 * ★ P1 Entegrasyonu:
 *   - CPUID doğrulama (#14) — boot'ta en erken
 *   - OLED SSD1306 (#19) — durum ekranı
 *   - Keypad 4×4 (#20) — kullanıcı girişi
 *   - TPL5010 Watchdog (#21) — MCU sağlık
 *   - UART Firewall (#22) — modem izolasyonu
 *   - Modem FW Hash (#15) — bütünlük kontrolü
 *   - TLS zorunlu (#11) — şifresiz bağlantı yok
 *
 * (c) 2026 PROJECT TITAN
 */

#include "stm32l4xx_hal.h"
/* #include "FreeRTOS.h" */
/* #include "task.h" */

/* Core module headers */
#include "at_engine.h"
#include "band_config.h"
#include "cobs_framing.h"
#include "config.h"
#include "jamming_detect.h"
#include "modem_monitor.h"
#include "modem_thermal.h"
#include "power.h"
#include "sim_manager.h"
#include "tamper.h"
#include "tcp_session.h"
#include "uart_fpga.h"
#include "uart_modem.h"

/* ★ P1 Security & Peripheral headers */
#include "cpuid_verify.h"    /* #14: CPUID hardware check */
#include "keypad.h"          /* #20: Keypad input */
#include "mcu_watchdog.h"    /* #21: TPL5010 watchdog */
#include "modem_fw_verify.h" /* #15: Modem firmware hash */
#include "oled_ssd1306.h"    /* #19: OLED display (includes oled_font.h) */
#include "oled_ui.h"         /* #19: UI screens (uses fw_signing.h) */
#include "uart_firewall.h"   /* #22: Modem UART firewall */

/* ★ P2 Security modules */
#include "imsi_detect.h" /* #37: IMSI catcher detection */
#include "ota_manager.h" /* #31: OTA + Recovery + PVD */

/* ★ P3 Kişiselleştirme modules */
#include "boot_pin.h"      /* #33/#34: Boot PIN + Duress PIN */
#include "dead_man.h"      /* #36: Dead Man Switch */
#include "operator_bind.h" /* #37: Operatör Bağlama */

/* ★ P4 İletişim Protokolü modules */
#include "msg_compose.h" /* #40: Mesaj Yazma ve Gönderme */

/* ★ P5 Kriptografik Mükemmellik modules */
#include "pvd_kill.h"      /* #45: PVD + Supercap Kill Guarantee */
#include "sram_scramble.h" /* #47: SRAM Cold Boot Scrambling */

/* ★ P6 Operasyonel Güvenlik modules */
#include "bkp_zeroize.h"     /* #65: BKP Hardware Zeroization */
#include "cryo_kill.h"       /* #67: Cryo Kill */
#include "modem_purge.h"     /* #55: Modem RAM Purge */
#include "oled_privacy.h"    /* #62: OLED Privacy Filter */
#include "ota_wear.h"        /* #68: OTA Wear-Out Protection */
#include "sealed_recovery.h" /* #51: Sealed Recovery Mode */
#include "usb_protect.h"     /* #69: USB Surge/Overvoltage */

/* ★ V14.2 Hardening modules */
#include "acoustic_mask.h"    /* V14.2: Acoustic side-channel */
#include "backside_shield.h"  /* V14.2: TSC capacitive sensing */
#include "device_provision.h" /* V14.2: Factory provisioning */
#include "radio_silence.h"    /* V14.2: GaN FET modem RF kill */
#include "secure_element.h"   /* V14.2: ATECC608B (when present) */
#include "spi_flash_crypto.h" /* V14.2: Encrypted OTA staging */

/*============================================================================
 * I2C Handle (for OLED)
 *============================================================================*/
static I2C_HandleTypeDef hi2c1;

/*============================================================================
 * TASK PRIORITIES (FreeRTOS — uncomment when RTOS integrated)
 *============================================================================*/
/* #define TASK_PRIO_FPGA_RX     (configMAX_PRIORITIES - 1) */
/* #define TASK_PRIO_MODEM_RX    (configMAX_PRIORITIES - 2) */
/* #define TASK_PRIO_AT_ENGINE   (configMAX_PRIORITIES - 3) */
/* #define TASK_PRIO_MONITOR     (configMAX_PRIORITIES - 4) */
/* #define TASK_PRIO_THERMAL     (configMAX_PRIORITIES - 5) */
/* #define TASK_PRIO_KEYPAD      (configMAX_PRIORITIES - 6) */
/* #define TASK_PRIO_JAMMING     (configMAX_PRIORITIES - 7) */

/*============================================================================
 * FORWARD DECLARATIONS
 *============================================================================*/
static void system_clock_config(void);
static void gpio_init(void);
static void i2c1_init(void);
static void error_handler(void);

/*============================================================================
 * MAIN — Boot Sequence
 *
 * Güvenlik sıralaması (en kritik önce):
 *   1. HAL + Clock + GPIO
 *   2. Tamper detection (kapak sensörleri)
 *   3. ★ CPUID doğrulama (sahte çip kontrolü)
 *   4. Watchdog init (MCU sağlık garantisi)
 *   5. Power management
 *   6. OLED init (kullanıcı geri bildirim)
 *   7. Keypad init (kullanıcı girişi)
 *   8. UART init (FPGA + Modem)
 *   9. ★ UART Firewall (modem izolasyonu)
 *  10. COBS framing
 *  11. Modem boot + AT engine
 *  12. ★ Modem FW verify
 *  13. SIM management
 *  14. Band config (LTE_ONLY)
 *  15. ★ TLS mandatory TCP session
 *  16. Background monitors
 *============================================================================*/
int main(void) {
  /* ═══════════════════════════════════════════════════════
   * PHASE 1: Hardware Foundation
   * ═══════════════════════════════════════════════════════ */
  HAL_Init();
  system_clock_config();
  gpio_init();

  /* ═══════════════════════════════════════════════════════
   * PHASE 2: Security — Early Boot (before any comms)
   * ═══════════════════════════════════════════════════════ */

  /* Tamper detection — reed switch, limit switch, FPGA kill */
  tamper_init();

  /* ★ P1 #14: Verify MCU is genuine STM32L476
   *   Failure → FPGA kill + infinite halt */
  cpuid_verify_init();

  /* ★ P1 #21: External watchdog — MCU sağlık garantisi
   *   TPL5010 WAKE/DONE handshake başlatılır */
  mcu_watchdog_init();

  /* Power management — PVD, battery ADC */
  power_init();

  /* ★ P2 #32: Recovery mode check (WDT reset or key combo) */
  recovery_check(false, false,
                 false); /* TODO: read actual reset cause + keys */

  /* ═══════════════════════════════════════════════════════
   * PHASE 3: User Interface
   * ═══════════════════════════════════════════════════════ */

  /* ★ P1 #19: OLED display init */
  i2c1_init();
  oled_init(&hi2c1);
  oled_ui_init(); /* Shows boot splash */

  /* ★ P1 #20: Keypad init */
  keypad_init();

  /* ═══════════════════════════════════════════════════════
   * PHASE 2.5: Operator Authentication (P3)
   * ═══════════════════════════════════════════════════════ */

  /* ★ P3 #33: Boot PIN init (reads fail count from BKP) */
  boot_pin_init();

  /* ★ P3 #37: Operatör binding init */
  operator_bind_init();

  /* ★ P3 #33/#34: PIN entry loop */
  if (bps.pin_set) {
    char pin_buf[9] = {0};
    uint8_t pin_len = 0;
    ui_draw_pin(pin_buf, pin_len);

    while (!bps.authenticated) {
      uint32_t tick = HAL_GetTick();
      keypad_poll(tick);
      mcu_watchdog_poll(); /* Keep WDT alive during PIN entry */

      /* Lockout check */
      if (boot_pin_is_locked(tick)) {
        ui_draw_alert("KILITLI", "Bekleyin...");
        continue;
      }

      char key;
      if (kp_event_pop(&key)) {
        if (key == '#') {
          /* Submit PIN */
          pin_result_t result = boot_pin_verify(pin_buf, pin_len);
          switch (result) {
          case PIN_OK:
            bps.authenticated = true;
            break;
          case PIN_DURESS:
            /* ★ P3 #34: Show fake screen + silent kill */
            ui_draw_duress_fake();
            /* Background: FPGA kill after 3s (looks normal) */
            HAL_Delay(3000);
            GPIOC->BSRR = (1U << 13); /* PC13 = FPGA_KILL */
            while (1) {
              __NOP();
            }
            break;
          case PIN_ZEROIZE:
            /* Already killed in boot_pin_verify */
            break;
          case PIN_LOCKED:
          case PIN_WRONG:
            pin_len = 0;
            memset(pin_buf, 0, sizeof(pin_buf));
            ui_draw_alert("YANLIS PIN", NULL);
            HAL_Delay(1000);
            ui_draw_pin(pin_buf, pin_len);
            break;
          }
        } else if (key == '*') {
          /* Backspace */
          if (pin_len > 0) {
            pin_len--;
            pin_buf[pin_len] = 0;
          }
          ui_draw_pin(pin_buf, pin_len);
        } else if (key >= '0' && key <= '9' && pin_len < 8) {
          pin_buf[pin_len++] = key;
          ui_draw_pin(pin_buf, pin_len);
        }
      }
    }

    /* ★ P3 #37: Check operator binding after PIN success */
    bind_result_t bind = operator_bind_check(bps.pin_hash);
    if (bind == BIND_MISMATCH) {
      ui_draw_alert("OPERATOR UYUSMUYOR", "IMHA");
      HAL_Delay(1000);
      GPIOC->BSRR = (1U << 13); /* FPGA_KILL */
      while (1) {
        __NOP();
      }
    } else if (bind == BIND_VIRGIN) {
      operator_bind_set(bps.pin_hash);
    }

    /* Clear PIN from RAM */
    memset(pin_buf, 0, sizeof(pin_buf));
  }

  /* ★ P3 #36: Dead man switch init (keypad fallback mode) */
  dead_man_init(false); /* false = no HW sensor, keypad timeout */
  dead_man_arm(HAL_GetTick());

  /* ═══════════════════════════════════════════════════════
   * PHASE 4: Communication Setup
   * ═══════════════════════════════════════════════════════ */

  /* UART init */
  uart_fpga_init();  /* USART1: 921600, CTS/RTS */
  uart_modem_init(); /* USART2: 115200 (modem boot) */

  /* ★ P1 #22: UART Firewall — modem izolasyonu */
  uart_firewall_init();

  /* COBS framing init */
  cobs_framing_init();

  /* Modem power sequencing */
  modem_monitor_init();

  /* Wait for modem boot + AT ready */
  at_engine_init();

  /* ★ P1 #15: Modem firmware integrity check */
  modem_fw_verify_init();

  /* SIM management */
  sim_manager_init();

  /* ★ P1 #12: Network config — LTE_ONLY default (2G disabled) */
  band_config_init();

  /* ★ P1 #11: TCP session with mandatory TLS */
  tcp_session_init();

  /* ★ P2 #37: IMSI catcher detection init */
  imsi_detect_init();

  /* Background monitors */
  modem_thermal_init();
  jamming_detect_init();

  /* ★ P5 Kriptografik Mükemmellik init */
  pvd_init();           /* #45: PVD power-loss detection */
  sram_scramble_init(); /* #47: SRAM cold boot scrambling */

  /* ★ P6 Operasyonel Güvenlik init */
  bkp_zeroize_init();   /* #65: BKP zeroize engine ready */
  cryo_kill_init();     /* #67: ADC temperature sentinel */
  modem_purge_init();   /* #55: Modem RAM purge engine ready */
  usb_protect_init();   /* #69: USB surge/overvoltage ADC */
  ota_wear_init();      /* #68: Flash wear-out counters loaded */
  oled_privacy_init(0); /* #62: Auto-dim, level 0 = normal */

  /* ★ V14.2 Hardening init */
  /* radio_silence: no init needed — state initialized statically */
  backside_shield_init(); /* TSC calibration + baseline */
  /* acoustic_mask_init(&htim3); — requires TIM3 handle (TODO: add TIM3 init) */
  device_provision_load(); /* Factory config from SPI flash */
  /* spi_flash_crypto_init(&hspi2); — requires SPI2 handle (TODO: add SPI2 init)
   */
  /* secure_element_init(&hi2c2); — requires I2C2 handle + ATECC608B chip */

  /* Update OLED to status screen after boot */
  ui_draw_status();

  /* ═══════════════════════════════════════════════════════
   * PHASE 5: Main Loop
   * ═══════════════════════════════════════════════════════ */

  /* FreeRTOS tasks (uncomment when RTOS integrated) */
  /*
  xTaskCreate(uart_fpga_rx_task,   "fpga_rx",  512, NULL, TASK_PRIO_FPGA_RX,
  NULL); xTaskCreate(uart_modem_rx_task,  "modem_rx", 512, NULL,
  TASK_PRIO_MODEM_RX,   NULL); xTaskCreate(at_engine_task,      "at_eng",   512,
  NULL, TASK_PRIO_AT_ENGINE,  NULL); xTaskCreate(modem_monitor_task,  "mon",
  256, NULL, TASK_PRIO_MONITOR,    NULL); xTaskCreate(modem_thermal_task,
  "thermal",  256, NULL, TASK_PRIO_THERMAL,    NULL); xTaskCreate(keypad_task,
  "keypad",   256, NULL, TASK_PRIO_KEYPAD,     NULL);
  xTaskCreate(jamming_detect_task, "jamming",  256, NULL, TASK_PRIO_JAMMING,
  NULL); vTaskStartScheduler();
  */

  /* Superloop fallback (pre-RTOS development) */
  while (1) {
    uint32_t tick = HAL_GetTick();

    /* Core data path */
    uart_fpga_poll();
    uart_modem_poll();
    at_engine_poll();

    /* ★ P1 peripherals */
    keypad_poll(tick);         /* #20: Scan keypad + T9 */
    mcu_watchdog_poll();       /* #21: TPL5010 DONE response */
    ui_auto_clear_check(tick); /* #19: Auto-clear sensitive content */

    /* ★ P3 polling */
    dead_man_poll(tick);  /* #36: Dead man switch check */
    ui_pixel_scrub(tick); /* #35: OLED burn-in prevention */
    if (dm.state == DM_WARNING) {
      ui_draw_alert("OPERATOR YOK", "5sn icinde imha");
    }

    /* Touch signal on any keypress */
    {
      char _k;
      if (kp_event_pop(&_k)) {
        dead_man_touch();       /* #36: Reset dead man timer */
        ui_activity_ping(tick); /* #35: Reset auto-dim timer */
        kp_event_push(_k);      /* Put key back for other consumers */
      }
    }

    /* Background monitors */
    modem_thermal_poll();
    jamming_detect_poll();
    power_poll();

    /* ★ P2 monitors */
    /* imsi_detect runs via AT response parser, not polled */

    /* ★ P4 messaging */
    msg_compose_poll(tick); /* #40: Mesaj gönderim state machine */

    /* ★ P5 security polling */
    pvd_poll();               /* #45: PVD power-loss check */
    sram_scramble_poll(tick); /* #47: SRAM periodic re-mask */

    /* ★ P6 security polling */
    /* cryo_kill_poll(adc_raw, tick); — requires ADC reading (TODO: add ADC
     * polling) */
    /* usb_protect_poll(adc_raw, tick); — requires VBUS ADC (TODO: add ADC) */
    /* ota_wear: event-driven, no polling needed */

    /* ★ V14.2 hardening polling */
    /* radio_silence: event-driven via keypad combo check */
    {
      bss_status_t bss = backside_shield_check();
      if (bss == BSS_CRITICAL) {
        GPIOC->BSRR = (1U << 13); /* FPGA_KILL */
        while (1) {
          __NOP();
        }
      }
    }
  }
}

/*============================================================================
 * SYSTEM CLOCK: 80 MHz (HSE + PLL)
 *============================================================================*/
static void system_clock_config(void) {
  /* HSE 8MHz → PLL → 80MHz SYSCLK
   * PLL_M=1, PLL_N=20, PLL_R=2 → 8/1*20/2 = 80MHz
   * APB1 = 80MHz (max), APB2 = 80MHz (max)
   * Flash latency = 4WS (80MHz @ 3.3V) */

  RCC_OscInitTypeDef osc = {0};
  osc.OscillatorType = RCC_OSCILLATORTYPE_HSE;
  osc.HSEState = RCC_HSE_ON;
  osc.PLL.PLLState = RCC_PLL_ON;
  osc.PLL.PLLSource = RCC_PLLSOURCE_HSE;
  osc.PLL.PLLM = 1;
  osc.PLL.PLLN = 20;
  osc.PLL.PLLR = RCC_PLLR_DIV2;
  osc.PLL.PLLP = RCC_PLLP_DIV7;
  osc.PLL.PLLQ = RCC_PLLQ_DIV2;
  if (HAL_RCC_OscConfig(&osc) != HAL_OK) {
    error_handler();
  }

  RCC_ClkInitTypeDef clk = {0};
  clk.ClockType = RCC_CLOCKTYPE_HCLK | RCC_CLOCKTYPE_SYSCLK |
                  RCC_CLOCKTYPE_PCLK1 | RCC_CLOCKTYPE_PCLK2;
  clk.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
  clk.AHBCLKDivider = RCC_SYSCLK_DIV1; /* HCLK = 80MHz */
  clk.APB1CLKDivider = RCC_HCLK_DIV1;  /* APB1 = 80MHz */
  clk.APB2CLKDivider = RCC_HCLK_DIV1;  /* APB2 = 80MHz */
  if (HAL_RCC_ClockConfig(&clk, FLASH_LATENCY_4) != HAL_OK) {
    error_handler();
  }

  /* Enable LSE for RTC/BKP registers (used by ota_wear, boot_pin) */
  RCC_OscInitTypeDef lse = {0};
  lse.OscillatorType = RCC_OSCILLATORTYPE_LSE;
  lse.LSEState = RCC_LSE_ON;
  HAL_RCC_OscConfig(&lse); /* Non-fatal if no LSE crystal */
}

/*============================================================================
 * GPIO Init — All pins per architecture doc
 *============================================================================*/
static void gpio_init(void) {
  /* Enable all GPIO clocks */
  __HAL_RCC_GPIOA_CLK_ENABLE();
  __HAL_RCC_GPIOB_CLK_ENABLE();
  __HAL_RCC_GPIOC_CLK_ENABLE();

  GPIO_InitTypeDef g = {0};

  /* ── PORT A ─────────────────────────────────────────────── */

  /* PA0: USART2_CTS (AF7) — Modem CTS */
  /* PA1: USART2_RTS (AF7) — Modem RTS */
  /* PA2: USART2_TX  (AF7) — Modem TX */
  /* PA3: USART2_RX  (AF7) — Modem RX */
  g.Pin = GPIO_PIN_0 | GPIO_PIN_1 | GPIO_PIN_2 | GPIO_PIN_3;
  g.Mode = GPIO_MODE_AF_PP;
  g.Pull = GPIO_NOPULL;
  g.Speed = GPIO_SPEED_FREQ_VERY_HIGH;
  g.Alternate = GPIO_AF7_USART2;
  HAL_GPIO_Init(GPIOA, &g);

  /* PA4: ADC Battery voltage */
  /* PA5: ADC Li-Po NTC */
  /* PA6: ADC Modem NTC */
  g.Pin = PIN_ADC_BATTERY | PIN_ADC_LIPO_NTC | PIN_ADC_MODEM_NTC;
  g.Mode = GPIO_MODE_ANALOG;
  g.Pull = GPIO_NOPULL;
  HAL_GPIO_Init(GPIOA, &g);

  /* PA7: Modem RI — EXTI input */
  g.Pin = GPIO_PIN_7;
  g.Mode = GPIO_MODE_IT_FALLING;
  g.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(GPIOA, &g);

  /* PA9:  USART1_TX (AF7) — FPGA TX */
  /* PA10: USART1_RX (AF7) — FPGA RX */
  g.Pin = GPIO_PIN_9 | GPIO_PIN_10;
  g.Mode = GPIO_MODE_AF_PP;
  g.Pull = GPIO_NOPULL;
  g.Speed = GPIO_SPEED_FREQ_VERY_HIGH;
  g.Alternate = GPIO_AF7_USART1;
  HAL_GPIO_Init(GPIOA, &g);

  /* PA11: FPGA CTS — GPIO output (active low) */
  g.Pin = PIN_FPGA_CTS;
  g.Mode = GPIO_MODE_OUTPUT_PP;
  g.Pull = GPIO_NOPULL;
  g.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOA, &g);
  HAL_GPIO_WritePin(GPIOA, PIN_FPGA_CTS, GPIO_PIN_RESET); /* CTS=0: ready */

  /* PA12: FPGA RTS — GPIO input */
  g.Pin = PIN_FPGA_RTS;
  g.Mode = GPIO_MODE_INPUT;
  g.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(GPIOA, &g);

  /* ── PORT B ─────────────────────────────────────────────── */

  /* PB6: I2C1_SCL (AF4) — OLED */
  /* PB7: I2C1_SDA (AF4) — OLED */
  /* (configured in i2c1_init) */

  /* PB12-PB15: Keypad COL0-COL3 — input with pull-up */
  g.Pin = PIN_KP_COL0 | PIN_KP_COL1 | PIN_KP_COL2 | PIN_KP_COL3;
  g.Mode = GPIO_MODE_INPUT;
  g.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(GPIOB, &g);

  /* ── PORT C ─────────────────────────────────────────────── */

  /* PC0: Modem PWRKEY — output (active high pulse) */
  g.Pin = PIN_MODEM_PWRKEY;
  g.Mode = GPIO_MODE_OUTPUT_PP;
  g.Speed = GPIO_SPEED_FREQ_LOW;
  g.Pull = GPIO_NOPULL;
  HAL_GPIO_Init(GPIOC, &g);
  HAL_GPIO_WritePin(GPIOC, PIN_MODEM_PWRKEY, GPIO_PIN_RESET);

  /* PC1: Modem STATUS — input */
  /* PC2: Modem NETLIGHT — input */
  g.Pin = PIN_MODEM_STATUS | PIN_MODEM_NETLIGHT;
  g.Mode = GPIO_MODE_INPUT;
  g.Pull = GPIO_PULLDOWN;
  HAL_GPIO_Init(GPIOC, &g);

  /* PC3: Modem RESET_N — output (active low) */
  g.Pin = PIN_MODEM_RESET_N;
  g.Mode = GPIO_MODE_OUTPUT_OD;
  g.Pull = GPIO_PULLUP;
  g.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOC, &g);
  HAL_GPIO_WritePin(GPIOC, PIN_MODEM_RESET_N, GPIO_PIN_SET); /* not reset */

  /* PC5: Tamper reed switch — EXTI */
  /* PC6: Tamper limit switch — EXTI */
  g.Pin = PIN_TAMPER_REED | PIN_TAMPER_LIMIT;
  g.Mode = GPIO_MODE_IT_RISING_FALLING;
  g.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(GPIOC, &g);

  /* PC7: TPL5010 WAKE — EXTI input */
  g.Pin = PIN_WDT_WAKE;
  g.Mode = GPIO_MODE_IT_RISING;
  g.Pull = GPIO_PULLDOWN;
  HAL_GPIO_Init(GPIOC, &g);

  /* PC8: TPL5010 DONE — output */
  g.Pin = PIN_WDT_DONE;
  g.Mode = GPIO_MODE_OUTPUT_PP;
  g.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOC, &g);

  /* PC9: Modem LDO enable — output */
  g.Pin = PIN_MODEM_LDO_EN;
  g.Mode = GPIO_MODE_OUTPUT_PP;
  g.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOC, &g);
  HAL_GPIO_WritePin(GPIOC, PIN_MODEM_LDO_EN, GPIO_PIN_RESET); /* LDO off */

  /* PC10: Radio Silence GaN FET — output */
  g.Pin = RADIO_SILENCE_PIN;
  g.Mode = GPIO_MODE_OUTPUT_PP;
  g.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOC, &g);
  HAL_GPIO_WritePin(GPIOC, RADIO_SILENCE_PIN,
                    GPIO_PIN_SET); /* FET ON = modem powered */

  /* PC11: SIM detect — input */
  g.Pin = PIN_SIM_DETECT;
  g.Mode = GPIO_MODE_INPUT;
  g.Pull = GPIO_PULLUP;
  HAL_GPIO_Init(GPIOC, &g);

  /* PC12: Modem W_DISABLE — output (active low RF kill) */
  g.Pin = PIN_MODEM_W_DISABLE;
  g.Mode = GPIO_MODE_OUTPUT_PP;
  g.Speed = GPIO_SPEED_FREQ_LOW;
  HAL_GPIO_Init(GPIOC, &g);
  HAL_GPIO_WritePin(GPIOC, PIN_MODEM_W_DISABLE,
                    GPIO_PIN_RESET); /* RF enabled */

  /* PC13: FPGA KILL — output (active high = kill) */
  g.Pin = PIN_FPGA_KILL;
  g.Mode = GPIO_MODE_OUTPUT_PP;
  g.Speed = GPIO_SPEED_FREQ_VERY_HIGH; /* Kill must be fast */
  HAL_GPIO_Init(GPIOC, &g);
  HAL_GPIO_WritePin(GPIOC, PIN_FPGA_KILL, GPIO_PIN_RESET); /* No kill */

  /* ── NVIC: Enable EXTI interrupts ──────────────────────── */
  HAL_NVIC_SetPriority(EXTI9_5_IRQn, 1, 0); /* WDT WAKE (PC7) */
  HAL_NVIC_EnableIRQ(EXTI9_5_IRQn);
  HAL_NVIC_SetPriority(EXTI15_10_IRQn, 0, 0); /* Tamper (PC5/PC6) */
  HAL_NVIC_EnableIRQ(EXTI15_10_IRQn);
}

/*============================================================================
 * ★ P1 #19: I2C1 Init (OLED SSD1306)
 *============================================================================*/
static void i2c1_init(void) {
  __HAL_RCC_I2C1_CLK_ENABLE();
  __HAL_RCC_GPIOB_CLK_ENABLE();

  /* PB6=SCL, PB7=SDA — Alternate Function 4 (I2C1) */
  GPIO_InitTypeDef gpio = {0};
  gpio.Pin = GPIO_PIN_6 | GPIO_PIN_7;
  gpio.Mode = GPIO_MODE_AF_OD;
  gpio.Pull = GPIO_PULLUP;
  gpio.Speed = GPIO_SPEED_FREQ_HIGH;
  gpio.Alternate = GPIO_AF4_I2C1;
  HAL_GPIO_Init(GPIOB, &gpio);

  hi2c1.Instance = I2C1;
  hi2c1.Init.Timing = 0x00702991; /* 400kHz (Fast Mode) @ 80MHz */
  hi2c1.Init.OwnAddress1 = 0;
  hi2c1.Init.AddressingMode = I2C_ADDRESSINGMODE_7BIT;
  hi2c1.Init.DualAddressMode = I2C_DUALADDRESS_DISABLE;
  hi2c1.Init.GeneralCallMode = I2C_GENERALCALL_DISABLE;
  hi2c1.Init.NoStretchMode = I2C_NOSTRETCH_DISABLE;
  HAL_I2C_Init(&hi2c1);
}

/*============================================================================
 * Error Handler
 *============================================================================*/
static void error_handler(void) {
  __disable_irq();
  while (1) { /* Stuck */
  }
}

/*============================================================================
 * ★ P1 #21: EXTI IRQ Handler for TPL5010 WAKE
 *============================================================================*/
void EXTI9_5_IRQHandler(void) { HAL_GPIO_EXTI_IRQHandler(PIN_WDT_WAKE); }

void HAL_GPIO_EXTI_Callback(uint16_t GPIO_Pin) {
  mcu_watchdog_exti_callback(GPIO_Pin);
}
