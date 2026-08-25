/**
 * @file stm32l4xx_hal.h
 * @brief STM32L4 HAL Stub — Editor type resolution only
 *
 * Bu dosya gerçek STM32 HAL SDK'sı DEĞİLDİR.
 * Sadece editörün (clang) tip ve fonksiyon tanımlarını bulması için
 * minimum stub tanımlar içerir. Gerçek donanımda STM32CubeL4 SDK kullanılır.
 */
#ifndef __STM32L4xx_HAL_H
#define __STM32L4xx_HAL_H

#include <stdbool.h>
#include <stdint.h>

/*============================================================================
 * Status
 *============================================================================*/
typedef enum {
  HAL_OK = 0x00,
  HAL_ERROR = 0x01,
  HAL_BUSY = 0x02,
  HAL_TIMEOUT = 0x03
} HAL_StatusTypeDef;

/*============================================================================
 * GPIO
 *============================================================================*/
#define GPIO_PIN_0 ((uint16_t)0x0001)
#define GPIO_PIN_1 ((uint16_t)0x0002)
#define GPIO_PIN_2 ((uint16_t)0x0004)
#define GPIO_PIN_3 ((uint16_t)0x0008)
#define GPIO_PIN_4 ((uint16_t)0x0010)
#define GPIO_PIN_5 ((uint16_t)0x0020)
#define GPIO_PIN_6 ((uint16_t)0x0040)
#define GPIO_PIN_7 ((uint16_t)0x0080)
#define GPIO_PIN_8 ((uint16_t)0x0100)
#define GPIO_PIN_9 ((uint16_t)0x0200)
#define GPIO_PIN_10 ((uint16_t)0x0400)
#define GPIO_PIN_11 ((uint16_t)0x0800)
#define GPIO_PIN_12 ((uint16_t)0x1000)
#define GPIO_PIN_13 ((uint16_t)0x2000)
#define GPIO_PIN_14 ((uint16_t)0x4000)
#define GPIO_PIN_15 ((uint16_t)0x8000)
#define GPIO_PIN_SET 1
#define GPIO_PIN_RESET 0

#define GPIO_MODE_INPUT 0x00
#define GPIO_MODE_OUTPUT_PP 0x01
#define GPIO_MODE_OUTPUT_OD 0x11
#define GPIO_MODE_AF_PP 0x02
#define GPIO_MODE_AF_OD 0x12
#define GPIO_MODE_ANALOG 0x03
#define GPIO_MODE_IT_RISING 0x10110000
#define GPIO_MODE_IT_FALLING 0x10210000

#define GPIO_NOPULL 0x00
#define GPIO_PULLUP 0x01
#define GPIO_PULLDOWN 0x02

#define GPIO_SPEED_FREQ_LOW 0x00
#define GPIO_SPEED_FREQ_MEDIUM 0x01
#define GPIO_SPEED_FREQ_HIGH 0x02
#define GPIO_SPEED_FREQ_VERY_HIGH 0x03

#define GPIO_AF4_I2C1 0x04
#define GPIO_AF7_USART1 0x07
#define GPIO_AF7_USART2 0x07

typedef struct {
  volatile uint32_t MODER, OTYPER, OSPEEDR, PUPDR;
  volatile uint32_t IDR, ODR, BSRR, LCKR;
  volatile uint32_t AFR[2];
} GPIO_TypeDef;

typedef struct {
  uint32_t Pin;
  uint32_t Mode;
  uint32_t Pull;
  uint32_t Speed;
  uint32_t Alternate;
} GPIO_InitTypeDef;

typedef int GPIO_PinState;

#define GPIOA ((GPIO_TypeDef *)0x48000000UL)
#define GPIOB ((GPIO_TypeDef *)0x48000400UL)
#define GPIOC ((GPIO_TypeDef *)0x48000800UL)
#define GPIOD ((GPIO_TypeDef *)0x48000C00UL)

/*============================================================================
 * RTC + Backup Registers
 *============================================================================*/
typedef struct {
  volatile uint32_t TR, DR, CR, ISR, PRER, WUTR, _reserved0;
  volatile uint32_t ALRMAR, ALRMBR, WPR, SSR, SHIFTR;
  volatile uint32_t TSTR, TSDR, TSSSR, CALR, TAMPCR;
  volatile uint32_t ALRMASSR, ALRMBSSR, OR;
  volatile uint32_t BKP0R, BKP1R, BKP2R, BKP3R, BKP4R;
  volatile uint32_t BKP5R, BKP6R, BKP7R, BKP8R, BKP9R;
  volatile uint32_t BKP10R, BKP11R, BKP12R, BKP13R, BKP14R;
  volatile uint32_t BKP15R, BKP16R, BKP17R, BKP18R, BKP19R;
  volatile uint32_t BKP20R, BKP21R, BKP22R, BKP23R, BKP24R;
  volatile uint32_t BKP25R, BKP26R, BKP27R, BKP28R, BKP29R;
  volatile uint32_t BKP30R, BKP31R;
} RTC_TypeDef;

#define RTC ((RTC_TypeDef *)0x40002800UL)

/*============================================================================
 * I2C
 *============================================================================*/
typedef struct {
  volatile uint32_t CR1, CR2, OAR1, OAR2;
  volatile uint32_t TIMINGR, TIMEOUTR, ISR, ICR;
  volatile uint32_t PECR, RXDR, TXDR;
} I2C_TypeDef;

typedef struct {
  I2C_TypeDef *Instance;
  struct {
    uint32_t Timing;
    uint32_t OwnAddress1;
    uint32_t AddressingMode;
    uint32_t DualAddressMode;
    uint32_t OwnAddress2;
    uint32_t GeneralCallMode;
    uint32_t NoStretchMode;
  } Init;
} I2C_HandleTypeDef;

#define I2C1 ((I2C_TypeDef *)0x40005400UL)
#define I2C_ADDRESSINGMODE_7BIT 0x01
#define I2C_DUALADDRESS_DISABLE 0x00
#define I2C_GENERALCALL_DISABLE 0x00
#define I2C_NOSTRETCH_DISABLE 0x00
#define I2C_OA2_NOMASK 0x00

/*============================================================================
 * UART
 *============================================================================*/
typedef struct {
  volatile uint32_t CR1, CR2, CR3, BRR;
} USART_TypeDef;

typedef struct {
  USART_TypeDef *Instance;
  uint32_t BaudRate, WordLength, StopBits, Parity;
  uint32_t Mode, HwFlowCtl, OverSampling;
} UART_HandleTypeDef;

#define USART1 ((USART_TypeDef *)0x40013800UL)
#define USART2 ((USART_TypeDef *)0x40004400UL)

/*============================================================================
 * SPI
 *============================================================================*/
typedef struct {
  volatile uint32_t CR1, CR2, SR, DR;
} SPI_TypeDef;

typedef struct {
  SPI_TypeDef *Instance;
} SPI_HandleTypeDef;

#define SPI1 ((SPI_TypeDef *)0x40013000UL)

/*============================================================================
 * TIM
 *============================================================================*/
typedef struct {
  volatile uint32_t CR1, CR2, SMCR, DIER, SR, EGR;
  volatile uint32_t CCMR1, CCMR2, CCER, CNT, PSC, ARR;
  volatile uint32_t _reserved;
  volatile uint32_t CCR1, CCR2, CCR3, CCR4;
} TIM_TypeDef;

typedef struct {
  TIM_TypeDef *Instance;
} TIM_HandleTypeDef;

#define TIM_CHANNEL_1 0x00
#define TIM_CHANNEL_2 0x04
#define TIM_CHANNEL_3 0x08
#define TIM_CHANNEL_4 0x0C

#define __HAL_TIM_SET_COMPARE(h, ch, v) ((h)->Instance->CCR1 = (v))

/*============================================================================
 * NVIC / System Intrinsics
 *============================================================================*/
#define __NOP() ((void)0)
#define __disable_irq() ((void)0)
#define __enable_irq() ((void)0)

typedef int IRQn_Type;
#define EXTI9_5_IRQn 23
#define USART1_IRQn 37
#define USART2_IRQn 38

/*============================================================================
 * Clock Enable Macros
 *============================================================================*/
#define __HAL_RCC_GPIOA_CLK_ENABLE() ((void)0)
#define __HAL_RCC_GPIOB_CLK_ENABLE() ((void)0)
#define __HAL_RCC_GPIOC_CLK_ENABLE() ((void)0)
#define __HAL_RCC_GPIOD_CLK_ENABLE() ((void)0)
#define __HAL_RCC_I2C1_CLK_ENABLE() ((void)0)
#define __HAL_RCC_USART1_CLK_ENABLE() ((void)0)
#define __HAL_RCC_USART2_CLK_ENABLE() ((void)0)
#define __HAL_RCC_SPI1_CLK_ENABLE() ((void)0)
#define __HAL_RCC_TIM2_CLK_ENABLE() ((void)0)
#define __HAL_RCC_PWR_CLK_ENABLE() ((void)0)
#define __HAL_RCC_RTC_ENABLE() ((void)0)

/*============================================================================
 * HAL Functions
 *============================================================================*/

/* Core */
static inline HAL_StatusTypeDef HAL_Init(void) { return HAL_OK; }
static inline uint32_t HAL_GetTick(void) { return 0; }
static inline void HAL_Delay(uint32_t ms) { (void)ms; }
static inline void HAL_NVIC_SystemReset(void) {}

/* NVIC */
static inline void HAL_NVIC_SetPriority(int irq, uint32_t pre, uint32_t sub) {
  (void)irq;
  (void)pre;
  (void)sub;
}
static inline void HAL_NVIC_EnableIRQ(int irq) { (void)irq; }

/* GPIO */
static inline void HAL_GPIO_Init(GPIO_TypeDef *g, GPIO_InitTypeDef *i) {
  (void)g;
  (void)i;
}
static inline void HAL_GPIO_WritePin(GPIO_TypeDef *g, uint16_t p,
                                     GPIO_PinState s) {
  (void)g;
  (void)p;
  (void)s;
}
static inline GPIO_PinState HAL_GPIO_ReadPin(GPIO_TypeDef *g, uint16_t p) {
  (void)g;
  (void)p;
  return GPIO_PIN_RESET;
}
static inline void HAL_GPIO_EXTI_IRQHandler(uint16_t p) { (void)p; }

/* I2C */
static inline HAL_StatusTypeDef HAL_I2C_Init(I2C_HandleTypeDef *h) {
  (void)h;
  return HAL_OK;
}
static inline HAL_StatusTypeDef HAL_I2C_Mem_Write(I2C_HandleTypeDef *h,
                                                  uint16_t a, uint16_t ma,
                                                  uint16_t ms, uint8_t *d,
                                                  uint16_t s, uint32_t t) {
  (void)h;
  (void)a;
  (void)ma;
  (void)ms;
  (void)d;
  (void)s;
  (void)t;
  return HAL_OK;
}
static inline HAL_StatusTypeDef HAL_I2C_Master_Transmit(I2C_HandleTypeDef *h,
                                                        uint16_t a, uint8_t *d,
                                                        uint16_t s,
                                                        uint32_t t) {
  (void)h;
  (void)a;
  (void)d;
  (void)s;
  (void)t;
  return HAL_OK;
}

/* UART */
static inline HAL_StatusTypeDef
HAL_UART_Transmit(UART_HandleTypeDef *h, uint8_t *d, uint16_t s, uint32_t t) {
  (void)h;
  (void)d;
  (void)s;
  (void)t;
  return HAL_OK;
}
static inline HAL_StatusTypeDef
HAL_UART_Receive(UART_HandleTypeDef *h, uint8_t *d, uint16_t s, uint32_t t) {
  (void)h;
  (void)d;
  (void)s;
  (void)t;
  return HAL_OK;
}

/* SPI */
static inline HAL_StatusTypeDef
HAL_SPI_Transmit(SPI_HandleTypeDef *h, uint8_t *d, uint16_t s, uint32_t t) {
  (void)h;
  (void)d;
  (void)s;
  (void)t;
  return HAL_OK;
}

/* TIM */
static inline HAL_StatusTypeDef HAL_TIM_PWM_Start(TIM_HandleTypeDef *h,
                                                  uint32_t c) {
  (void)h;
  (void)c;
  return HAL_OK;
}
static inline HAL_StatusTypeDef HAL_TIM_PWM_Stop(TIM_HandleTypeDef *h,
                                                 uint32_t c) {
  (void)h;
  (void)c;
  return HAL_OK;
}

#endif /* __STM32L4xx_HAL_H */
