# Callwhite Cellular Module — Mühendislik Planı

TITAN V14 FPGA'nın BLACK UART çıkışını 4G/LTE hücresel ağa bağlayan bağımsız iletişim modülünün detaylı tasarım planı.

---

## Mevcut Durum

### FPGA

`artix7_top_v14.vhd` — mevcut pinler:

```vhdl
BLACK_UART_RX_PIN : in  std_logic;   -- Şifreli veri giriş
BLACK_UART_TX_PIN : out std_logic;   -- Şifreli veri çıkış
```

Şu an bu pinler direkt kabloya bağlanıyor. Hedef: bu pinleri 4G/LTE modem'e bağlamak.

> [!CAUTION]
> EC25 UART 1.8V, STM32 3.3V — doğrudan bağlantı modem'i yakar. Level shifter zorunlu.

> [!WARNING]
> **FPGA DEĞİŞİKLİĞİ GEREKLİ:** Mevcut BLACK UART'ta CTS/RTS pini yok. `BLACK_UART_CTS_PIN : in std_logic` (MCU → FPGA: "DUR!") ve `BLACK_UART_RTS_PIN : out std_logic` (FPGA → MCU: "bekle") eklenmeli.

---

## Sistem Mimarisi

```
┌─────────────────────────────────────────────────────────────────┐
│                    CALLWHITE TITAN V15                          │
│                                                                 │
│  ┌──────────────┐    UART     ┌──────────────┐  LEVEL    ┌──────────┐│
│  │   ARTIX-7    │◄──────────►│  STM32L4     │◄─SHIFT──►│ Quectel  ││
│  │   FPGA       │  921600    │  MCU  3.3V   │ TXB0104  │ EC25-E   ││
│  │              │  (BLACK)   │              │ 3.3↔1.8V │ 1.8V     ││
│  │  AES-256     │            │  TCP/IP      │ TX/RX +  │          ││
│  │  Kill Proto  │            │  AT Parser   │ RTS/CTS  │ [SIM]    ││
│  │  TRNG        │            │  Session Mgr │          └──────────┘│
│  │  AEGIS       │            │  Heartbeat   │               │ SMA   │
│  └──────────────┘            └──────┬───────┘               │       │
│         │                          │                        │       │
│  ┌──────┐  ┌──────┐  ┌──────┐  ┌──┴──┐  ┌──────────────┐  │       │
│  │EKRAN │  │TUŞLAR│  │TAMPER│  │LDO  │  │  LDO 4.0V    │  │       │
│  │OLED  │  │4x4   │  │SWITCH│  │3.3V │  │  + CAP BANK  │  │       │
│  └──────┘  └──────┘  └──────┘  └─────┘  └──────────────┘  │       │
└──────────────────────────────────────────────────────────┼───────┘
                                                           │
                                                      ┌────┴────┐
                                                      │ Yagi    │
                                                      │ 12 dBi  │
                                                      │ + LNA   │
                                                      └─────────┘
```

---

## Bileşen Listesi (BOM)

| # | Bileşen | Model | Adet | Birim Fiyat | Toplam |
|---|---------|-------|------|-------------|--------|
| 1 | FPGA Board | Arty A7-100T (mevcut) | 1 | $130 | $130 |
| 2 | MCU | STM32L476RGT6 (LQFP-64) | 1 | $8 | $8 |
| 3 | 4G Modem | Quectel EC25-E Mini PCIe | 1 | $22 | $22 |
| 4 | SIM Slot | Nano SIM push-push **+ Card Detect (CD) switch** | 1 | $1.50 | $1.50 |
| 5 | SIM ESD Koruma | SMF15CT1G (SIM hatları için) | 1 | $1 | $1 |
| 5b | HSE Kristal | 8MHz ABM8G ±20ppm + 2×20pF yük kap | 1 | $1 | $1 |
| 6 | LNA | Skyworks SKY67151-396LF | 1 | $4 | $4 |
| **6b** | **RF Switch** | **SKY13351-378LF SPDT (TX/RX yol ayrımı, LNA koruması)** | **1** | **$2** | **$2** |
| **6c** | **SAW Filtre** | **Murata SAFFB1G84 (B3 1800MHz, LNA öncesi bant filtre)** | **1** | **$1** | **$1** |
| 7 | Anten (Main) | SMA Yagi 800-2600MHz 12dBi | 1 | $25 | $25 |
| 8 | Anten (Diversity) | PCB dipole veya stubby 3dBi | 1 | $5 | $5 |
| 9 | Anten (GNSS) | Pasif seramik patch 25x25mm **(DNP — varsayılan devre dışı)** | 1 | $3 | $3 |
| 10 | SMA Konnektör | Dişi, PCB montaj | 2 | $2 | $4 |
| 11 | Level Shifter | TXB0104 (3.3V↔1.8V, 4-ch) | 1 | $2 | $2 |
| 12 | LDO Regülatör | AP2112K-3.3 (ULDO, 250mV dropout) | 1 | $0.50 | $0.50 |
| 12b | Boost Converter | MT3608 (3.7V→5V, Arty A7 besleme — Faz 1) | 1 | $1 | $1 |
| 13 | LDO Regülatör | MIC29302 (4.0V 3A, Modem) | 1 | $3 | $3 |
| 13 | Cap Bank | 1000µF Elektrolitik + 10×100nF Seramik | 1 set | $3 | $3 |
| 14b | Supercapacitor | **0.47F/5.5V** KEMET FG + Schottky + 0.5Ω inrush R | 1 | $3 | $3 |
| 15 | Ext. Watchdog | TPL5010 (35nA, hard reset) | 1 | $2 | $2 |
| 16 | EMI Filtre | Ferrite Bead (BLM18PG) + 22pF cap, 8 set | 8 | $0.50 | $4 |
| 16b | Seri Sonlandırma | 22Ω 0402, tüm UART hatları (TX/RX/RTS/CTS) | 8 | $0.05 | $0.50 |
| 16c | SIM Decoupling | 100nF + 22pF (SIM_VCC), 22pF (SIM_DATA), 15pF (SIM_CLK) | 1 set | $0.50 | $0.50 |
| 17 | RF Match (DNP) | Pi-Network pad: 2×Cap + 1×Ind (0402) | 1 set | $0 | $0 |
| 18 | 0Ω Jumper (JTAG/SWD) | Debug port depopulation | 6 | $0.10 | $1 |
| 18b | SPI Flash (Staging) | W25Q16 2MB SPI NOR (OTA firmware staging) | 1 | $0.50 | $0.50 |
| 19 | OLED Ekran | SSD1306 128x64 I2C | 1 | $5 | $5 |
| 20 | Tuş Takımı | 4x4 Matrix Membrane | 1 | $3 | $3 |
| 21 | Li-Po Batarya | 3.7V 5000mAh (NTC çıkışlı) | 1 | $12 | $12 |
| 22 | Şarj IC | TP4056 + DW01 koruma | 1 | $1 | $1 |
| 23 | Anti-Tamper Switch | Manyetik Reed + Limit Switch | 2 | $2 | $4 |
| 23b | Recovery Button | Mikro tact switch (tamper bölgesi içinde) | 1 | $0.20 | $0.20 |
| 24 | PCB | 4 katman, 10x8cm, RF izolasyon + RED/BLACK moat | 1 | $15 | $15 |
| 24b | Anten ESD | PESD5V0U1UA TVS (<0.5pF), SMA + LNA giriş | 2 | $0.30 | $0.60 |
| 24c | Test Point Pad | Konnektörsüz TP, pogo-pin uyumlu | 5 | $0.05 | $0.25 |
| **24d** | **GDT Surge Protector** | **Bourns 2027-09-CLF (90V, yıldırım/ESD — SMA girişi)** | **1** | **$1.50** | **$1.50** |
| **24e** | **Modem USB Test Pad** | **Micro-USB footprint (DNP konnektör, modem FW update)** | **1** | **$0.50** | **$0.50** |
| **24f** | **NTC (Modem)** | **10KΩ NTC 0402 + divider (EC25 termal izleme)** | **1** | **$0.30** | **$0.30** |
| | | | | **TOPLAM** | **~$298** |

---

## Modül Detayları

### 1. MCU Katmanı (STM32L476)

MCU, FPGA ile 4G modem arasında köprü görevi görür. FPGA'nın AT komutu bilmesine gerek yok.

#### FPGA Değişikliği (artix7_top_v14.vhd — İLK VHDL DEĞİŞİKLİĞİ):

```vhdl
-- EŞİT: Mevcut port listesine ekle
BLACK_UART_CTS_PIN : in  std_logic;   -- MCU → FPGA: '1' = DUR
BLACK_UART_RTS_PIN : out std_logic;   -- FPGA → MCU: '1' = bekle

-- uart_driver BLACK instance'a bağla
uart_black_inst : entity work.uart_driver
    port map (
        ...
        cts_n    => BLACK_UART_CTS_PIN,  -- CTS (active high = dur)
        rts_out  => BLACK_UART_RTS_PIN,  -- RTS (gearbox doluluk)
        ...
    );

-- uart_driver.vhd TX FSM'ine ekle (tx_idle state):
if tx_start = '1' and cts_n = '0' then  -- CTS izin veriyorsa gönder
    tx_state <= tx_sending;
end if;

-- RTS: data_gearbox packer doluluk seviyesine bağlı
-- gearbox_count >= 14 (16'dan 14 = %87.5) → RTS HIGH → MCU durur
BLACK_UART_RTS_PIN <= '1' when gearbox_packer_count >= 14 else '0';
```

> [!IMPORTANT]
> **RTS neden gerekli?** MCU 4G modemden gelen downlink burst'ü FPGA'ya hızla basabilir. FPGA'da AES motoru veya Omega Cloak dummy round aktifken (`omega_stall='1'`) gearbox dolar ve sonraki byte kaybolur → AES-CTR counter desync → session crash.

#### Görevleri:
- FPGA'dan gelen şifreli byte'ları tamponla
- TCP/UDP soketi aç/kapat (AT komutları ile)
- Gelen veriyi FPGA'ya ilet
- Modem durum izleme (sinyal gücü, bağlantı, hata)
- OLED ekrana durum bilgisi yaz
- Tuş takımından komut al (karşı taraf IP, bağlantı modu)
- Heartbeat: modem canlılık kontrolü

#### Pin Bağlantıları:

```
STM32L476 Pin Haritası:
├── USART1 (TX: PA9,  RX: PA10)  → FPGA BLACK UART (3.3V direkt)
├── USART2 (TX: PA2,  RX: PA3)   → TXB0104 → EC25 UART (1.8V)
│   ├── RTS: PA1                  → TXB0104 → EC25 RTS (HW AKIŞ KONTROLÜ)
│   └── CTS: PA0                  → TXB0104 → EC25 CTS (HW AKIŞ KONTROLÜ)
├── I2C1   (SDA: PB7, SCL: PB6)  → OLED SSD1306
├── GPIO   (PB0-PB3, PB4-PB7)    → 4x4 Tuş matrisi
├── GPIO   (PC0)                  → Modem PWRKEY
├── GPIO   (PC1)                  → Modem STATUS  ★ Bağlantı izleme
├── GPIO   (PC2)                  → Modem NETLIGHT ★ Ağ durumu LED
├── GPIO   (PC3)                  → Modem RESET_N  ★ Hard reset (300ms LOW pulse)
├── GPIO   (PC4)                  → LNA Enable / RF Switch kontrol
├── GPIO   (PC5)                  → Reed Switch (kasa tamper)
├── GPIO   (PC6)                  → Limit Switch (kasa tamper)
├── ADC1   (PA4)                  → Batarya voltaj ölçüm
├── ADC1   (PA5)                  → ★ Li-Po NTC sıcaklık sensörü
├── ADC1   (PA6)                  → ★ Modem NTC sıcaklık sensörü (V15 yeni)
├── GPIO   (PC7)                  → ★ TPL5010 WAKE (watchdog heartbeat)
├── GPIO   (PC8)                  → ★ TPL5010 DONE (alive sinyal)
├── GPIO   (PC9)                  → ★ MIC29302 ENABLE (modem LDO power sequencing)
├── GPIO   (PC10)                 → ★ Recovery Button (boot sırasında kontrol)
├── GPIO   (PC11)                 → ★ SIM Card Detect (CD switch, V15 yeni)
├── GPIO   (PC12)                 → ★ Modem W_DISABLE# (RF sessizlik modu, V15 yeni)
├── EXTI   (PA7)                  → ★ Modem RI (Ring Indicator — uyandırma, V15 yeni)
├── GPIO   (PA8)                  → ★ Modem DTR (deep sleep kontrolü, V15 yeni)
├── UART4  (TX: PD1)              → ★ Debug TP1 (hidden diagnostic log)
├── SPI2   (PB12=CS, PB13=SCK, PB14=MISO, PB15=MOSI) → ★ W25Q16 SPI Flash
└── GPIO   (PC13)                 → FPGA kill_signal (acil imha)
```

> [!IMPORTANT]
> TXB0104 level shifter MCU↔Modem arasında 4 kanal: TX, RX, RTS, CTS. Modem 1.8V, MCU 3.3V.

> [!WARNING]
> **Altın Filtre Dizilimi** — tüm UART hatlarına (FPGA↔MCU ve MCU↔Modem):
> ```
> [IC TX] → [22Ω Seri] → [Ferrite Bead] → [22pF Cap] → [IC RX]
> ```
> - 22Ω: yansıma sönümleme (921600 baud, 3ns rise time, >4.5cm trace).
> - Ferrite: yüksek frekanslı RF gürültüsü filtreleme (4G modem EMI).
> - 22pF: LPF oluşturarak sinyal kenarlarını yumuşatır.
> - 8 hat: FPGA TX/RX + Modem TX/RX/RTS/CTS + SPI MOSI/MISO.

#### Firmware Yapısı (C, FreeRTOS):

```
firmware/
├── main.c                 -- Ana döngü, init, FreeRTOS task'lar
├── uart_fpga.c/.h         -- FPGA UART + DMA ring buffer
├── uart_modem.c/.h        -- Modem UART + RTS/CTS akış kontrolü
├── at_engine.c/.h         -- AT komut state machine
├── tcp_session.c/.h       -- TCP soket yönetimi
├── cobs_framing.c/.h      -- ★ COBS encode/decode (TCP stream framing)
├── escape_handler.c/.h    -- ★ Transparent mode escape (+++) yönetimi
├── modem_monitor.c/.h     -- ★ STATUS/NETLIGHT/RI pin izleme, reconnect
├── secure_boot.c/.h       -- ★ SBSFU: ECDSA-P256 imza doğrulama
├── watchdog_ext.c/.h      -- ★ TPL5010 harici watchdog yönetimi
├── display.c/.h           -- OLED ekran driver
├── keypad.c/.h            -- 4x4 tuş tarama
├── power.c/.h             -- Batarya, güç yönetimi
├── thermal.c/.h           -- ★ NTC sıcaklık izleme (Li-Po + Modem) + şarj/throttle
├── tamper.c/.h            -- ★ Reed/Limit switch → kill_signal
├── heartbeat.c/.h         -- Modem canlılık kontrolü
├── spi_flash.c/.h         -- ★ W25Q16 SPI Flash driver (OTA staging)
├── debug_log.c/.h         -- ★ Kara kutu event ring buffer
├── sim_manager.c/.h       -- ★★ V15: SIM detect, PIN yönetimi, VSIM voltaj
├── band_config.c/.h       -- ★★ V15: Band/operatör kilidi, roaming, 2G fallback
├── jamming_detect.c/.h    -- ★★ V15: RSSI anomali tespiti, RF bozucu uyarısı
├── modem_thermal.c/.h     -- ★★ V15: AT+QTEMP izleme, throttle, termal shutdown
└── config.h               -- IP, APN, port, band, timeout ayarları
```

---

### 2. 4G Modem Katmanı (Quectel EC25-E)

**Spesifikasyon:**
- LTE Cat 4: 150 Mbps DL / 50 Mbps UL
- Quad-band: B1/B3/B7/B8/B20 (Türkiye tam uyumlu)
- UART baud: 115200 varsayılan → 921600 hedef (aşağıya bkz.)
- Güç: 3.3-4.3V, tipik 250mA, pik 2A (TX burst)
- Sıcaklık: -40°C ~ +85°C (askeri derece)

> [!TIP]
> **Baud Rate Yükseltme (115200 → 921600):** 115200'de 16 byte (1 AES blok) = ~1.4ms. 921600'de = ~0.17ms. LTE Cat 4 downlink burst sırasında UART darboğaz olabilir.
>
> `uart_driver.vhd` generic `BAUD_RATE` parametresi zaten var — değişiklik trivial. Gereksinim: MCU tarafında HSE kristal (8MHz ABM8G ±20ppm) zorunlu. STM32 dahili HSI osilatör ±3% @ 85°C sapma gösterir — 921600'de framing error. HSE ile sapma ±0.002% — sorun tamamen çözülür.

#### AT Komut Akışı (V15 — SIM Yönetimi + TCP Transparent Mode):

```
→ AT                          -- Modem hazır mı?
← OK
→ AT+QSIMSTAT?               -- ★ V15: SIM kart fiziksel varlık kontrolu
← +QSIMSTAT: 0,1              -- 1 = SIM takılı (CD switch doğrulaması)
→ AT+CPIN?                    -- SIM durumu
← +CPIN: SIM PIN              -- ★ V15: PIN gerekiyor
→ AT+CPIN="1234"             -- ★ V15: Kullanıcıdan alınan PIN
← OK
→ AT+QSIMVOL?                -- ★ V15: SIM voltaj kontrolü
← +QSIMVOL: 1                 -- 1 = 1.8V (modern SIM)
→ AT+CREG?                    -- Ağ kaydı
← +CREG: 0,1                 -- Kayıtlı
→ AT+CSQ                      -- Sinyal gücü
← +CSQ: 22,0                 -- -69 dBm (iyi)
→ AT+QTEMP                   -- ★ V15: Modem sıcaklığı
← +QTEMP: 32,35,31            -- PMIC:32°C, XO:35°C, PA:31°C
→ AT+QICSGP=1,1,"internet"   -- APN ayarla (config.h'den alınabilir)
← OK
→ AT+QIACT=1                 -- PDP context aktif
← OK
→ AT+QIOPEN=1,0,"TCP","TARGET_IP",PORT,0,1  -- TCP bağlantı
← +QIOPEN: 0,0               -- Bağlandı
→ AT+QISEND=0,16              -- 16 byte gönder
← >                           -- Veri bekle
→ [AES ciphertext bytes]      -- FPGA'dan gelen şifreli veri
← SEND OK
```

> [!IMPORTANT]
> **V15 SIM Yönetimi Akışı (sim_manager.c):**
> 1. Boot'ta `PC11` (Card Detect) kontrol → SIM yoksa → OLED: "SIM TAKILMADI"
> 2. `AT+CPIN?` → "SIM PIN" gelirse → Tuş takımından PIN iste → 3 deneme hakkı
> 3. `AT+CPIN?` → "SIM PUK" gelirse → OLED: "SIM KİLİTLİ — PUK GEREKLİ"
> 4. `AT+QSIMVOL?` → voltaj uyumsuzluğu varsa otomatik düzelt
> 5. `AT+CLCK="SC",2` → SIM PIN kilidi aktif mi kontrol (isteğe bağlı etkinleştirme)

#### Transparent Mode (Tercih Edilen):

```
→ AT+QIOPEN=1,0,"TCP","TARGET_IP",PORT,0,2  -- mode=2: transparent
← CONNECT
-- Artık UART'a yazılan her şey direkt TCP'ye gider
-- FPGA → MCU → Modem → Internet → Karşı TITAN
```

> [!WARNING]
> **Escape Stratejisi:** Bağlantı koptuğunda MCU veri göndermeye devam edebilir.

#### Transparent Mode Güvenlik Mekanizması:

```
MCU Firmware — modem_monitor task (50ms döngü):

1. STATUS pin izle (PC1):
   - STATUS=LOW → modem kapandı → AT moduna geri dön → reconnect
   - STATUS=HIGH → modem çalışıyor

2. NETLIGHT pin izle (PC2):
   - 64ms ON/800ms OFF → ağ aranıyor → veri gönderme
   - 64ms ON/3s OFF → kayıtlı → veri gönderilebilir
   - Sürekli OFF → ağ yok → AT moduna geç

3. Escape Sequence:
   - Bağlantı 5 saniye yanıt vermezse:
     → 1 saniye sessizlik
     → "+++" gönder
     → 1 saniye bekle
     → "AT" gönder, "OK" bekle
     → AT moduna dönüldü → reconnect veya hata raporla

4. Veri kaybı koruması:
    - RTS/CTS aktif → modem tamponu dolduğunda MCU durur
    - MCU ring buffer 4KB → FPGA'dan gelen veri tamponlanır
    - High Watermark: buffer %80 dolduğunda CTS HIGH → FPGA durur
    - Low Watermark: buffer %50'ye düştüğünde CTS LOW → FPGA devam eder
    - Hysteresis: %80/%50 → CTS oscillation önlenir
    - Fren mesafesi: FPGA en fazla 1 byte daha gönderir (TX FSM IDLE'da kontrol)
```

---

### 3. Anten + LNA Katmanı (V15 Güncellemesi)

> [!CAUTION]
> **V15 KRİTİK DÜZELTME:** Orijinal planın sinyal zinciri LNA'yı doğrudan Main anten portuna bağlıyordu. EC25 Main portu **çift yönlü** (TX + RX): TX burst'te +23 dBm (200 mW) gücünde sinyal yayınlar. SKY67151 LNA'nın max giriş gücü +10 dBm — **13 dB aşım LNA'yı kalıcı olarak yakar.** RF switch ile TX/RX yol ayrımı zorunludur.

#### Sinyal Zinciri (V15 — Düzeltilmiş):

```
                          ┌──── TX path ─────────────────────────────┐
                          │  (PA → directly to antenna, no LNA)       │
Baz İstasyonu ──[RF]──►  Yagi Anten (12 dBi)                        │
                              │                                       │
                              ▼                                       │
                         SMA Konnektör                                │
                              │                                       │
                              ▼                                       │
                    GDT Surge (Bourns 2027-09)  ← Yıldırım koruma    │
                              │                                       │
                              ▼                                       │
                    TVS1 (PESD5V0U1UA, <0.5pF)  ← ESD koruma         │
                              │                                       │
                              ▼                                       │
                    RF Switch (SKY13351-378LF)  ← MCU PC4 kontrol    │
                         │              │                              │
                    RX path        TX path ────────────────────────────┘
                         │
                         ▼
                    SAW Filtre (Murata SAFFB1G84)  ← Band seçici
                         │
                         ▼
                    TVS2 (PESD3V3U1UA, <0.2pF)  ← İnce LNA koruma
                         │
                         ▼
                    LNA (SKY67151, +15 dB, NF <1 dB)
                         │
                         ▼
                    EC25 MAIN RF girişi
```

> [!IMPORTANT]
> **RF Switch Kontrol Mantığı (MCU firmware):**
> - EC25'in TX aktifliğini algılamak için `AT+QCFG="urc/ri/ring"` kullanılır
> - Alternatif: EC25 STATUS pini + timing — TX burst ~1ms, guard time 100µs
> - **Varsayılan pozisyon: RX** (fail-safe, LNA korunur)
> - SKY13351: insertion loss 0.3 dB, isolation 28 dB, switching time 50ns

#### GDT + TVS Surge Koruma Zinciri:

```
Yıldırım / Statik Yük Akışı:

Anten → SMA → [GDT: 90V spark gap] → [TVS1: 5V clamp] → RF Switch → [TVS2: 3.3V] → LNA

GDT (Bourns 2027-09-CLF):
  - Spark gap: 90V DC
  - Surge current: 5kA (8/20µs)
  - Capacitance: 0.7pF (RF'i etkilemez)
  - Görev: kaba enerji sönümleme (yıldırım indüksiyonu)

TVS1 (PESD5V0U1UA):
  - Clamp: 5V
  - Capacitance: <0.5pF
  - Görev: GDT sonrası kalıntı enerji sönümleme

TVS2 (PESD3V3U1UA):
  - Clamp: 3.3V
  - Capacitance: <0.2pF
  - Görev: LNA girişi ince koruma (ESD + RF switch kaçağı)

★ GDT + TVS1 + TVS2 = üç katmanlı koruma — askeri standartta gerekli.
★ Tüm GND bağlantıları en kısa via ile toprak düzlemine.
```

#### SAW Filtre (Band Seçici):

```
Murata SAFFB1G84:
  - Merkez frekansı: 1842.5 MHz (B3 — Türkiye birincil)
  - Bant genişliği: 75 MHz (1805-1880 MHz)
  - Insertion loss: 1.5 dB
  - Out-of-band rejection: >35 dB

Neden gerekli:
  - Wi-Fi (2.4 GHz), Bluetooth, ISM bandından gelen parazitler LNA'yı doyurabilir
  - LNA doyunca (compression), wanted sinyalin SNR dramatik düşer
  - SAW filtre ile LNA sadece hedef bandı görür → NF avantajı korunur
  - Maliyet: ~$1/adet — performans/fiyat oranı mükemmel

★ Multi-band operasyon (B1/B7/B8/B20) için:
  - Üretim PCB'de SAW yerine wideband BAW filtre (TDK B39) düşünülebilir
  - Veya SAW footprint DNP → LNA wideband modda kullanılır
```

#### Link Budget Hesabı (V15 — Güncellenmiş):

```
Baz istasyonu TX gücü:    +43 dBm (20W, tipik)
Path loss (10 km, 1800MHz): -138 dB
Anten kazancı:            +12 dB (Yagi)
Kablo kaybı (LMR-195):   -1.8 dB (3m × 0.6 dB/m)  ★ V15: kablo tipi belirtildi
GDT + TVS kaybı:         -0.2 dB
RF Switch kaybı:          -0.3 dB (SKY13351 insertion loss)
SAW Filtre kaybı:         -1.5 dB (Murata SAFFB1G84)
LNA kazancı:              +15 dB
──────────────────────────────────
Alıcı gücü:              -71.8 dBm
EC25 hassasiyeti:         -106 dBm
Margin:                   +34.2 dB ← YETERLİ

★ Orijinal plan: 36 dB margin (kablo/switch/SAW kaybı hesaplanmamıştı)
★ Gerçek margin: 34.2 dB — hâlâ çok güçlü
★ Margin > 20 dB = dağ, çöl, iç mekan dahil güvenilir bağlantı
```

> [!TIP]
> **Anten Kablosu Seçimi:** RG174 (ince, esnek) 1800 MHz'de **1.1 dB/m** kayıp verir — 3m kablo ile 3.3 dB kayıp. **LMR-195** (biraz daha kalın) 0.6 dB/m — 3m'de 1.8 dB. Askeri terminal için LMR-195 önerilir. RG174 sadece prototip fazında kabul edilebilir.

#### VSWR Koruması (Anten Ayrılma Durumu):

```
SMA anten çıkarılırsa veya kablo hasarlıysa:
  - VSWR > 10:1 → yansıyan güç modem PA'ya geri döner
  - EC25 dahili VSWR koruması var ama uzun süreli maruz kalma → PA termal hasar

MCU VSWR İzleme (modem_monitor.c):
  - AT+QENG="servingcell" → RSRP sorgusu
  - RSRP < -120 dBm + RSRQ < -15 dB → olası anten hasarı
  - 3 ardışık ölçüm başarısız → OLED: "⚠️ ANTEN KONTROLÜ" uyarısı
  - Modem TX gücünü düşür: AT+QCFG="txpower",1 (yarım güç)
```

Telefonla karşılaştırma: Telefon anteni 2 dBi + LNA yok = -95 dBm → **23 dB daha zayıf.**

---

### 4. RF İzolasyonu ve TRNG Koruması

> [!CAUTION]
> EC25 TX burst (2A pik) ciddi EMI yayar. FPGA Ring Oscillator entropisi bozulabilir.

#### PCB Tasarım Kuralları:

```
┌───────────────────────────────────────────────────┐
│                  TOP LAYER                        │
│                                                   │
│  ┌─────────────┐    ≥15mm     ┌────────────────┐  │
│  │  FPGA       │   İZOLASYON  │  RF BÖLGE      │  │
│  │  ZONE       │   GAP        │                │  │
│  │             │   (GND ile   │  EC25 Modem    │  │
│  │  Artix-7    │   doldur)    │  SMA           │  │
│  │  TRNG RO    │              │  LNA           │  │
│  │  STM32      │              │  Matching      │  │
│  └─────────────┘              └────────────────┘  │
│                                                   │
│  Layer 2: GND (kesintisiz düzlem)                 │
│  Layer 3: Power (bölünmüş: 1.8V | 3.3V | 4.0V)   │
│  Layer 4: GND (kesintisiz düzlem)                 │
└───────────────────────────────────────────────────┘
```

**Decoupling Stratejisi (Modem güç hattı):**
- 1×1000µF düşük ESR elektrolitik (TX burst akım reservoir)
- 10×100nF X7R seramik (yüksek frekans filtreleme)
- 1×10µF tantalum (orta frekans)
- Yerleşim: modem VCC pinine mümkün olduğunca yakın

**TRNG Koruma:**
- Ring oscillator'lar FPGA'nın modem'den en uzak köşesine yerleştirilir (LOC constraint)
- GND guard ring: RO etrafında kesintisiz toprak halkası
- Differential clock pair: EMI etkisini azaltır

**SIM ESD Koruması:**
- SMF15CT1G ESD diyodu EC25 ile SIM yuvası arasına yerleştirilir
- SIM sinyal yolları (CLK, DATA, RST, VCC) RF hattına paralel gitmez
- SIM yuvadan modem'e en kısa yol, RF anteninden uzak
- SIM slot PCB'nin ORTASINA, tamper bölgesi içine yerleştirilir
- Dışarıdan erişim yok — kapağı açmadan SIM çıkarılamaz → kapak açılırsa kill_signal

#### SIM VCC Decoupling + Quiet Ground:

```
EC25 SIM_VCC ──┬── [100nF] ──┬── SIM Slot VCC
               │              │
              GND            [22pF]
                              │
                             GND (★ SIM Quiet Ground)

EC25 SIM_DATA ── [22pF] ── GND   (RF filtre)
EC25 SIM_CLK  ── [15pF] ── GND   (RF filtre)
```

> [!CAUTION]
> **SIM Quiet Ground:** Modem 2A TX burst sırasında GND plane'de ground bounce oluşur ve SIM haberleşmesini bozar. SIM yuvasının GND via'ları modem RF GND'den ayrı bir noktaya bağlanmalı — ana GND plane'e sadece tek nokta star ground bağlantısı (batarya/LDO girişine yakın).

---

### 5. RF Matching Network

#### Pi-Network (DNP — kalibrasyon için):

```
EC25 RF out ──┬── [C1 DNP] ──┬── [L1 DNP] ──┬── [C2 DNP] ──┬── SMA Konnektör
               │               │               │               │
              GND             GND             GND             GND
```

- Başlangıçta 0Ω direnci konur (bypass) veya boş bırakılır
- Saha testinde VSWR yüksekse VNA ile ölçülüp doğru değerler yerleştirilir
- 0402 paket — PCB'de sadece pad alanı, maliyet $0

### 5b. Anten Diversity ve GNSS

**3 Anten Portu (EC25-E):**

| Port | Anten | Tip | Görev |
|------|-------|-----|-------|
| MAIN | Yagi 12 dBi (harici SMA) | Yönlü, yüksek kazanç | Birincil TX/RX |
| DIV | PCB dipole 3 dBi (dahili) | Omnidirectional | Multipath fading koruması |
| GNSS | Seramik patch 25x25mm | Pasif | GPS/GLONASS konum |

**Diversity Avantajı:**
- Tek anten: multipath ortamda (dağ, şehir) sinyal fading → veri kaybı
- Diversity: modem iki antenden gelen sinyali birleştirir (MRC) → 3-6 dB kazancın üstüne ek kararlılık

> [!WARNING]
> **GNSS Güvenlik Tradeoff'u:** GPS cihazın konumunu ifşa eder. Firmware'de varsayılan olarak devre dışı. Operatör isterse `AT+QGPS=1` ile açılır. Konum verisi ayrıca AES ile şifrelenerek gönderilir.

---

### 6. RED/BLACK PCB Moat (TEMPEST Uyumlu Fiziksel Ayrım)

> [!CAUTION]
> Tuş takımı ve ekran RED (açık metin) bölgesindedir. Modem BLACK (şifreli) bölgesindedir. Parasitik kapasitans/endüktans ile RED verisi BLACK hatlara sızabilir.

#### PCB RED/BLACK Ayrımı:

```
┌───────────────────────────────────────────────────┐
│    RED ZONE              ║ MOAT ║    BLACK ZONE       │
│                          ║      ║                     │
│  FPGA (RED UART tarafı) ║ GND  ║  EC25 Modem        │
│  Keypad (4x4)           ║ cut  ║  SMA Anten         │
│  OLED Ekran             ║      ║  LNA               │
│  Batarya                ║      ║  SIM Slot + ESD    │
│                          ║      ║                     │
│        ┌──────────┐      ║      ║                     │
│        │ STM32    │─────║─UART─║────────────────│
│        │ MCU      │      ║ ONLY ║ (TXB0104)         │
│        └──────────┘      ║      ║                     │
└──────────────────────────║──────║─────────────────────┘
```

**Kurallar:**
- Moat: RED ve BLACK arasında en az 5mm bakır boşluk, dört katmanda da
- MCU moat'ın üzerinde oturur — tek kontrollü geçiş noktası
- RED bölgesinden BLACK bölgesine sadece MCU UART geçer (zaten şifreli)
- Keypad/OLED trace'leri BLACK bölgeye asla girmez
- Moat bölgesinde sinyal yolu yok, sadece GND via stitching

---

### 7. Harici Watchdog (TPL5010) + Güvenli Boot

#### TPL5010 Harici Watchdog:

```
TPL5010 (35nA)
   │
   ├── WAKE → STM32 PC7 (interrupt: "alive mısın?")
   │
   ├── DONE ← STM32 PC8 ("evet, çalışıyorum")
   │
   └── RSTn → MCU NRST + Modem PWRKEY (cevap gelmezse hard reset)
```

- MCU kilitlenirse TPL5010 tüm sistemi fiziksel olarak resetler
- 35nA güç tüketimi — bataryayı etkilemez
- Timeout: ayarlanabilir (1s - 2 saat)

#### SBSFU (Secure Boot & Firmware Update):

```
Boot Sırası:
  1. STM32 açılır
  2. SBSFU bootloader: firmware imzasını kontrol et
     → ECDSA-P256 + SHA-256 doğrulama
  3. İmza geçerli → firmware'i çalıştır
  4. İmza geçersiz → kill_signal + DEAD_LOOP

Firmware Güncelleme:
  - BLACK UART üzerinden şifreli paket gelir
  - MCU AES ile çözer → imza doğrular → flash'a yazar
  - RDP Level 1 (geliştirme) / Level 2 (üretim)
```

> [!IMPORTANT]
> Geliştirme sırasında RDP Level 1 (debug korumalı ama güncellenebilir). Son üretim birimlerinde RDP Level 2 (geri dönüşümsüz kilitleme).

#### Golden Image — Dual-Bank Firmware Recovery:

> [!WARNING]
> Şifreli firmware güncelleme sırasında enerji kesilirse veya 4G bağlantısı koparsa cihaz brick olabilir. Dual-bank flash ile bu risk ortadan kalkar.

```
STM32L476 Dual-Bank Flash (512KB × 2):

  Bank 1: Mevcut çalışan firmware (Golden Image)
  Bank 2: Yeni gelen firmware (candidate)

  Güncelleme Protokolü:
  1. MCU → FPGA SPI: CMD_FW_UPDATE (0xFU)
     → FPGA watchdog timeout'u geçici olarak 1.5s → 30s'ye uzatır
  2. Yeni firmware önce W25Q16 SPI Flash'a indirilir (staging)
  3. SHA-256 ile tamlık doğrulaması (SPI Flash üzerinde)
  4. Sadece %100 sağlamsa → Bank 2'ye kopyalanır
  5. ECDSA imza doğrulanır
  6. Başarılı → BFB2 option byte ile bank swap → soft reset
  7. Başarısız → Bank 1'de kalır → normal boot

  ★ Bank 1 ASLA güncelleme tamamlanmadan silinmez.
  ★ FPGA tarafında watchdog_monitor.vhd'ye extended_timeout modu gerekir.
  ★ SPI Flash staging: yarım kalan indirme internal flash'ı HIÇ etkilemez.
  ★ SPI Flash'taki firmware şifreli saklanır — fiziksel okumaya karşı koruma.
```

---

### 8. Güç Yönetimi

> [!CAUTION]
> **TASARIM DÜZELTME:** TLV1117 LDO Li-Po ile çalışmaz (dropout 1.1V — pil 3.7V'da çıkış 2.6V'a düşer). AP2112K-3.3 ile değiştirildi (dropout 250mV — pil 3.55V'a kadar stabil 3.3V verir).

```
Li-Po 3.7V 5000mAh
    │
    ├──► TP4056 Şarj IC (USB-C girişli)
    │
    ├──► MIC29302 LDO → 4.0V @ 3A → EC25 Modem
    │        ENABLE ← STM32 GPIO PC9    ★ POWER SEQUENCING
    │        (pik 2A TX burst'ü kaldırır)
    │        + 1000µF + 10×100nF cap bank
    │
    ├──► AP2112K-3.3 ULDO → 3.3V → STM32 + OLED + Tuşlar + TXB0104
    │        (dropout 250mV: pil 3.55V'da bile 3.3V sağlar)
    │
    ├──► MT3608 Boost → 5.0V → Arty A7 (Faz 1: breadboard prototip)
    │        (Üretim PCB'de kullanılmaz — bare FPGA: 1.0V/1.8V/3.3V ayrı LDO)
    │
    └──► Üretim: TPS62080 Buck → 1.0V (VCCINT) + 1.8V (VCCAUX) + 3.3V (VCCO)
```

> [!CAUTION]
> **Power Sequencing — Back-Powering Riski:** MCU kapalıyken modem açık kalırsa, EC25'in 1.8V UART pinlerinden TXB0104 level shifter üzerinden MCU bacaklarına akım sızar → latch-up → kalıcı hasar.

#### Zorunlu Boot Sıralaması:

```
T+0ms   : 3.3V rail ON (FPGA + MCU)
T+50ms  : FPGA PLL locks → system_ready
T+100ms : MCU boot complete, SPI handshake ile FPGA kontrol
T+150ms : MCU → PC9 HIGH → MIC29302 ENABLE → 4.0V ON → Modem açılır
T+2000ms: AT+CFUN=1 → hücresel kayıt
```

#### Firmware (power.c) — modem güç kontrolü:

```c
void modem_power_on(void) {
    assert(fpga_handshake_ok);  // Önkoşul: FPGA hazır
    HAL_GPIO_WritePin(GPIOC, GPIO_PIN_9, GPIO_PIN_SET);   // LDO ENABLE
    HAL_Delay(100);  // LDO stabilizasyon
    HAL_GPIO_WritePin(GPIOC, GPIO_PIN_0, GPIO_PIN_SET);   // PWRKEY pulse
    HAL_Delay(500);
    HAL_GPIO_WritePin(GPIOC, GPIO_PIN_0, GPIO_PIN_RESET);
}
```

#### Li-Po Termal Yönetim (NTC):

```
Li-Po Batarya NTC pin → 10KΩ voltage divider → STM32 ADC (PA5)

Firmware (thermal.c) — 500ms döngü:

  Sıcaklık < 0°C  → Şarjı tamamen kes (Li-Po donma riski)
  Sıcaklık 0-45°C  → Normal çalışma
  Sıcaklık > 45°C → Şarjı kes + modem low-power mode (AT+CFUN=0)
  Sıcaklık > 55°C → Acil: modem kapat + OLED uyarı + FPGA'ya bildir
  Sıcaklık > 65°C → Sistem shutdown (yangın riski)
```

#### Last Gasp — Supercapacitor Kill Güvencesi:

> [!CAUTION]
> Saldırgan pili keser veya pil aniden biterse, FPGA async zeroize (<20ns) çalışır ama MCU graceful shutdown için ~50ms gerekir. Supercapacitor bu enerjiyi sağlar.

```
Li-Po ──┬── [MIC29302] ── Modem (supercap BAĞLI DEĞİL)
        │
        ├── [Schottky] ── [0.1F Supercap] ──┬── [AP2112K] ── MCU 3.3V
        │        (Şarj: 0.5Ω seri R)          └── FPGA 3.3V
        │
        (Schottky: pil kesilince supercap'ten pile ters akımı önler)

Hesap: 0.47F × (3.3V - 2.8V) = 235mC
       MCU 30mA + FPGA 300mA = 330mA toplam
       330mA × 50ms = 16.5mC << 235mC → 14× güvenlik marjı

★ V15 Düzeltme: 0.1F → 0.47F yükseltildi
  - 0.1F sadece MCU 30mA için yeterliydi (30× marj)
  - FPGA ~300mA çektiğinde 0.1F ile marj 3×'a düşer — yetersiz
  - 0.47F ile FPGA + MCU birlikte ~700ms graceful shutdown süresi = güvenli
```

#### Brownout Koruması — İki Katmanlı PVD + BOR:

```
4.2V ───── Normal çalışma
3.3V ───── AP2112K çıkışı stabil
3.0V ───── PVD interrupt → graceful shutdown (YAZILIM)         ← Katman 1
2.8V ───── BOR Level 4 reset → hard reset (DONANIMSAL)        ← Katman 2
2.5V ───── Supercap tükenmiş, FPGA async zeroize
```

#### Firmware (power.c) — PVD graceful shutdown:

```c
void PVD_IRQHandler(void) {
    // Pil 3.0V altına düştü → supercap enerjisi ile çalışıyoruz
    modem_power_off();                    // Modem kapat (enerji tasarrufu)
    log_event(EVT_LOW_BATTERY_SHUTDOWN);  // Kara kutuya yaz
    HAL_GPIO_WritePin(KILL_PORT, KILL_PIN, GPIO_PIN_SET);  // FPGA kill
    HAL_PWR_EnterSTANDBYMode();           // MCU derin uyku
}
```

---

### 9. Fiziksel Güvenlik (Anti-Tamper)

#### Kasa Yapısı:

```
┌──────────────────────────────────────┐
│  ┌─ KAPAK ──────────────────────┐    │
│  │   [Reed Switch] ←→ [Magnet] │    │
│  └──────────────────────────────┘    │
│                                      │
│  PCB + Bileşenler                    │
│                                      │
│  [Limit Switch] ←── kapak menteşesi  │
└──────────────────────────────────────┘
```

**Çalışma Prensibi (İki Aşamalı Tamper):**

1. **Dış kapak açılırsa** (Reed Switch PC5 / Limit Switch PC6):
   → FPGA kill_signal → tüm key'ler zeroize
   → MCU flash silinmez — recovery mümkün

2. **İç kapak açılırsa** (PCB'ye fiziksel erişim):
   → RDP Level 2 → MCU flash geri dönüşümsüz kilitlenir

İki bağımsız sensör: Biri bypass edilse diğeri tetikler (defense in depth)

#### Recovery Button (PC10):

```
Boot sırasında PC10 kontrol edilir:
  PC10 = LOW (basılı) + 3 saniye bekle → Bank 1 (Golden Image) boot
  PC10 = HIGH (normal) → SBSFU imza kontrolü → normal boot

Buton tamper bölgesi içinde — sadece kapak açık erişilebilir
Kapak açılınca key'ler zaten silinir → güvenlik açığı yok
Amaç: firmware brick kurtarma, yeni key injection sonrası tekrar çalışır
```

#### Firmware (tamper.c):

```c
void EXTI9_5_IRQHandler(void) {
    // Dış kapak: FPGA kill (key zeroize), MCU flash'a dokunma
    HAL_GPIO_WritePin(KILL_PORT, KILL_PIN, GPIO_PIN_SET);
    // NOT: RDP Level 2 sadece iç kapak (ayrı interrupt) ile tetiklenir
}

void EXTI15_10_IRQHandler(void) {
    // İç kapak: tam imha
    HAL_GPIO_WritePin(KILL_PORT, KILL_PIN, GPIO_PIN_SET);
    FLASH_OB_RDPConfig(OB_RDP_LEVEL_2);  // Geri dönüşümsüz
    while(1);
}
```

---

### 10. JTAG/SWD Debug Port Depopulation

```
Geliştirme PCB:
  FPGA JTAG: TCK ─[0Ω]─ Header    ← takılı, debug açık
  MCU  SWD:  SWDIO─[0Ω]─ Header    ← takılı, debug açık

Üretim PCB:
  FPGA JTAG: TCK ─[BOŞ]─ Header    ← söküldü, fiziksel kesim
  MCU  SWD:  SWDIO─[BOŞ]─ Header    ← söküldü, fiziksel kesim
```

6 adet 0Ω jumper:
- FPGA: TCK, TMS, TDI, TDO (4 adet)
- MCU: SWDIO, SWCLK (2 adet)
- Üretimde sökülür → işlemci bacaklarına fiziksel erişim kesilir
- Glitch attack yolu ortadan kalkar

#### Pil Ömrü Hesabı (V15 — Gerçekçi, FPGA Dahil):

| Mod | FPGA | MCU | Modem | Diğer | Toplam | Süre (5000mAh) |
|-----|------|-----|-------|--------|--------|----------------|
| Standby (bağlı, veri yok) | ~250mA | ~10mA | ~30mA | ~10mA | **~300mA** | **~16 saat** |
| Aktif iletişim | ~300mA | ~30mA | ~250mA | ~20mA | **~600mA** | **~8 saat** |
| TX burst (pik) | ~300mA | ~30mA | ~2A | ~20mA | ~2.4A | kısa süreli |
| MCU Sleep + Modem PSM | ~250mA | ~2µA | ~8µA | ~10mA | **~260mA** | **~19 saat** |

> [!WARNING]
> **V15 Düzeltme:** Orijinal pil ömrü hesabı FPGA tüketimini içermiyordu (MCU 50mA + Modem 250mA = 300mA → 16 saat). Gerçekte Artix-7 FPGA ~250-300mA çeker — bu hesabı yarıya düşürür. Üretim PCB'de bare FPGA + verimli buck converter ile FPGA tüketimi ~150mA'ya düşürülebilir.

### 11b. Anten Hattı ESD Koruması

Yagi anten dış ortamda — statik yük birikimi, yıldırım indüksiyonu riski.

```
Anten → SMA → [TVS1: PESD5V0U1UA] → Pi-Network → [TVS2: PESD3V3U1UA] → LNA → EC25
                  (<0.5pF)                           (<0.2pF)
```

- TVS1 (SMA): Kaba ESD sönümleme (5V clamp)
- TVS2 (LNA giriş): İnce koruma (3.3V clamp, düşük kapasitans)
- Her iki TVS'in GND'si en kısa via ile toprak düzlemine bağlanmalı

### 11c. Gizli Diyagnostik Portu (Hidden Test Pads)

JTAG/SWD söküldükten sonra saha debug yeteneği:

```
PCB Test Point Haritası (kasa içi, konnektörsüz):
  TP1: UART4_TX (PD1) → MCU debug log çıkışı
  TP2: GND
  TP3: 3.3V (güç kontrolü)
  TP4: MCU NRST (acil reset)
  TP5: FPGA UART_TX_PAD (mevcut telemetri)
```

#### Firmware (debug_log.c):

```c
// Recovery button 3sn basılı → DEBUG_MODE = 1
// Log: son 100 event ring buffer (flash'ta saklı)
// Event: modem_disconnect, sim_error, thermal_shutdown,
//        kill_trigger, pvt_alarm, watchdog_timeout
// GÜVENLİK: Kripto verisi, key, plaintext ASLA loglanmaz.
```

---

### 11. P2P Protokol Simetrisi (COBS Framing Layer)

> [!CAUTION]
> **The Hidden Rust Dependency:** TCP bir akış (stream) protokolüdür — paket sınırlarını kendisi belirlemez. AES ciphertext içindeki rastgele byte dizilimleri FPGA frame SOF'unu (0xAA55AA55) taklit edebilir → False SOF Detection.

**COBS (Consistent Overhead Byte Stuffing):**
- Veri içinde asla 0x00 geçmeyeceğini garanti eder
- 0x00 byte paket sınırı olarak kullanılır → kurşun geçirmez framing
- Overhead: ~%1 (254 byte'da 1 byte ek)

#### Callwhite P2P Protocol v1.0:

```
TCP Stream üzerinde:
  [0x00] [COBS-encoded FPGA frame] [0x00] [COBS-encoded FPGA frame] ...

Her COBS payload'ı içinde:
  [SOF] [SEQ] [NBLK] [CT: N×16B] [MAC]
```

#### Simetri Gereksinimi:

```
TITAN-A (gönderen):                    TITAN-B (alan):
  FPGA → comm_protocol → frame           TCP → cobs_decode → frame
  frame → MCU cobs_encode → TCP           frame → FPGA → comm_protocol
  TCP → Internet → TITAN-B              → AES decrypt → plaintext
```

#### Rust Tarafı (hidra_net) — Zorunlu Değişiklik:

```rust
// hidra_net/src/cobs.rs — YENI MODÜL
pub fn cobs_encode(input: &[u8]) -> Vec<u8>;
pub fn cobs_decode(input: &[u8]) -> Result<Vec<u8>, CobsError>;

// hidra_net/src/transport.rs — Feature Flag Handshake
pub const FLAG_COBS_ENABLED: u8 = 0x01;
// İlk bağlantıda karşı tarafa feature flag gönderilir
// Legacy TITAN (COBS'suz) → raw frame modu (geriye uyumluluk)
// Callwhite TITAN → COBS modu
```

> [!IMPORTANT]
> Her iki uçtaki MCU/Rust yazılımı bu COBS layer ile güncellenmelidir. Tek taraflı güncelleme → karşı taraf "garbled data" görür → session kurulamaz.

---

## Geliştirme Fazları

### Faz 1: Breadboard Prototip (1-2 hafta)
- [ ] STM32 Nucleo-L476RG geliştirme kartı al
- [ ] Quectel EC25 Mini PCIe + breakout board al
- [ ] SIM kart tak, AT komutlarını test et
- [ ] STM32 UART ↔ Modem UART çalıştır
- [ ] TCP transparent mode doğrula
- [ ] FPGA Arty A7 BLACK UART → STM32 UART bağla
- [ ] Uçtan uca test: FPGA → MCU → Modem → Internet → Karşı taraf

### Faz 2: PCB Tasarımı (2-3 hafta)
- [ ] KiCad şematik: FPGA + MCU + Modem + Güç
- [ ] 4 katman PCB layout (RF bölge ayrımı önemli)
- [ ] SMA anten konnektörü yerleşimi
- [ ] Güç düzlemi tasarımı (modem pik akım için geniş trace)
- [ ] PCB üretimi (JLCPCB, 5-7 gün)

### Faz 3: Entegrasyon (1-2 hafta)
- [ ] SMD montaj
- [ ] Firmware geliştirme (AT engine, TCP session, display)
- [ ] OLED + tuş takımı entegrasyonu
- [ ] Anten + LNA kurulumu
- [ ] Saha testi (şehir + kırsal sinyal karşılaştırma)

### Faz 4: Kasa + Ürünleştirme (2-4 hafta)
- [ ] 3D baskı kasa (IP54 koruma)
- [ ] Batarya entegrasyonu
- [ ] USB-C şarj
- [ ] SMA anten montaj noktası
- [ ] Final test + doğrulama

---

## Kritik Tasarım Kararları

### FPGA'da Değişiklik Gerekiyor mu?

**EVET** — minimal ama zorunlu. CTS/RTS akış kontrolü (2 pin + gearbox doluluk mantığı), SPI FW_UPDATE komutu ve watchdog extended timeout eklenmeli. Mevcut `BLACK_UART_TX/RX_PIN` pinleri değişmez — FPGA kabloya mı yoksa modem'e mi bağlı olduğunu hâlâ bilmez.

### Neden Modem Direkt FPGA'ya Bağlanmıyor?

- Modem AT komutları ile kontrol edilir — FPGA'da AT parser yazmak gereksiz karmaşıklık
- TCP/IP stack FPGA'da implement etmek binlerce LUT harcar
- MCU zaten $8 — eklenen karmaşıklık minimum
- MCU ayrıca ekran, tuş takımı, batarya yönetimi gibi ek görevleri üstlenir

### Güvenlik

- MCU sadece şifreli veri görür — açık metin FPGA'dan hiç çıkmaz
- MCU firmware'i tamper protection ile korunur (STM32 RDP Level 2)
- Modem → MCU → FPGA yönünde gelen veri FPGA'da AES ile çözülür
- MCU kompromize olsa bile: sadece şifreli byte'lar sızar, anahtar FPGA'da

---

## Tahmini Toplam Maliyet ve Süre

| Kalem | Maliyet |
|-------|---------|
| Bileşenler (BOM) | ~$298 |
| PCB üretimi | ~$15-30 |
| 3D baskı kasa | ~$20 |
| **Toplam** | **~$333-345** |

| Kalem | Süre |
|-------|------|
| Breadboard prototip | 1-2 hafta |
| PCB tasarım + üretim | 3-4 hafta |
| Firmware + entegrasyon | 2-3 hafta |
| Test + ürünleştirme | 1-2 hafta |
| **Toplam** | **~7-11 hafta** |

---

## V15 Yeni Bölümler

### 12. SIM Yöneticisi (sim_manager.c)

#### SIM Card Detect Akışı:

```
Boot sırasında:
  1. PC11 (Card Detect) kontrol et
     - CD = LOW  → SIM takılı → devam et
     - CD = HIGH → SIM yok → OLED: "⚠️ SIM TAKILMADI"
                             → Modem başlatma (AT+CFUN=0, minimum mod)
                             → 30 saniyede bir CD tekrar kontrol

  2. SIM varlığı onaylanınca:
     → AT+CPIN? sorgu
     → READY: devam
     → SIM PIN: tuş takımından PIN iste (OLED: "SIM PIN GIR: ____")
       - 3 yanlış → PUK → OLED: "SIM KİLİTLİ"
       - PIN doğru → NVRAM'a şifreli sakla (opsiyonel, AT+CLCK ile)
     → SIM PUK: OLED: "SIM KALİCİ KİLİT — SERVİSE BAŞVUR"

  3. SIM voltaj uyumluluğu:
     → AT+QSIMVOL? → 1.8V veya 3.0V otomatik algılama
     → Uyumsuzluk varsa AT+QSIMVOL=<doğru değer> ile düzelt
```

#### Çalışma Sırasında SIM Hot-Swap:

```c
void EXTI15_10_IRQHandler(void) {  // PC11 EXTI
    if (sim_card_detect_pin == HIGH) {
        // SIM çıkarıldı!
        modem_enter_safe_mode();  // AT+CFUN=0
        display_warning("SIM CIKARILDI");
        log_event(EVT_SIM_REMOVED);
    }
}
```

---

### 13. Band / Ağ Yapılandırması (band_config.c)

#### 2G Fallback Stratejisi:

```
Güvenlik Modu Seçenekleri (config.h veya tuş takımı menüsü):

  MODE_LTE_ONLY:
    AT+QCFG="nwscanmode",3     -- Sadece LTE
    ★ Avantaj: 2G/3G intercept riski sıfır
    ★ Dezavantaj: LTE kapsama dışında bağlantı yok
    ★ Önerilen: yüksek güvenlik gerektiren operasyonlarda

  MODE_LTE_3G:
    AT+QCFG="nwscanmode",5     -- LTE + WCDMA (2G yok)
    ★ Orta güvenlik, iyi kapsama
    ★ Önerilen: varsayılan mod

  MODE_AUTO:
    AT+QCFG="nwscanmode",0     -- Otomatik (LTE/3G/2G)
    ★ En geniş kapsama ama 2G güvensiz
    ★ Not: TITAN E2E şifreli olduğundan veri güvende
           ama metadata (IMSI, lokasyon) 2G'de korunmasız

★ TITAN zaten uçtan uca AES-256 şifreli — 2G'de bile veri içeriği güvende.
  Ancak 2G SS7 saldırılarına açık: IMSI yakalama, konum takibi mümkün.
```

#### Band Kilidi:

```c
// band_config.c — operasyonel bölge bazlı band yapılandırması

typedef struct {
    const char* name;
    const char* bands;  // AT+QCFG="band" hex mask
} BandProfile;

// Önceden tanımlı profiller
static const BandProfile profiles[] = {
    {"TR",     "0,800D5,0"},   // B1+B3+B7+B8+B20 (Türkiye)
    {"EU",     "0,800D5,0"},   // Aynı bantlar (Avrupa)
    {"GLOBAL", "0,FFFF,0"},    // Tüm bantlar açık
    {"STEALTH","0,4,0"},       // Sadece B3 (minimum RF footprint)
};

// Tuş takımı menüsünden seçilebilir
// AT+QCFG="band",0,<mask>,0 ile uygulanır
```

#### Operatör Seçimi:

```
  Manuel operatör kilidi (askeri kullanım):
    AT+COPS=1,2,"28601"    -- Turkcell'e kilitle
    AT+COPS=1,2,"28602"    -- Vodafone'a kilitle

  Otomatik (varsayılan):
    AT+COPS=0              -- En güçlü operatör

  Roaming (sınır ötesi):
    AT+QCFG="roamservice",2  -- Roaming aktif
    APN yapılandırması güncellenmelidir
```

---

### 14. Modem Termal Yönetimi (modem_thermal.c)

```
EC25 Sıcaklık İzleme:

  Kaynak: AT+QTEMP (3 sensör: PMIC, XO, PA)
  + Harici NTC (MCU ADC PA6 — PCB'deki EC25 altında)

  Sörgu periyodu: 10 saniye

  Eşik Değerleri:
    < 60°C  → Normal çalışma
    60-70°C → Throughput throttle: TX burst aralığını artır
              OLED: "MODEM: SICAK" (bilgilendirme)
    70-80°C → AT+CFUN=0 → RF kapat, soğumayı bekle
              OLED: "⚠️ MODEM TERMAL KORUMA"
    > 80°C  → MIC29302 ENABLE LOW → modem gücü kes
              OLED: "🛑 MODEM KAPATILDI"
              log_event(EVT_MODEM_THERMAL_SHUTDOWN)

  Soğuma sonrası oto-restart:
    - 55°C altına düşünce modem yeniden başlatılır
    - Hysteresis: 80°C kapat → 55°C aç (25°C fark)
    - 3 ardışık termal shutdown → modem devre dışı + servis uyarısı

  PCB Tasarım:
    - EC25 altında termal pad (exposed pad → inner layer GND)
    - Termal via array (5×5 grid, 0.3mm)
    - NTC 0402 termal pad'in hemen yanına
```

---

### 15. Jamming Algılama (jamming_detect.c)

```
RF Bozucu Tespit Algoritması:

  Giriş: AT+CSQ periyodik sorgu (5 saniye aralık)
  İzlenen metrikler:
    - RSSI (sinyal gücü)
    - RSRP/RSRQ (LTE kalite metrikleri)
    - AT+CREG? (ağ kayıt durumu)

  Anomali Tespiti:
    1. RSSI ani düşüşü:
       - RSSI(t) - RSSI(t-1) > 20 dB → şüpheli
       - 3 ardışık >15 dB düşüş → olası jamming

    2. Kayıt kaybı pattern:
       - CREG 0,1 → 0,0 (kayıt dışı) tekrar tekrar
       - 60 saniyede 3+ kayıt kaybı → olası jamming

    3. RSSI doyumu:
       - RSSI = 0 (veya 99) + CREG = 0 → broadband jamming

  Tepki:
    - Seviye 1: OLED: "⚠️ RF BOZUCU OLASI" (bilgilendirme)
    - Seviye 2: log_event(EVT_JAMMING_DETECTED)
    - Seviye 3 (3+ dakika): FPGA'ya bildir (SPI komutu)
                            OLED: "🛑 İLETİŞİM GÜVENLİ DEĞİL"
    - Seviye 4 (operatörü tercihi): W_DISABLE# → RF tamamen kapat

  ★ Jamming tespiti kesin sonuç veremez — dağ/tünel de sinyal keser.
    Amaç: bilgi vermek, kararı operatöre bırakmak.
```

---

### 16. GNSS Kararı (V15)

> [!CAUTION]
> **Güvenlik Tradeoff:** GNSS konum bilgisi doğası gereği cihazın fiziksel konumunu ifşa eder. Askeri terminalde bu kritik bir OPSEC riskidir.

```
Varsayılan: GNSS devre dışı (antenna DNP, firmware kapalı)

Eğer operatör GNSS isterse:
  1. GNSS anten takılır (seramik patch)
  2. Firmware: AT+QGPS=1
  3. Konum verisi MCU'da AES ile şifrelenir
  4. Şifrelenmemiş konum ASLA UART'a veya OLED'e yazılmaz
  5. Konum log'u MCU flash'ta değil, sadece RAM'de (kill ile silinir)

Kullanım senaryosu:
  - Acil durum: konum bilgisi komuta merkezine iletilir
  - Normal: GNSS tamamen kapalı, RF iz yok
```

---

### 17. Modem USB Debug Portu (V15)

```
Micro-USB Footprint (PCB'de, konnektör DNP):

  Görev:
    - EC25 firmware güncellemesi (QFlash Tool)
    - AT komut debug (minicom/PuTTY)
    - Modem log toplama (AT+QCFG="usbcfg")

  Güvenlik:
    - Konnektör varsayılan olarak TAKILMAZ (DNP)
    - Sadece fabrika/servis ortamında geçici olarak lehimlenir
    - Saha birimlerinde test pad olarak bırakılır (pogo-pin)
    - USB veri hatlarına 0Ω jumper (üretimde sökülür)
```

