/**
 * @file config.h
 * @brief Callwhite MCU — System Configuration
 */
#ifndef CALLWHITE_CONFIG_H
#define CALLWHITE_CONFIG_H

/*============================================================================
 * UART Configuration
 *============================================================================*/
#define FPGA_UART_BAUD 921600       /* BLACK UART (USART1) */
#define MODEM_UART_BAUD 115200      /* EC25-E default (USART2) */
#define MODEM_UART_BAUD_FAST 921600 /* AT+IPR=921600 sonrasi */

/*============================================================================
 * Network Configuration
 *============================================================================*/
#define DEFAULT_APN "internet"
#define DEFAULT_SERVER_IP "0.0.0.0" /* TODO: Set target server */
#define DEFAULT_SERVER_PORT 4433
#define TCP_KEEPALIVE_SEC 30

/*============================================================================
 * ★ P1 Security Configuration
 *============================================================================*/
#define SECURITY_RDP_LEVEL 2        /* #7: STM32 RDP Level 2 (production) */
#define SECURITY_BOOT_CPUID_CHECK 1 /* #14: DBGMCU_IDCODE verify at boot  */
#define SECURITY_MODEM_FW_VERIFY 1  /* #15: AT+QGMR hash check at boot    */
#define SECURITY_TLS_MANDATORY 1    /* #11: Plaintext TCP REJECTED         */
#define SECURITY_UART_FIREWALL 1    /* #22: Modem UART whitelist parser    */
#define SECURITY_FW_SIGNING 1       /* #17: OTA HMAC-SHA256 verification   */

/*============================================================================
 * Band / Operator Configuration
 *============================================================================*/
#define BAND_PROFILE_DEFAULT BAND_TR /* Turkiye bantlari */
/* ★ P1 #12: 2G tamamen devre disi — downgrade saldirisi engeli     */
/* Eski: NW_MODE_LTE_3G — 3G fallback acikti                       */
/* Yeni: NW_MODE_LTE_ONLY — sadece LTE, acil menuden 3G acilabilir */
#define NW_MODE_DEFAULT NW_MODE_LTE_ONLY

/*============================================================================
 * Thermal Thresholds (Celsius)
 *============================================================================*/
#define MODEM_TEMP_THROTTLE 60
#define MODEM_TEMP_RF_OFF 70
#define MODEM_TEMP_SHUTDOWN 80
#define MODEM_TEMP_RESTART 55
#define MODEM_THERMAL_MAX_SHUTDOWNS 3

/*============================================================================
 * Jamming Detection
 *============================================================================*/
#define JAMMING_RSSI_DROP_THRESHOLD 20 /* dB sudden drop */
#define JAMMING_CREG_LOSS_WINDOW 60    /* seconds */
#define JAMMING_CREG_LOSS_COUNT 3      /* losses in window */
#define JAMMING_LEVEL3_DURATION 180    /* seconds for level 3 alert */

/*============================================================================
 * Power Management
 *============================================================================*/
#define BATTERY_LOW_MV 3300      /* 3.3V = low battery */
#define BATTERY_CRITICAL_MV 3100 /* 3.1V = shutdown modem */
#define SUPERCAP_SHUTDOWN_MS 700 /* graceful shutdown window */

/*============================================================================
 * COBS Framing
 *============================================================================*/
#define COBS_MAX_FRAME_SIZE 2048 /* Must match Rust MAX_FRAME_SIZE */
#define COBS_DELIMITER 0x00

/*============================================================================
 * Hardware Pin Map (STM32L476 LQFP-64)
 *============================================================================*/
/* FPGA UART (USART1) */
#define PIN_FPGA_TX GPIO_PIN_9   /* PA9 — USART1_TX */
#define PIN_FPGA_RX GPIO_PIN_10  /* PA10 — USART1_RX */
#define PIN_FPGA_CTS GPIO_PIN_11 /* PA11 — GPIO output */
#define PIN_FPGA_RTS GPIO_PIN_12 /* PA12 — GPIO input */

/* Modem UART (USART2) */
#define PIN_MODEM_TX GPIO_PIN_2  /* PA2 — USART2_TX */
#define PIN_MODEM_RX GPIO_PIN_3  /* PA3 — USART2_RX */
#define PIN_MODEM_RTS GPIO_PIN_1 /* PA1 — USART2_RTS */
#define PIN_MODEM_CTS GPIO_PIN_0 /* PA0 — USART2_CTS */

/* Modem Control */
#define PIN_MODEM_PWRKEY GPIO_PIN_0     /* PC0 */
#define PIN_MODEM_STATUS GPIO_PIN_1     /* PC1 */
#define PIN_MODEM_NETLIGHT GPIO_PIN_2   /* PC2 */
#define PIN_MODEM_RESET_N GPIO_PIN_3    /* PC3 */
#define PIN_MODEM_LDO_EN GPIO_PIN_9     /* PC9 */
#define PIN_MODEM_W_DISABLE GPIO_PIN_12 /* PC12 */

/* ★ V14.2: Radio Silence (GaN FET modem power kill) */
#define RADIO_SILENCE_PIN GPIO_PIN_10     /* PC10 — GaN FET gate */
#define RADIO_SILENCE_KEY_COMBO "*#7370#" /* Keypad shortcut */

/* SIM */
#define PIN_SIM_DETECT GPIO_PIN_11 /* PC11 */

/* ADC */
#define PIN_ADC_BATTERY GPIO_PIN_4   /* PA4 */
#define PIN_ADC_LIPO_NTC GPIO_PIN_5  /* PA5 */
#define PIN_ADC_MODEM_NTC GPIO_PIN_6 /* PA6 */

/* Tamper */
#define PIN_TAMPER_REED GPIO_PIN_5  /* PC5 */
#define PIN_TAMPER_LIMIT GPIO_PIN_6 /* PC6 */
#define PIN_FPGA_KILL GPIO_PIN_13   /* PC13 */

/* ★ P1 #19: OLED SSD1306 (I2C1) */
#define PIN_OLED_SCL GPIO_PIN_6 /* PB6 — I2C1_SCL */
#define PIN_OLED_SDA GPIO_PIN_7 /* PB7 — I2C1_SDA */
#define OLED_I2C_ADDR 0x3C      /* SSD1306 7-bit address */
#define OLED_WIDTH 128
#define OLED_HEIGHT 64

/* ★ P1 #20: Keypad 4×4 Matrix */
#define PIN_KP_ROW0 GPIO_PIN_4  /* PA4 — ROW0 output */
#define PIN_KP_ROW1 GPIO_PIN_5  /* PA5 — ROW1 output */
#define PIN_KP_ROW2 GPIO_PIN_6  /* PA6 — ROW2 output */
#define PIN_KP_ROW3 GPIO_PIN_7  /* PA7 — ROW3 output */
#define PIN_KP_COL0 GPIO_PIN_12 /* PB12 — COL0 input (pull-up) */
#define PIN_KP_COL1 GPIO_PIN_13 /* PB13 — COL1 input (pull-up) */
#define PIN_KP_COL2 GPIO_PIN_14 /* PB14 — COL2 input (pull-up) */
#define PIN_KP_COL3 GPIO_PIN_15 /* PB15 — COL3 input (pull-up) */
#define KP_DEBOUNCE_MS 20       /* Debounce period */
#define KP_T9_TIMEOUT_MS 800    /* T9 char confirm timeout */

/* ★ P1 #21: TPL5010 External Watchdog */
#define PIN_WDT_WAKE GPIO_PIN_7 /* PC7 — TPL5010 WAKE (input, EXTI) */
#define PIN_WDT_DONE GPIO_PIN_8 /* PC8 — TPL5010 DONE (output) */

/* ★ P1 #22: UART Firewall */
#define UART_FW_MAX_RESPONSE 512 /* Max AT response bytes */
#define UART_FW_STRIKE_LIMIT 10  /* Strikes before UART shutdown */

/*============================================================================
 * ★ P3 Security — Kişiselleştirme
 *============================================================================*/
#define PIN_MAX_ATTEMPTS 10         /* #33: 10 yanlış = zeroize */
#define PIN_LOCKOUT_TIER1_MS 30000  /* #33: 3 yanlış → 30s lockout */
#define PIN_LOCKOUT_TIER2_MS 300000 /* #33: 5 yanlış → 5min lockout */
#define DEAD_MAN_WARN_SEC 10        /* #36: Uyarı süresi */
#define DEAD_MAN_KILL_SEC 15        /* #36: Zeroize süresi */
#define STEALTH_AUTO_DIM_SEC 30     /* #35: Otomatik karartma */
#define PIXEL_SCRUB_INTERVAL_SEC 60 /* #35: Burn-in önlemi */

#endif /* CALLWHITE_CONFIG_H */
