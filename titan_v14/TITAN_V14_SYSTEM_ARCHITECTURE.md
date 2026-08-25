# TITAN V14 — Tam Sistem Mimarisi

## Egemen Güvenli İletişim Terminali | Artix-7 + PolarFire Dual-FPGA

**Versiyon**: V14 (AEGIS Entegre)  
**Tarih**: Şubat 2026  
**Sınıflandırma**: Mühendislik Referans Dökümanı

---

## İçindekiler

1. [Sistem Genel Bakışı](#1-sistem-genel-bakışı)
2. [Katman 1: Hesaplama ve Mantık Çekirdeği](#2-katman-1-hesaplama-ve-mantık-çekirdeği)
3. [Katman 2: FPGA İçi Güvenlik — AEGIS](#3-katman-2-fpga-i̇çi-güvenlik--aegis)
4. [Katman 3: Güvenlik Bekçileri — Analog Watchdog](#4-katman-3-güvenlik-bekçileri--analog-watchdog)
5. [Katman 4: Fiziksel İmha ve Koruma](#5-katman-4-fiziksel-i̇mha-ve-koruma)
6. [Katman 5: Yazılım Yığını](#6-katman-5-yazılım-yığını)
7. [Katman 6: Üretim ve Fabrika Güvenliği](#7-katman-6-üretim-ve-fabrika-güvenliği)
8. [Birleşik Kill Zinciri](#8-birleşik-kill-zinciri)
9. [Kaynak Kullanımı ve Performans](#9-kaynak-kullanımı-ve-performans)
10. [Saldırı Vektörü Kapsamı](#10-saldırı-vektörü-kapsamı)

---

## 1. Sistem Genel Bakışı

TITAN V14, devlet seviyesindeki siber ve fiziksel tehditlere karşı tasarlanmış, çok katmanlı bir güvenli iletişim terminalidir. Tasarım felsefesi:

> **Yazılıma güvenilmez. Donanıma güvenilir. Tek bir donanıma da güvenilmez.**

### Savunma Derinliği (Defense-in-Depth) Modeli

```
┌──────────────────────────────────────────────────────────────────┐
│                    TITAN V14 — 6 KATMANLI GÜVENLİK              │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ KATMAN 6: Üretim Güvenliği                                │  │
│  │ Factory Bait + eFUSE + Bypass Yolu                        │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ KATMAN 5: Yazılım                                         │  │
│  │ Buildroot Linux + Rust Core + POST                        │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ KATMAN 4: Fiziksel İmha                                   │  │
│  │ GaN Susturma + HV İmha + Epoksi + Mu-Metal + LFI Mesh   │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ KATMAN 3: Analog Bekçiler                                 │  │
│  │ Freq Police + Phase Kill + Crowbar + LFI Photodiode       │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ KATMAN 2: FPGA İçi Güvenlik — AEGIS  ★ V14 YENİ ★        │  │
│  │ Omega Cloak + PVT Monitor + AI Anomaly + Kill Chain x4    │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ KATMAN 1: Hesaplama Çekirdeği                             │  │
│  │ Dual-FPGA Lockstep + Logic Wall + Clock Distribution      │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

**V13 → V14 Farkı**: V13'te Katman 2 (FPGA içi güvenlik) neredeyse boştu. AES çalıştırılıyor, anahtar flip-flop'larda tutuluyordu ama **yan kanal koruması yoktu**. V14/AEGIS bu katmanı 4 bağımsız koruma mekanizmasıyla doldurdu.

---

## 2. Katman 1: Hesaplama ve Mantık Çekirdeği

### 2.1 Dual-FPGA Lockstep Mimarisi

**Prensip**: Tek bir tedarikçiye güvenilmez. Kriptografik işlem iki farklı çipte, iki farklı fabrikadan, aynı anda yürütülür.

| Rol | Çip | Fabrika | Teknoloji | Görev |
|-----|-----|---------|-----------|-------|
| **Primary** | Xilinx Artix-7 XC7A100T | TSMC | SRAM tabanlı | Performans yükü, AES-256, AEGIS |
| **Auditor** | Microchip PolarFire MPF100T | UMC | Flash tabanlı | Denetim, SEU bağışıklığı, watchdog |

**Neden iki farklı fabrika?**  
Aynı donanım trojanının hem TSMC hem UMC üretim hattına aynı anda eklenmesi **pratik olarak imkansız**. Bu, tedarik zinciri saldırılarını etkisiz kılan mimari bir karardır.

### 2.2 Logic Wall — Ayrık Mantık Karşılaştırma Motoru

İki FPGA'dan çıkan şifreli veri, bir yazılım veya FPGA tarafından değil, **ayrık mantık (discrete logic)** tarafından karşılaştırılır.

| Bileşen | Parça | Adet | Görev |
|---------|-------|------|-------|
| Karşılaştırıcı | 74HC688 (8-Bit Magnitude) | 33 | 264 bit eşzamanlı karşılaştırma |
| Oylama | 74HC11 (Triple AND Gate) | 11 | Tüm karşılaştırıcı çıkışlarını toplar |
| Çeşitlilik | TI + NXP + Toshiba markaları | Karışık | Tek parti hatasını önler (interleaved) |

**Aksiyon**: Veriler arasında **1 bit bile fark** olsa → karşılaştırıcılar KILL hattını fiziksel olarak tetikler (Low Signal).

**Neden FPGA içinde değil?**  
Eğer karşılaştırma FPGA içinde yapılsaydı, FPGA trojanı hem şifreleyiciyi hem karşılaştırıcıyı manipüle edebilirdi. Ayrık mantık, FPGA trojandan bağımsızdır.

**Zamanlama Bütçesi Notu**:  
74HC688 propagation delay: tipik 15-25ns, worst-case 40ns. 33 karşılaştırıcının çıkışları paralel olarak toplanır (kaskat değil). Ancak karşılaştırma her clock cycle'da değil, **AES blok çıkışı başına bir kez** yapılır (~20-40 cycle = 400-800ns pencere). Bu pencere 74HC688 settling time'ı için fazlasıyla yeterlidir. PCB şematiklerinde FPGA'dan `compare_valid` strobe sinyali çıkarılarak, karşılaştırma sonucunun D-FF ile örneklenmesi önerilir.

### 2.3 Boot Senkronizasyonu (Blind Boot Protection)

**Problem**: Artix-7 (SRAM tabanlı) yapılandırma yüklemesi ~50ms sürer. PolarFire (Flash tabanlı) ise <1ms'de hazırdır. Bu 50ms penceresi boyunca Logic Wall, bir taraftan veri gelirken diğer taraftan sessizlik görür ve yanlış alarm üretebilir.

**Çözüm**: DONE pin AND gate ile boot maskeleme.

```
ARTIX7_DONE_PIN ──┐
                  AND ──→ LOGIC_WALL_ENABLE (PCB üzerinde, 1x 74HC08)
POLARFIRE_DONE ───┘

Her iki FPGA DONE=1 olmadan Logic Wall karşılaştırması başlamaz.
Bu tek AND gate, boot sırasındaki yanlış kill tetiklemesini önler.
```

| Parametre | Değer |
|-----------|-------|
| Artix-7 config süresi | ~50ms (SPI Flash'tan) |
| PolarFire config süresi | <1ms (dahili Flash) |
| Maskeleme süresi | Max 50ms (DONE pin'e kadar) |
| Ek bileşen | 1x 74HC08 (Quad AND Gate), sadece 1 gate kullanılır |
| Güvenlik etkisi | Boot sırasında system kill-proof, boot sonrası tam koruma |

### 2.4 Clock Dağıtımı — Tek Kaynak Prensibi

| Bileşen | Parça | Görev |
|---------|-------|-------|
| **Osilatör** | SiTime SiT5356 (MEMS, 100 MHz) | Kristal yerine MEMS: daha düşük jitter, daha yüksek şok dayanımı |
| **Prescaler** | 74VHC74 (D-Type Flip-Flop) | 100 MHz → 50 MHz bölme + sinyal temizleme |
| **Dağıtım** | Length-Matched Traces | Her iki FPGA'ya eşit yol uzunluğu (< 50ps skew) |

**Neden önemli?** Lockstep karşılaştırması, iki FPGA'nın **aynı clock edge'inde** sonuç üretmesini gerektirir. Clock skew > 1ns ise karşılaştırma anlamsızlaşır.

---

## 3. Katman 2: FPGA İçi Güvenlik — AEGIS ★ V14 YENİ ★

Bu katman V14'ün en büyük yeniliğidir. V13'te FPGA sadece AES çalıştırıyor ve anahtarı saklıyordu. V14'te FPGA'nın **içine** 4 katmanlı bir güvenlik çerçevesi entegre edilmiştir.

### 3.1 Omega Cloak — DPA Koruma Sistemi

**Problem**: Korumasız AES, güç tüketimi izleri ile 1.000 trace'de kırılabilir.

**Çözüm**: 4 bağımsız katman, her biri farklı bir saldırı yüzeyini kapatır.

#### Katman A: Dual Kaotik PRNG

```
Map A: x(n+1) = 3.99 × x(n) × (1 - x(n))   [Logistic Map]
Map B: x(n+1) = 3.97 × x(n) × (1 - x(n))   [Farklı parametre]
Çıkış: chaos = x_a XOR x_b                   [Periyot kırma]
```

| Parametre | Değer |
|-----------|-------|
| Aritmetik | Q8.24 Fixed-Point (32-bit) |
| Çarpıcı | Fabric multiplier (DSP-free) |
| Pipeline | 7 cycle |
| NIST testi | Frequency, Runs, Block Frequency: PASS |

**Neden LFSR değil?** LFSR'lar lineerdir ve kısa sürede tahmin edilebilir. Kaotik PRNG'nin orbit uzunluğu astronomikdır ve tahmin edilemez.

#### Katman B: Clock Jitter Enjeksiyonu

| Parametre | Değer |
|-----------|-------|
| Mekanizma | MMCME2_ADV dinamik fine phase shift |
| Çözünürlük | ~18.5 ps / adım |
| Sınır | ±108 adım (±2 ns) |
| Kontrol | PRNG-driven, FSM: IDLE→SHIFT→WAIT |
| Bypass | Temiz clock pass-through modu |

**Etki**: Saldırganın güç izlerini zamanda hizalaması (alignment) gerekir. ±2ns rastgele kayma bu hizalamayı imkansız kılar.

#### Katman C: Dummy Round Ekleme (Sahte İşlem)

| Parametre | Değer |
|-----------|-------|
| Shadow datapath | Tam AES round replikası (SubBytes + ShiftRows + MixColumns + AddRoundKey) |
| Sahte round sayısı | 0-3 / gerçek round (PRNG bits[1:0] ile seçilir) |
| Sahte state kaynağı | PRNG çıkışı (değişken switching activity) |
| Güç profili | Gerçek round ile **aynı** logic path |
| Sentez koruması | `DONT_TOUCH` attribute (optimize edilmez) |

**Neden etkili?** Saldırgan, kaydedilen güç izinde 10-13 AES round'u görür ama hangisinin gerçek, hangisinin sahte olduğunu ayırt edemez. Sahte round'lar gerçek S-box ve MixColumns kullanır → güç imzası aynıdır.

#### Katman D: Boolean Maskeleme

S-box girişi, PRNG'den gelen rastgele maske byte'ı ile XOR'lanır:
```
masked_input = real_input XOR mask
S-box[masked_input] → korelasyon kopmuştur
```

#### Ölçüm Sonucu (CPA Simülasyonu)

| Metrik | Korumasız AES | Omega Cloak |
|--------|:------------:|:-----------:|
| İz sayısı | 1,000 | 50,000 |
| Anahtar kurtarıldı mı? | **EVET** | **HAYIR** |
| Gerçek anahtar korelasyonu | 0.9157 | 0.0107 |
| **Korelasyon azalması** | — | **%98.8** |

### 3.2 PVT Monitor — Fiziksel Durum İzleme

V13'te bu görev sadece PCB üzerindeki analog devreler (LM2907N) tarafından yapılıyordu. V14'te FPGA'nın **içine** de dijital bir PVT monitor eklenmiştir.

| Parametre | Analog (Katman 3) | Dijital PVT (Katman 2) |
|-----------|:-----------------:|:---------------------:|
| Konum | PCB üzerinde | FPGA içinde |
| Sensör tipi | LM2907N F-to-V | Ring Oscillator |
| Sensör sayısı | 1 (merkezi) | 4 (dağıtık) |
| Ölçüm | Analog voltaj | Dijital frekans sayma |
| Tepki süresi | ~100 µs | ~1 ms |
| Alarm | LTC1540 comparator | Kodlanmış ±%20 eşik |
| Avantaj | FPGA bağımsız | Yazılımla yapılandırılabilir |

**Neden ikisi de lazım?** Analog watchdog FPGA'nın kendisi çökse bile çalışır. Dijital PVT monitor daha hassas ve çok noktalı ölçüm yapar. **Derinlemesine savunma.**

### 3.3 AEGIS AI Anomaly Detection

**Durum**: Deneysel aşamada. Mimari tamamlanmış, eğitim verisi silikon doğrulamadan sonra toplanacak.

| Parametre | Değer |
|-----------|-------|
| Model | Echo State Network (ESN) |
| Giriş | PVT sensör verisi (Q8.8, AXI4-Stream) |
| Aktivasyon | tanh LUT ROM |
| Çıkış | anomaly_irq (gated by AEGIS_ENABLE_PIN) |
| Kontrol | Deney aşamasında: enable pin ile devre dışı bırakılabilir |

**Amaç**: PVT eşik tabanlı alarm "sıcaklık X'i geçti mi?" sorusunu sorar. AEGIS AI ise "bu davranış pattern'i **normal mi**?" sorusunu sorar — daha önce görülmemiş yeni saldırı türlerini tespit edebilir.

### 3.4 Genişletilmiş Kill Chain (V14)

V13'te kill chain 2 kaynaklıydı. V14'te 4'e genişletildi:

```
V13 Kill Chain:
  KILL_PIN ──────────────────┐
  PF_WDT (PolarFire Watchdog)┼──→ OR → kill_active → Zeroization
                             │
V14 Kill Chain:
  KILL_PIN ──────────────────┐
  PF_WDT ───────────────────┤
  AEGIS_IRQ (AI Anomaly) ──AND(ENABLE)─┤
  PVT_ALARM (Digital) ──────┼──→ OR → kill_active → Zeroization
```

**AEGIS_ENABLE_PIN gate**: AI modülü deneysel olduğundan, false positive riski vardır. Enable pini sayesinde AI alarmı istenirse devre dışı bırakılabilir — sistemin geri kalanı etkilenmez.

### 3.5 V13 Miras Modülleri (Dokunulmadı)

| Modül | Dosya | Durum |
|-------|-------|-------|
| AES-256-CTR Engine | `aes_core_wrapper.vhd` | V13 aynen korundu |
| SPI Volatile Key Loader | `key_loader_spi.vhd` | V13 aynen korundu |
| TRNG (3x Ring Osc) | `trng_ring_osc.vhd` | V13 aynen korundu |
| Kill Protocol (Async) | `kill_protocol.vhd` | V14: 4 kaynak girişi eklendi |
| Data Gearbox (128↔8) | `data_gearbox.vhd` | V13 aynen korundu |
| UART Pipeline | `uart_driver.vhd` | V13 aynen korundu |
| Watchdog Monitor | `watchdog_monitor.vhd` | V13 aynen korundu |
| MMCM Clocking | `artix7_clocking.vhd` | V13 aynen korundu |

**Geriye dönük uyumluluk**: Tüm V13 fonksiyonelliği %100 korunmuştur. Yeni modüller enable pinleri ile devre dışı bırakılabilir → V13 davranışına geri dönülür.

### 3.6 SPI Şifreli Anahtar Transferi ★ V14.1 YENİ ★

**Problem**: Kriptografik anahtar SPI bus üzerinden cleartext olarak yükleniyor. Saldırgan PCB üzerindeki SPI hatlarına logic analyzer bağlayarak anahtarı doğrudan yakalayabilir.

**Çözüm — Çift Katmanlı Koruma (PCB + Protokol):**

#### A. PCB-Seviyesi Fiziksel Koruma

```
PCB Katman Yapısı (6-Layer):
  Katman 1: Bileşen yüzü (FPGA, SPI Flash)
  Katman 2: GND Düzlemi ← Faraday kafesi üst
  Katman 3: SPI hatları ← İÇ KATMAN (yüzeyde YOK)
  Katman 4: VCC Düzlemi
  Katman 5: Sinyal
  Katman 6: GND Düzlemi ← Faraday kafesi alt

SPI MOSI/MISO/SCK hatları:
  ✅ İç katmanda (Katman 3) — yüzeyden probe yapılamaz
  ✅ Üst ve alt GND düzlemleri arasında — EM sızıntısı bastırılır
  ✅ Blind via ile bileşenlere bağlantı (through-hole via değil)
  ✅ Epoksi + mu-metal kaplama — decapping gerektirir
```

| Parametre | Değer |
|-----------|-------|
| SPI hat katmanı | Katman 3 (iç katman) |
| Probe koruması | ≥2 GND düzlemi ile shielded |
| Via tipi | Blind via (yüzeyden görünmez) |
| Ek maliyet | ~$2-3/PCB (6-layer vs 4-layer farkı) |

#### B. Protokol-Seviyesi Şifreleme (Transport Key)

Anahtar SPI üzerinden asla açık metin olarak akmaz:

```
┌─────────────────┐                    ┌─────────────────┐
│  Güvenli Kaynak  │                    │  FPGA (Artix-7) │
│  (STM32 veya     │     SPI Bus        │                 │
│   Secure Element)│  (iç katman)       │                 │
│                  │                    │                 │
│  1. Transport Key│                    │ 1. Transport Key│
│     (eFUSE ile   │                    │    (eFUSE ile   │
│      paylaşılır) │                    │     paylaşılır) │
│                  │                    │                 │
│  2. Nonce üret   │──── Nonce ────────→│ 2. Nonce al     │
│     (TRNG)       │                    │                 │
│                  │                    │                 │
│  3. Session Key  │                    │ 3. Session Key  │
│  = AES(TK, Nonce)│                    │ = AES(TK, Nonce)│
│                  │                    │                 │
│  4. Enc_Key =    │── Şifreli Anahtar→│ 4. Key =        │
│  AES(SK, RealKey)│                    │ AES_Dec(SK,     │
│                  │                    │        Enc_Key) │
└─────────────────┘                    └─────────────────┘
```

| Adım | İşlem | SPI'da Görünen |
|------|-------|:--------------:|
| 1 | Transport Key paylaşımı | ❌ (eFUSE, SPI dışı) |
| 2 | Nonce gönderimi | Rastgele 128-bit |
| 3 | Session Key türetimi | ❌ (her iki tarafta yerel) |
| 4 | Şifreli anahtar aktarımı | AES-CTR(SK, anahtar) |

**Saldırgan SPI'ı dinlerse ne görür?**
- Adım 2: Rastgele nonce (değersiz)
- Adım 4: AES ile şifrelenmiş blob (Transport Key olmadan açılamaz)
- Transport Key eFUSE'da — fiziksel olarak okunamaz (OTP, yalnızca yazılabilir)

**FPGA kaynak maliyeti**: ~200 LUT + ~100 FF (AES decryptor zaten mevcut, tekrar kullanılır)

---

## 4. Katman 3: Güvenlik Bekçileri — Analog Watchdog

Bu katman tamamen **FPGA'nın dışında**, PCB üzerindeki analog devrelerden oluşur. FPGA compromised olsa bile bu devreler çalışmaya devam eder.

### 4.1 Analog Frekans Polisi (F-to-V Monitor)

**Prensip**: Dijital sayaçlar manipülasyona açıktır. Saf fizik kullanır.

| Bileşen | Parça | Görev |
|---------|-------|-------|
| F-to-V Dönüştürücü | LM2907N-8 | 50 MHz clock'u lineer voltaja çevirir (2.50V) |
| Voltaj Referansı | TI REF3325 | Sıcaklıktan bağımsız referans (3 ppm/°C) |
| Kalibrasyon | Bourns 3296W (25-tur trimpot) | Üretim toleranslarını sıfırlar, ayar sonrası mühürlenir |
| Karşılaştırıcı | LTC1540 (Nano-Power) | Voltaj 2.48V-2.52V dışına çıkarsa → KILL |

**Saldırı senaryosu**: Adversary clock frekansını %2'den fazla değiştirirse (overclocking, underclocking, glitch), voltaj aralık dışına çıkar ve analog devre **dijital müdahale olmadan** kill tetikler.

### 4.2 Faz Dedektörü (Phase Killer)

**Problem**: Frekans doğru olsa bile, clock fazı kaydırılarak zamanlama saldırıları yapılabilir.

| Bileşen | Parça | Görev |
|---------|-------|-------|
| XOR Gate | 74VHC86 | İki FPGA'ya giden clock yollarını karşılaştırır |
| Filtre | RC Ağı (10kΩ + 1nF) | XOR çıkışındaki darbeleri DC voltaja çevirir |
| Tetik | LTC1540 | Faz farkı nanosaniye bile olsa → alarm |

**Nasıl çalışır?** İki FPGA'ya giden clock aynı frekansta ama farklı fazda ise, XOR gate periyodik pulse üretir. RC filtre bunu DC voltaja çevirir. LTC1540 bu voltajı eşikle karşılaştırır. Faz sapması → kill.

### 4.3 Anti-Chypnosis: VCCINT Crowbar Devresi ★ V14.1 YENİ ★

**Tehdit**: Chypnosis (2025, IEEE S&P 2026, AMD-SB-8018), FPGA'nın besleme voltajını hızla düşürerek (brownout) çipi "uyku" durumuna sokar. Bu durumda:
- Clock durur → dijital sensörler (PVT, XADC) çalışamaz
- Async CLR çalışamaz (VCCINT < threshold)
- AMA: Flip-flop'lar veri tutmaya devam eder (data retention ~0.3V)
- Saldırgan LLSI (lazer) veya empedans analizi ile FF'lerdeki anahtarı okur

**Neden FPGA firmware ile çözülemez?**  
FPGA içindeki HER mekanizma (ring oscillator, kill protocol, XADC) aynı VCCINT'ten beslenir. VCCINT düşürüldüğünde hepsi birlikte durur. AMD, Artix-7'deki XADC'nin bu saldırıyı tespit edemeyeceğini doğrulamıştır.

**Çözüm**: FPGA'dan tamamen bağımsız, saf analog crowbar devresi:

```
VCCINT (1.0V) ──┬──→ FPGA
                │
                ├──→ R_deglitch (100kΩ) ──→ LTC1540 Comparator
                │                    │       IN+ = VCCINT (filtrelenmiş)
                │                   C (100nF) IN- = REF3325 × R-divider = 0.85V
                │                    │       Hysteresis: ~20mV
                │                   GND      │
                │                            ↓ VCCINT < 0.85V → OUT = HIGH
                │                            │
                │                       ┌────┴────┐
                │                       │ BT169   │ SCR (Thyristor)
                │                       │ Gate ←──┘
                │                       │ Anode = VCCINT
                │                       │ Cathode = GND
                │                       └─────────┘
                │                            │
                └────────────────────────────┘
                     ↓
              VCCINT → 0V (< 1µs)
              FF data retention SONA ERER
              Anahtar fiziksel olarak YOK
```

| Parametre | Değer |
|-----------|-------|
| Algılama eşiği | VCCINT < 0.85V |
| SCR tetikleme | < 500ns |
| VCCINT → 0V süresi | < 1µs |
| Veri retention voltajı | ~0.3V (eşiğin altına düşer) |
| Güç kaynağı | VCCINT (bağımsız, FPGA clock gerektirmez) |
| Latching davranış | SCR bir kez tetiklenince kalıcı → tekrar güç verilmeli |
| Chypnosis penceresi | **0µs** (voltaj 0.85V'a düşmeden SCR tetiklenir) |
| **Deglitch filtresi** | R=100kΩ, C=100nF → τ=10ms (modem spike filtresi) |

**Deglitch Filtresi (★ Red Team Karşı Önlem):**
Modem TX burst sırasında (≤2A peak) PDN üzerinde mikrosaniyelik voltaj spike'ları oluşabilir. Bu spike'lar crowbar'a false positive tetikleme yapabilir. **RC deglitch filtresi** bunu önler:

```
VCCINT ─────→ R (100kΩ) ────→ LTC1540 IN+  (sense, filtrelenmiş)
                          │
                         C (100nF)
                          │
                         GND

τ = R × C = 100k × 100n = 10ms

Modem spike (<1ms): Filtrelenir → crowbar TETİKLENMEZ
Chypnosis (sürekli düşüş >10ms): Geçer → crowbar TETİKLENİR
```

| Bileşen | Parça | Maliyet |
|---------|-------|--------|
| Comparator | LTC1540 (zaten mevcut, 3. birim) | $4.00 |
| Crowbar | BT169 (SCR/Thyristor, TO-92) | $0.30 |
| Gate direnci | 10kΩ (0402) | $0.01 |
| Deglitch R | 100kΩ (0402) | $0.01 |
| Deglitch C | 100nF (0402) | $0.01 |
| **Anti-Chypnosis toplam** | | **~$4.33** |

**Neden SCR?** MOSFET crowbar voltaj düşünce kapanabilir. SCR bir kez tetiklenince akım akmaya devam eder (latching) — saldırgan voltajı geri yükseltse bile VCCINT kısa devrede kalır.

### 4.4 Analog vs Dijital Watchdog Karşılaştırması

| Özellik | Analog (PCB) | Dijital (FPGA PVT) |
|---------|:------------:|:------------------:|
| FPGA çökerse çalışır mı? | ✅ Evet | ❌ Hayır |
| Chypnosis'e dayanır mı? | ✅ Evet (crowbar) | ❌ Hayır |
| Çok noktalı ölçüm? | ❌ Tek nokta | ✅ 4 sensör |
| Yazılımla ayarlanabilir mi? | ❌ Trimpot ile fiziksel | ✅ Register ile |
| Hassasiyet | Orta (±%2) | Yüksek (±%1 mümkün) |
| Maliyet | ~$10 (BOM) | $0 (FPGA içi) |
| **Sonuç** | İkisi de gerekli — complementary protection |

---

## 5. Katman 4: Fiziksel İmha ve Koruma

### 5.1 Sıralı İnfaz Protokolü — The Reaper

Tehdit algılandığında (herhangi bir katmandan) iki aşamalı fiziksel imha başlar:

| Aşama | Süre | Bileşen | Eylem |
|-------|------|---------|-------|
| **T+0** | Anında | FPGA Kill Protocol | Tüm FF'ler asenkron sıfırlanır (<6ns), kriptografik anahtarlar yok |
| **T+150ns** | 150 ns | GaN Systems GS61008P | Modemin gücünü keser → veri sızıntısı anında durur |
| **T+10ms** | 10 ms | Omron G6D-1A-ASI (HV Röle) | 1000V kapasitör bankasını RAM/Flash VCC hattına boşaltır |

**Sonuç**: T+150ns'de iletişim kesilir, T+10ms'de silikon zarı (die) fiziksel olarak patlar.

**Koruma detayları:**
- GaN gate hattında SMAJ15A TVS koruması (saldırgan transistörü bypass edemez)
- HV röle normalde açık (deenergized = güvenli durum)
- Kapasitör sürekli şarjlı tutulur (güç kesilirse bile son imha gerçekleşir)

### 5.2 Modem Karantinası ★ Red Team Güçlendirilmiş ★

Modem (Quectel EC25-E) **güvenilmeyen** bileşen olarak muamele görür.

```
┌──────────┐     Whitelist AT     ┌──────────────┐     Encrypted     ┌──────────┐
│  FPGA    │ ←── commands only ──→│  STM32L4     │ ←── data only ──→│  Modem   │
│  (Güven) │                      │  (Firewall)  │                   │ (Güvensz)│
└──────────┘                      └──────────────┘                   └──────────┘
```

#### 5.2.1 AT Whitelist — Exact Match Engine

STM32 üzerindeki AT komut filtresi, basit `strncasecmp` prefix matching **KULLANMAZ**. Kesin eşleşme (exact match) motoru:

```c
// BEYAZ LİSTE (tam eşleşme, prefix değil)
static const char* AT_WHITELIST[] = {
    "AT+CSQ",    // sinyal kalitesi
    "AT+CREG?",  // ağ kaydı sorgu
    "AT+COPS?",  // operatör sorgu
    "AT+CGATT?", // PDP context
    "AT+QSEND",  // veri gönder (yalnızca şifreli payload)
    NULL
};

bool at_filter(const char* cmd) {
    // 1. Uzunluk kontrolü (max 64 byte, fazlası DROP)
    if (strlen(cmd) > 64) return false;

    // 2. Yasak karakter tarama (shell meta-karakterleri)
    for (int i = 0; cmd[i]; i++) {
        if (cmd[i] == ';' || cmd[i] == '|' || cmd[i] == '&' ||
            cmd[i] == '$' || cmd[i] == '`' || cmd[i] == '\n' ||
            cmd[i] == '(' || cmd[i] == ')' || cmd[i] == '{' ||
            cmd[i] == '}') {
            return false; // REJECT: enjeksiyon girişimi
        }
    }

    // 3. Exact match (prefix DEĞİL, tam eşleşme)
    for (int i = 0; AT_WHITELIST[i]; i++) {
        if (strcmp(cmd, AT_WHITELIST[i]) == 0) {
            return true;  // PASS: tam eşleşme
        }
    }

    return false; // REJECT: bilinmeyen komut
}
```

| Koruma | Detay |
|--------|-------|
| Eşleşme tipi | `strcmp` (tam eşleşme, prefix değil) |
| Uzunluk limiti | 64 byte (taşma önlenir) |
| Meta-karakter filtre | `;` `|` `&` `$` `` ` `` `\n` `(` `)` |
| IFS bypass | Engellenir — `$`, `{`, `}` filtrelenir |
| `AT+QLINUXCMD` | ❌ Listede YOK → REJECT |
| `AT+MBASHCMD` | ❌ Listede YOK → REJECT |
| `AT+CSQ;reboot` | ❌ `;` karakter filtresi → REJECT |

#### 5.2.2 UART Flood DoS Koruması

Saldırgan modem üzerinden STM32'ye yüksek hızda gürültü verisi gönderebilir. ORE (Overrun Error) bayrağı sonsuz kesme döngüsüne neden olabilir.

**Çözüm — 4 katmanlı koruma:**

| Katman | Koruma | Mekanizma |
|--------|--------|:---------:|
| **donanım** | RTS/CTS akış kontrolü | STM32 UART_CR3.RTSE=1, CTSE=1 |
| **donanım** | DMA tabanlı UART alımı | DMA circular mode, ISR yerine DMA TC interrupt |
| **yazılım** | ORE bayrak temizleme | ISR'da her zaman `USART_SR` + `USART_DR` dummy read |
| **yazılım** | Rate limiter | >1000 byte/100ms → modem UART devre dışı, alarm |

```c
// ORE sonsuz döngü önleme (STM32 HAL)
void USART2_IRQHandler(void) {
    if (__HAL_UART_GET_FLAG(&huart2, UART_FLAG_ORE)) {
        __HAL_UART_CLEAR_OREFLAG(&huart2);
        uart_overrun_count++;
        if (uart_overrun_count > 10) {
            modem_uart_disable();
            kill_chain_trigger(KILL_SRC_UART_FLOOD);
        }
        return;
    }
    HAL_UART_IRQHandler(&huart2);
}
```

**RTS/CTS neden kritik?** Donanımsal akış kontrolü, STM32'nin tampon dolu olduğunu modem'e sinyal ile bildirir. Modem göndermeyi durdurur. Yazılımsal rate limiting yıkılsa bile donanım seviyesinde taşma önlenir.

#### 5.2.3 DMA Donanımsal Enforcement

STM32 — Modem arasında DMA **kullanılmaz**. Bu yazılımsal karar değil, **donanımsal enforcement**:

| Mekanizma | Detay |
|-----------|-------|
| STM32 MPU Bölge 0 | UART2 DMA kanalı = Erişim ENGELLENDİ |
| DMA kanal konfig | USART2_RX/TX DMA kanalları = DISABLE (RCC'de clock gated) |
| STM32 Firewall | UART2 peripheral → Secure domain dışında erişilemez |
| Geliştirici koruması | MPU konfigürasyon write-protect (Option Byte) |

Bir geliştirici "performans için" DMA eklemek istese bile, MPU Bölge 0 ve Firewall bunu **donanım seviyesinde** engeller.

### 5.3 Fiziksel Zırhlama

| Katman | Malzeme | Tehdit |
|--------|---------|--------|
| **Epoksi** | MG Chemicals 832HD (siyah, vakum döküm) | X-Ray ile devre takibi, probing |
| **Manyetik** | Mu-Metal levha | EM probe ile sinyal çıkarma |
| **RF** | Bakır mesh | RF emanation sızıntısı |
| **PCB** | 6+ katmanlı, inner-layer SPI routing | Probe koruması, SPI gizleme |
| **Optik** | Photodiode mesh (FPGA altı) | Laser Fault Injection |

### 5.4 Laser Fault Injection (LFI) Koruması ★ V14.1 YENİ ★

**Problem**: Saldırgan çipin epoksisini kürarak (decapping) lazer ile tekil transistörlere hata enjekte edebilir. Voltaj glitch'ten çok daha hassas ve hedefli — spesifik AES round'larına hata verilebilir (Differential Fault Analysis).

**Neden FPGA firmware çözemez?**  
LFI fiziksel bir ışık saldırısıdır. FPGA'nın içinde ışık sensörü yoktur. Ring oscillator frekans değişimini algılayabilir ama LFI nanometre-hassasiyetli hedefli saldırıdır — sadece birkaç gate'i etkiler, global frekansı değiştirmez.

**Çözüm: PCB-seviyesi Photodiode LFI Mesh:**

```
                    FPGA Die (üstten görünüm)
              ┌─────────────────────────┐
              │                         │
              │    ┌───┐    ┌───┐       │
              │    │PD1│    │PD2│       │
              │    └───┘    └───┘       │
              │                         │
              │    ┌───┐    ┌───┐       │
              │    │PD3│    │PD4│       │
              │    └───┘    └───┘       │
              │                         │
              └─────────────────────────┘
                        ↓ (hepsi paralel)
              ┌─────────────────────────┐
              │ LTC1540 Comparator      │
              │ IN+ = Photodiode çıkışı │
              │ IN- = Dark referans     │
              │ OUT → Kill Chain OR     │
              └─────────────────────────┘

Normal: PD çıkışı ≈ 0 (karanlık, epoksi altında)
Decap + Lazer: PD çıkışı >> eşik → LTC1540 alarm → Kill Chain
```

**Çalışma prensibi:**
1. 4× BPW34 Si PIN photodiode, FPGA BGA footprint'inin altına monte edilir
2. Epoksi kaplama altında diyotlar karanlıkta → çıkış ≈ 0µA
3. LFI saldırısı için saldırganın epoksiyi kırması GEREKİR
4. Epoksi kırıldığı an ortam ışığı + lazer, photodiode'u tetikler
5. LTC1540 (zaten mevcut) ışık eşiğini algılar → Kill Chain
6. **LFI saldırısının ön koşulu (decapping) kendisi alarm kaynağıdır**

| Parametre | Değer |
|-----------|-------|
| Photodiode | BPW34 (Si PIN, 900nm peak, IR-sensitive) |
| Adet | 4 (her FPGA köşesinde) |
| Dark current | <2nA @ 25°C |
| Algılama eşiği | >10µA (ortam ışığı veya 850nm LFI lazer) |
| Yerleşim | FPGA BGA footprint altı, PCB alt yüzü |
| Bağlantı | Paralel → LTC1540 (4. birim) → Kill Chain |
| Ek maliyet | 4× BPW34 ($0.30) + 1× LTC1540 ($4.00) = ~$5.20 |
| False positive riski | ❌ Sıfır — epoksi altında karanlık garantili |

**Neden 4 adet?** FPGA die'ın farklı bölgeleri hedeflenebilir. Tek photodiode'un lazer noktasından uzak kalma riski var. 4 diyot ile kapsama %100'e yaklaşır.

### 5.5 PDN İzolasyonu — Güç Alanı Ayrımı ★ Red Team Karşı Önlem ★

**Problem**: Modem TX burst sırasında (≤2A peak) ortak güç hattında voltaj düşüşü oluşur. Bu düşüş FPGA VCCINT'i etkileyebilir — hem işlem hatalarına hem crowbar false positive'e yol açar. **Saldırgan, modem'e büyük veri paketleri göndererek sistemi uzaktan yok edebilir.**

**Çözüm: 4 Bağımsız Güç Alanı (Power Domain Isolation):**

```
Ana Besleme (12V/5V)
       │
       ├─── DCDC #1 (TPS62160, 3.3V, 1A) ───→ MODEM VCC
       │    └─ Ferrit Bead (BLM18PG221SN1)
       │    └─ 100µF bulk + 10µF + 100nF decoupling
       │
       ├─── LDO #1 (TPS7A8300, 1.0V, 300mA) ──→ FPGA VCCINT
       │    └─ Ultra-low noise (<4µVrms)
       │    └─ PSSR: 72dB @ 1MHz (modem gürültüsü bastırılır)
       │    └─ Modem hattından TAMAMEN İZOLE
       │
       ├─── LDO #2 (TPS7A4700, 3.3V, 150mA) ──→ FPGA VCCAUX/IO
       │
       └─── LDO #3 (TPS7A4700, 3.3V, 300mA) ──→ STM32 + Dijital

İzolasyon Detayları:
  • Modem ↔ FPGA: FARKLI regülatör, farklı giriş kapasitörü
  • Ferrit bead: 220Ω @ 100MHz → yüksek frekanslı gürültü bastirma
  • Star grounding: Her alanın GND'si tek noktada birleşir
  • Modem alanı resetlenebilir (GaN ile güç kesme)
```

| Parametre | Değer |
|-----------|-------|
| VCCINT kaynağı | Dedicated LDO (TPS7A8300) |
| Modem kaynağı | Ayrı DCDC (TPS62160) |
| İzolasyon | >72dB PSSR + ferrit bead |
| Modem 2A spike etkisi | <1mV VCCINT ripple (0.85V crowbar eşiğinden uzak) |
| Ek maliyet | ~$6.50 (TPS7A8300 + TPS62160 + passive) |

**Bu önlem olmadan**: Modem TX → VCCINT dip → Crowbar false positive → SELF-DESTRUCTION  
**Bu önlem ile**: Modem TX → Modem VCC'de dip → FPGA VCCINT ETKİLENMEZ → GÜvenli

---

## 6. Katman 5: Yazılım Yığını

**Prensip**: İşletim sistemi donanımın kölesidir. Karar verici değildir.

### 6.1 Platform

| Bileşen | Seçim | Gerekçe |
|---------|-------|---------|
| OS | Buildroot Linux (özel derleme) | Minimal saldırı yüzeyi |
| Kernel | 6.1 LTS (Hardened) | Gereksiz sürücüler silinmiş |
| Init | Runit | Systemd'nin karmaşıklığından kaçınma |
| Core | Rust | Bellek güvenliği, `zeroize` crate ile anahtar temizliği |
| UI | Python | Sadece ekrana piksel basar, kritik veri tutmaz |
| Köprü | PyO3 | Rust ↔ Python güvenli veri geçişi |

### 6.2 POST — Güvenli Başlatma Sırası (V14 Güncel)

```
1. Güç verilir
   → Ekran AÇIK, USB/Klavye KAPALI (FQP27P06 MOSFET ile)
   → Logic Wall ENABLE = LOW (DONE pin AND gate, boot maskeleme)
   → Analog watchdog bypass aktif (factory trace)

2. FPGA'lar boot olur
   → PolarFire: <1ms'de hazır (Flash tabanlı, DONE=1)
   → Artix-7: ~50ms yapılandırma yükler (SRAM, SPI Flash'tan)
   → Bu süre boyunca Logic Wall PASIF (yanlış kill önlenir)

3. Artix-7 DONE=1 olur
   → AND gate: ARTIX_DONE & PF_DONE = 1 → Logic Wall ENABLE
   → Test vektörleri çalıştırılır
   → Logic Wall karşılaştırma yapar
   → PVT Monitor baseline alır
   → Omega Cloak enable olur

4. Logic Wall ONAY verir
   → USB MOSFET açılır
   → Klavye elektriği gelir

5. Ekranda "SYSTEM VERIFIED" görünür
   → Kullanıcı şifre girebilir

KORUMA: Klavye elektriği yokken şifre girilemez.
         Kötü niyetli firmware USB'yi bypass edemez — elektrik yok.
         Boot sırasında Logic Wall pasif — yanlış imha önlenir.
```

---

## 7. Katman 6: Üretim ve Fabrika Güvenliği

### 7.1 Factory Bait Stratejisi

| | Factory Bait | Golden Image |
|---|:---:|:---:|
| Fabrikaya gönderilen | ✅ | ❌ |
| Kripto IP içeriği | %0.4 (10 LUT) | %100 |
| İçerik | LED chaser + UART echo | Tam kripto sistem |
| Şifreleme | Açık | AES-encrypted (eFUSE) |
| Amaç | PCB montaj doğrulama | Saha deployment |

### 7.2 Deployment Akışı

```
Fabrika:
  1. Factory bait bitstream yüklenir (IP sızdırmaz)
  2. PCB monte edilir, lehim kalitesi test edilir
  3. Cihaz gönderilir

Güvenli Tesis:
  4. eFUSE key yakılır (GERİ ALINAMAZ!)
  5. Golden image encrypted olarak yüklenir
  6. JTAG kalıcı devre dışı (eFUSE JTAG_DISABLE | READBACK_PROTECT)
  7. SVN (Security Version Number) yakılır (anti-rollback)
  8. ICAP erişimi devre dışı (bitstream'de ICAP_DISABLE)
  9. JTAG PCB trace'leri fiziksel olarak kesilir (matkap)
  10. Bypass yolu fiziksel olarak yok edilir (matkapla delinir)
  11. Cihaz artık klonlanamaz / modifiye edilemez / downgrade edilemez
```

### 7.3 Anti-Starbleed Önlemleri ★ Red Team Karşı Önlem ★

**Tehdit**: Starbleed (CVE-2020-5991) Xilinx 7-serisi (Artix-7 dahil) FPGA'larda WBSTAR yazmacı üzerinden şifreli bitstream plaintext çıkarılmasına izin verir. Unpatchable silicon bug.

**Starbleed'in gereksinimleri ve TITAN V14'ün yanıtları:**

| Starbleed Gereksinimi | TITAN V14 Durumu |
|-----------------------|:----------------:|
| JTAG erişimi (WBSTAR okuma) | ❌ eFUSE ile KALICI devre dışı |
| SelectMAP erişimi | ❌ Pin'ler GND'ye bağlı, epoksi kaplı |
| JTAG PCB trace'leri | ❌ Fiziksel olarak kesilmiş (matkap) |
| ICAP dahili erişim | ❌ Bitstream'de ICAP_DISABLE set |
| Fiziksel erişim | ❌ Epoksi + mu-metal + photodiode mesh |

**Saldırı zinciri analizi:**
1. Saldırgan JTAG port'una erişmeye çalışır → eFUSE disable + trace kesilmiş → **BAŞARISIZ**
2. Saldırgan SelectMAP dener → Pin'ler sabit, epoksi kaplı → **BAŞARISIZ**
3. Saldırgan ICAP üzerinden dener → ICAP bitstream'de devre dışı → **BAŞARISIZ**
4. Saldırgan epoksiyi kırar → Photodiode mesh tetiklenir → Kill chain → **SİSTEM YOK EDİLDİ**

### 7.4 Anti-Rollback: eFUSE SVN ★ Red Team Karşı Önlem ★

**Problem**: Saldırgan bilinen zafiyetli eski bitstream sürümünü yükleyebilir (downgrade attack).

**Çözüm**: eFUSE tabanlı Security Version Number (SVN):

```
eFUSE SVN Register (32-bit):
  Bit 0: ✅ Yakıldı (V14.0)
  Bit 1: ✅ Yakıldı (V14.1 — Red Team patch'leri)
  Bit 2-31: Boş (gelecek güncellemeler için)

Boot sırası:
  1. FPGA bitstream yükler
  2. Bitstream header'daki SVN okunur
  3. eFUSE SVN ile karşılaştırılır
  4. Bitstream SVN < eFUSE SVN → REJECT (yükleme iptal)
  5. Bitstream SVN >= eFUSE SVN → ACCEPT
```

| Parametre | Değer |
|-----------|-------|
| SVN bit sayısı | 32 (32 güncelleme kapasitesi) |
| Geri alma | ❌ İMKANSIZ (eFUSE fiziksel olarak geri alınamaz) |
| Yazılımsal bypass | ❌ İMKANSIZ (eFUSE donanım kontrolü) |

### 7.5 Bypass Yolu

**Problem**: Boş FPGA'lar ilk açılışta hiçbir clock/heartbeat üretmez → analog watchdog tetiklenir → imha.

**Çözüm**: PCB üzerinde matkapla delinebilir bir "bypass trace" bırakılmıştır. Kod yüklendikten ve sistem doğrulandıktan sonra bu iz **fiziksel olarak yok edilir** (matkap ile).

### 7.6 Termal Yönetim

- GaN transistörlerin (GS61008P) PCB altında ısınmasını önlemek için **termal via array** kullanılmıştır
- Geniş bakır pour alanları (thermal pad)
- HV bileşenlerle dijital bölge arasında **creepage distance** korunmuştur

---

## 8. Birleşik Kill Zinciri

Tüm katmanlardan gelen tehdit sinyalleri tek bir kill noktasında birleşir:

```
                         KATMAN 1: Compute
                         ┌─────────────────┐
                         │ Logic Wall FAIL │───┐
                         │ (1 bit fark)    │   │
                         └─────────────────┘   │
                                               │
                         KATMAN 2: AEGIS        │
                         ┌─────────────────┐   │
                         │ KILL_PIN        │───┤
                         │ PF_WDT Timeout  │───┤
                         │ AEGIS Anomaly   │─AND(EN)─┤
                         │ PVT Alarm       │───┤
                         └─────────────────┘   │
                                               │
                         KATMAN 3: Analog       │
                         ┌─────────────────┐   │
                         │ Freq Police     │───┤
                         │ Phase Killer    │───┤
                         └─────────────────┘   │
                                               │
                                               ▼
                                        ┌──────────┐
                                        │   OR     │
                                        │  GATE    │
                                        └────┬─────┘
                                             │
                              ┌──────────────┼──────────────┐
                              ▼              ▼              ▼
                         T+0: FPGA      T+150ns: GaN    T+10ms: HV
                         Zeroization    Modem Kill      Physical
                         (<6ns)         (Veri susturma) Destruction
```

**Ek analog yollar (FPGA dışı, clock bağımsız):**
```
VCCINT brownout ──→ LTC1540 (deglitch τ=10ms) → BT169 SCR → VCCINT=0V (<1µs)
LFI / Decapping ──→ Photodiode → LTC1540 → Kill Chain OR gate
UART Flood ──→ STM32 rate limiter → Kill Chain
MAD Auth Fail ──→ HMAC mismatch → Kill Chain
```

### 8.1 Kriptografik MAD Heartbeat ★ Red Team Karşı Önlem ★

**Problem**: Basit GPIO toggle heartbeat, saldırgan MCU'yu ele geçirirse sahte heartbeat üretebilir (spoofing).

**Çözüm: HMAC-SHA256 Challenge-Response:**

```
Her 100ms:
  1. Artix-7 → PolarFire: 32-bit rastgele nonce (TRNG)
  2. PolarFire: response = HMAC-SHA256(shared_key, nonce)[0:3]  // ilk 4 byte = 32 bit
  3. PolarFire → Artix-7: 32-bit response
  4. Artix-7: Doğrula
     ✅ Eşleşme → hayat devam
     ❌ 3 ardışık hata → KILL CHAIN

Shared Key:
  - Boot-time SPI ile yüklenir (volatile FF, transport key'li)
  - Her iki FPGA'da aynı key tutulur
  - Saldırgan key'i bilmeden sahte response ÜRETEMEz
  - Brute-force: 2^32 olasılık / 100ms = ~13.6 yıl
```

| Parametre | Değer |
|-----------|-------|
| Protokol | HMAC-SHA256 challenge-response |
| Nonce boyutu | 32-bit (TRNG) |
| Response boyutu | 32-bit (truncated HMAC) |
| Failover | 3 ardışık hata = kill |
| Spoofing riski | ❌ Key olmadan imkansız |
| Replay riski | ❌ Her cycle farklı nonce |

### 8.2 GaN Dead-Time Hardware Interlock ★ Red Team Karşı Önlem ★

**Problem**: Saldırgan FPGA PWM sinyallerini manipüle ederek GaN half-bridge'de shoot-through (üst+alt transistör aynı anda ON) oluşturabilir → fiziksel patlama.

**Çözüm: Donanımsal Dead-Time Enforcer (FPGA dışı):**

```
              FPGA PWM_H ──→ ┌─────────────┐ ──→ GaN HIGH-side
                             │ Dead-Time   │
              FPGA PWM_L ──→ │ Enforcer    │ ──→ GaN LOW-side
                             │ (74LVC2G14) │
                             │ + RC delay  │
                             └─────────────┘
                                   │
                            Anti-Overlap:
                            PWM_H=1 VE PWM_L=1
                            → HER İKİSİ de = 0
                            → Dead-time: 50ns min
```

| Parametre | Değer |
|-----------|-------|
| Dead-time | ≥50ns (RC delay ile) |
| Shoot-through koruması | Donanımsal anti-overlap gate |
| FPGA bağımlılığı | ❌ FPGA hack'lense bile dead-time KORUNUR |
| Ek maliyet | ~$0.50 (74LVC2G14 + RC) |

**Toplam tetik kaynağı**: 12 bağımsız kaynak:
1. Logic Wall (ayrık mantık)
2. KILL_PIN (fiziksel tamper mesh)
3. PF_WDT (PolarFire watchdog)
4. AEGIS_IRQ (AI anomaly)
5. PVT_ALARM (ring oscillator)
6. Freq Police (analog F-to-V)
7. Phase Killer (XOR+RC)
8. VCCINT Crowbar (SCR, Chypnosis, deglitch filtreli)
9. LFI Photodiode Mesh (optik, decapping/lazer)
10. SPI Integrity Check (transport key doğrulama hatası)
11. UART Flood Detector (rate limiter → STM32)
12. MAD Auth Failure (HMAC mismatch, 3 ardışık)

**Single Point of Failure**: YOKTUR.  
**Chypnosis SPOF**: YOKTUR. Crowbar FPGA'dan bağımsız.  
**LFI SPOF**: YOKTUR. Photodiode mesh FPGA'dan bağımsız.  
**Heartbeat Spoofing**: YOKTUR. HMAC key olmadan taklit edilemez.  
**GaN Shoot-Through**: YOKTUR. Dead-time enforcer FPGA'dan bağımsız.

---

## 9. Kaynak Kullanımı ve Performans

### 9.1 FPGA Kaynak Kullanımı (Artix-7 XC7A100T)

| Kaynak | V13 Baseline | V14 AEGIS Eklentisi | Toplam | Mevcut | Kullanım |
|--------|:-----------:|:------------------:|:------:|:------:|:--------:|
| LUT | ~900 | ~2,600 | ~3,500 | 63,400 | %5.5 |
| FF | ~350 | ~2,150 | ~2,500 | 126,800 | %2.0 |
| MMCM | 1 | 1 | 2 | 6 | %33 |
| BRAM | 1 | 1 | 2 | 135 | %1.5 |
| DSP48 | 0 | 0 | 0 | 240 | %0 |

**Boş kapasite**: FPGA'nın %94'ü hâlâ boş. Gelecek modüller (Kyber-768, Dilithium, ek sensörler) için alan mevcuttur.

### 9.2 BOM Maliyeti (Güvenlik Donanımı)

| Bileşen | Birim Fiyat | Adet | Toplam |
|---------|:----------:|:----:|:------:|
| 74HC688 | $0.50 | 33 | $16.50 |
| 74HC11 | $0.30 | 11 | $3.30 |
| LM2907N | $3.00 | 1 | $3.00 |
| LTC1540 | $4.00 | 4 | $16.00 |
| REF3325 | $2.50 | 1 | $2.50 |
| 74VHC86 | $0.40 | 1 | $0.40 |
| GS61008P | $8.00 | 1 | $8.00 |
| G6D-1A-ASI | $5.00 | 1 | $5.00 |
| SiTime SiT5356 | $3.00 | 1 | $3.00 |
| Bourns 3296W | $1.50 | 1 | $1.50 |
| 74HC08 (Boot gate) | $0.25 | 1 | $0.25 |
| BT169 SCR (Crowbar) | $0.30 | 1 | $0.30 |
| BPW34 Photodiode (LFI) | $0.30 | 4 | $1.20 |
| TPS7A8300 LDO (PDN) | $3.50 | 1 | $3.50 |
| TPS62160 DCDC (Modem) | $2.50 | 1 | $2.50 |
| 74LVC2G14 (Dead-time) | $0.25 | 1 | $0.25 |
| Deglitch R+C (Crowbar) | $0.02 | 1 | $0.02 |
| **Güvenlik BOM** | | | **~$68** |

---

## 10. Saldırı Vektörü Kapsamı

### 10.1 Tam Saldırı Matrisi (Red Team Doğrulanmış)

| # | Saldırı | Katman 1 | Katman 2 (AEGIS) | Katman 3 | Katman 4 | Sonuç |
|---|---------|:--------:|:----------------:|:--------:|:--------:|:-----:|
| 1 | DPA (Güç Analizi) | — | ✅ Omega Cloak | — | — | %98.8 azalma |
| 2 | Probing/Decapping | — | — | ✅ LFI Mesh | ✅ Epoksi+MuMetal | Optik alarm + kill |
| 3 | Clock Glitch | — | ✅ PVT alarm | ✅ Freq Police | ✅ GaN kill | 3 katman tespit |
| 4 | Faz Saldırısı | — | — | ✅ Phase Killer | — | Analog tespit |
| 5 | Freeze (Cold Boot) | — | ✅ PVT Monitor | — | — | <2ms algılama |
| 6 | Voltaj Glitch | — | ✅ PVT alert_hi | ✅ Freq Police | — | 2 katman tespit |
| 7 | Supply Chain | ✅ Dual-FPGA | — | — | — | 2 fabrika |
| 8 | HW Trojan | ✅ Logic Wall | — | — | — | Ayrık mantık |
| 9 | JTAG/Debug | — | — | — | — | eFUSE disable + trace cut |
| 10 | Two-Time Pad | — | ✅ TRNG IV | — | — | HW randomness |
| 11 | Key Extraction | — | ✅ Volatile FF | — | ✅ HV imha | Güçte kayıp |
| 12 | EM Emanation | — | ✅ Jitter+Dummy | — | ✅ Bakır mesh | Azaltma |
| 13 | Modem Exploit | — | — | — | ✅ STM32 FW | Whitelist AT |
| 14 | Bitstream Copy | — | — | — | — | eFUSE encrypt |
| 15 | **Chypnosis** ★ | — | ❌ bypass | ✅ **SCR Crowbar** | ✅ Epoksi | **<1µs veri imha** |
| 16 | **SPI Sniffing** ★ | — | ✅ Transport Key | — | ✅ Inner-layer PCB | **Şifreli transfer** |
| 17 | **Laser Fault Inj.** ★ | — | — | ✅ **Photodiode Mesh** | ✅ Epoksi | **Optik alarm + kill** |
| 18 | **Post-Quantum** ★ | — | ✅ AES-256 güvenli | — | — | **Kyber-768 hazır** |
| 19 | **AT Cmd Injection** ★★ | — | — | — | ✅ Exact match + sanitize | **Enjeksiyon imkansız** |
| 20 | **UART Flood DoS** ★★ | — | — | — | ✅ RTS/CTS + rate limit | **4 katman koruma** |
| 21 | **DMA Manipulation** ★★ | — | — | — | ✅ MPU + Firewall | **HW enforcement** |
| 22 | **Modem PDN Attack** ★★ | — | — | ✅ PDN izole + deglitch | — | **<1mV ripple** |
| 23 | **Starbleed** ★★ | — | — | — | ✅ JTAG cut + ICAP off | **Tüm yollar kapalı** |
| 24 | **Bitstream Rollback** ★★ | — | — | — | — | **eFUSE SVN** |
| 25 | **Heartbeat Spoofing** ★★ | ✅ Crypto MAD | — | — | — | **HMAC challenge-response** |
| 26 | **GaN Shoot-Through** ★★ | — | — | ✅ Dead-time HW | — | **HW interlock** |
| 27 | **Remote Timing** ★★ | — | ✅ HW AES + Omega | — | — | **Constant-time HW** |

**★ = V14.1 eklenen** | **★★ = Red Team raporu sonrası eklenen**

### 10.2 V13 vs V14 İyileştirme Tablosu

| Özellik | V13 | V14 (AEGIS) |
|---------|:---:|:-----------:|
| DPA koruması | ❌ Yok | ✅ 4 katman, %98.8 kanıtlı |
| Kill chain kaynakları | 2 | 12 bağımsız kaynak |
| Freeze algılama (FPGA içi) | ❌ Yok | ✅ 4x Ring Osc |
| AI anomaly detection | ❌ Yok | ✅ ESN (deneysel) |
| Dummy round injection | ❌ Yok | ✅ 0-3 sahte round/cycle |
| Clock jitter (FPGA içi) | ❌ Yok | ✅ MMCM ±2ns |
| **Chypnosis koruması** | ❌ Yok | ✅ SCR Crowbar + deglitch |
| **SPI anahtar şifreleme** | ❌ Cleartext | ✅ Transport Key + inner-layer |
| **Laser Fault Injection** | ❌ Yok | ✅ 4x Photodiode mesh |
| **Post-Quantum hazırlık** | ❌ Yok | ✅ Kyber-768 mimari hazır |
| **AT Whitelist** | Basit prefix | ✅ Exact match + sanitize |
| **UART Flood koruması** | ❌ Yok | ✅ RTS/CTS + rate limit |
| **DMA enforcement** | Yazılımsal | ✅ MPU + Firewall + RCC gate |
| **PDN izolasyonu** | Ortak hat | ✅ 4 bağımsız güç alanı |
| **Anti-Starbleed** | Sadece eFUSE | ✅ JTAG cut + ICAP off + epoksi |
| **Anti-Rollback** | ❌ Yok | ✅ eFUSE SVN (32 güncelleme) |
| **MAD Heartbeat** | GPIO toggle | ✅ HMAC challenge-response |
| **GaN Dead-Time** | Yazılımsal | ✅ HW interlock (74LVC2G14) |
| Blind Boot koruması | ❌ Yok | ✅ DONE pin AND gate |
| FPGA kaynak kullanımı | ~%1 | ~%6 (hâlâ %94 boş) |
| Toplam RTL satırı | ~800 | ~2,264 (+1,464) |
| Toplam tetik kaynağı | 4 | 12 |
| Saldırı matrisi kapsamı | ~10 | **27 (Red Team doğrulanmış)** |
| Test sayısı | ~10 | ~41 |
| CI/CD framework | ❌ Yok | ✅ cosim_framework.py |
| Güvenlik BOM | ~$47 | ~$68 (+$21 yeni korumalar) |

---

## 11. Post-Quantum Hazırlık ★ V14.1 YENİ ★

### 11.1 Mevcut Durum: AES-256 Kuantum Güvenliği

AES-256, kuantum bilgisayarlara karşı **hâlâ güvenli** kabul edilir:

| Algoritma | Klasik Güvenlik | Kuantum Güvenlik (Grover) | Durum |
|-----------|:--------------:|:------------------------:|:-----:|
| AES-256 | 256-bit | 128-bit | ✅ Güvenli |
| AES-128 | 128-bit | 64-bit | ⚠️ Risk |
| RSA-2048 | 112-bit | 0-bit (Shor) | ❌ Kırılır |
| ECC P-256 | 128-bit | 0-bit (Shor) | ❌ Kırılır |

**TITAN'ın şifreleme motoru AES-256 → kuantum saldırıya doğrudan dirençli.**

### 11.2 Açık: Anahtar Değişimi

AES-256 simetrik bir algoritmadır — her iki taraf da anahtarı bilmelidir. Mevcut anahtar değişim yöntemleri (ECDH, RSA) kuantum bilgisayarla kırılır. Çözüm: **NIST PQC Standard — CRYSTALS-Kyber-768**.

### 11.3 Kyber-768 FPGA Implementasyon Planı

| Parametre | Değer |
|-----------|-------|
| Algoritma | CRYSTALS-Kyber-768 (NIST FIPS 203) |
| Güvenlik seviyesi | NIST Level 3 (AES-192 eşdeğeri) |
| Anahtar boyutu | Pubkey: 1,184 B, Ciphertext: 1,088 B |
| İşlem | Key Encapsulation Mechanism (KEM) |

**Tahmini FPGA kaynak kullanımı:**

| Kaynak | Kyber-768 İhtiyacı | Mevcut Boş | Uyumluluk |
|--------|:-----------------:|:----------:|:---------:|
| LUT | ~8,000−15,000 | ~59,900 | ✅ %13−25 |
| FF | ~4,000−8,000 | ~124,300 | ✅ %3−6 |
| BRAM | ~4−8 | 133 | ✅ %3−6 |
| DSP48 | ~2−4 (NTT butterfly) | 240 | ✅ %1−2 |

**Artix-7 XC7A100T, AES-256 + AEGIS + Kyber-768'i barındırmak için yeterli kapasiteye sahiptir.** Toplam kullanım ~%25'te kalır.

### 11.4 Entegrasyon Mimarisi

```
┌──────────────────────────────────────────────────────────┐
│                    FPGA (Artix-7)                         │
│                                                          │
│  ┌─────────────┐   ┌─────────────┐   ┌──────────────┐   │
│  │ Kyber-768   │   │ AES-256-CTR │   │ AEGIS        │   │
│  │ KEM Engine  │──→│ Engine      │──→│ Omega Cloak  │   │
│  │             │   │             │   │ PVT Monitor  │   │
│  │ Shared Key  │   │ Data Enc    │   │ Kill Chain   │   │
│  └─────────────┘   └─────────────┘   └──────────────┘   │
│        ↑                                                 │
│        │ Key Exchange                                    │
│        ↓                                                 │
│  ┌─────────────┐                                         │
│  │ TRNG        │ → Kyber randomness kaynağı              │
│  │ (3x Ring Osc)│                                        │
│  └─────────────┘                                         │
└──────────────────────────────────────────────────────────┘
```

**Akış:**
1. Kyber-768 KEM → 256-bit shared secret üretir
2. Shared secret → AES-256 anahtarı olarak kullanılır
3. AES-256-CTR ile veri şifrelenir
4. Tüm işlemler AEGIS koruması altında (DPA, kill chain, PVT)

### 11.5 Zaman Çizelgesi

| Faz | Süre | Durum |
|-----|------|:-----:|
| Mimari planlama | — | ✅ Tamamlandı (bu bölüm) |
| VHDL RTL geliştirme | ~8-12 hafta | ⏳ Planlandı |
| NTT (Number Theoretic Transform) IP | ~4 hafta | ⏳ Planlandı |
| Sentez + zamanlama doğrulama | ~2 hafta | ⏳ Planlandı |
| NIST KAT vektör testi | ~2 hafta | ⏳ Planlandı |
| AEGIS entegrasyonu (Omega Cloak for Kyber) | ~2 hafta | ⏳ Planlandı |

---

## 12. Callwhite Hücresel Modül Entegrasyonu (V15)

### 12.1 Genel Bakış

Callwhite, TITAN V14 BLACK UART çıkışını 4G/LTE hücresel ağa bağlayan bağımsız iletişim modülüdür. STM32L476 MCU köprüsü ile Quectel EC25-E modem kontrol edilir.

```
FPGA (BLACK UART) ←→ STM32L4 MCU ←→ EC25-E Modem ←→ 4G/LTE
     921600 baud      CTS/RTS         AT Komutları       Anten
```

### 12.2 FPGA Değişiklikleri

**uart_driver.vhd — CTS/RTS Akış Kontrolü:**
- `cts_n` (in, default '0'): MCU buffer doluyken TX'i durdurur
- `rts_n` (out): Backpressure sinyali (top-level'da blk_tx_busy'ye bağlı)
- Geriye uyumlu: `cts_n` varsayılan '0' → RED UART etkilenmez

**artix7_top_v14.vhd — BLACK UART Güncelleme:**
- Baud rate: 115200 → 921600 (MCU HSE kristal gerektirir)
- CTS/RTS pinleri: `BLACK_UART_CTS_PIN` (N14), `BLACK_UART_RTS_PIN` (P14)
- RTS mantığı: `BLACK_UART_RTS_PIN <= blk_tx_busy`

### 12.3 Rust COBS Framing (hidra_net)

TCP stream'de paket sınırı belirleme:
- `hidra_net::cobs::encode()` — 0x00-free stream üretir
- `hidra_net::cobs::decode()` — frame recovery
- Overhead: ~%1 (254 byte'da 1 byte)
- 9 unit test + 1 doc-test ile doğrulanmış

### 12.4 RF Zinciri

```
Anten → GDT → TVS1 → RF Switch (SKY13351) → SAW → TVS2 → LNA → EC25
                         ↓ TX path (bypass)
```

- Link budget: 34.2 dB margin (10 km, 1800 MHz)
- 3 katmanlı surge koruma (GDT + TVS1 + TVS2)
- LNA TX koruması: RF switch ile yol ayrımı

### 12.5 Entegrasyon Durumu

```
ŞU ANKİ DURUM:
  FPGA ←──kablo──→ FPGA              ✅ Çalışıyor (şifreli kablolu iletişim)

HEDEF:
  FPGA ←──MCU──→ Modem ←──4G──→ İnternet ←──→ Karşı TITAN
       921600     CTS/RTS   AT+TCP          MQTT mesh
```

| Katman | Bileşen | Durum |
|--------|---------|:-----:|
| **FPGA RTL** | BLACK UART 921600 + CTS/RTS | ✅ Hazır |
| **FPGA RTL** | AES-256 + Kill Chain + AEGIS | ✅ Çalışıyor |
| **Rust SW** | COBS framing (hidra_net) | ✅ Hazır |
| **Rust SW** | MQTT mesh / Tor / Decoy | ✅ Çalışıyor |
| **Donanım** | STM32L476 MCU (köprü) | 🔴 Üretilecek |
| **Donanım** | Quectel EC25-E modem | 🔴 Tedarik edilecek |
| **Donanım** | Anten + LNA + RF switch | 🔴 Tedarik edilecek |
| **Donanım** | 4 katman PCB (RF izolasyon) | 🔴 Tasarlanacak |
| **Firmware** | STM32 AT engine + TCP + SIM | 🔴 Yazılacak |
| **Donanım** | Li-Po + güç yönetimi | 🔴 Entegre edilecek |

### 12.6 Üretim Yol Haritası

| Faz | Süre | Çıktı |
|-----|------|-------|
| Faz 1: Breadboard prototip | 1-2 hafta | Nucleo + EC25 breakout + ilk 4G bağlantı |
| Faz 2: PCB tasarımı | 2-3 hafta | KiCad şematik + 4 katman layout |
| Faz 3: Entegrasyon | 1-2 hafta | SMD montaj + firmware + saha testi |
| Faz 4: Kasa + ürünleştirme | 2-4 hafta | 3D baskı + batarya + final test |

> [!IMPORTANT]
> Tahmini toplam maliyet: **~$333-345** (BOM $298 + PCB $15-30 + Kasa $20)

### 12.7 MCU Köprüsü (STM32L476RGT6)

FPGA ile modem arasında protokol çevirisi yapan köprü işlemci.

```
FPGA (BLACK UART)           STM32L476             EC25-E Modem
  ┌────────────┐         ┌──────────────┐        ┌──────────┐
  │ tx_pin ────────────► │ USART1 RX    │        │          │
  │ rx_pin ◄──────────── │ USART1 TX    │        │          │
  │ CTS_PIN ◄──────────  │ GPIO (CTS)   │        │          │
  │ RTS_PIN ──────────►  │ GPIO (RTS)   │        │          │
  └────────────┘         │              │        │          │
      921600 baud        │ USART2 TX ──────TXB── │ UART RX  │
      3.3V direkt        │ USART2 RX ◄────TXB── │ UART TX  │
                         │ PA1 (RTS) ──────TXB── │ RTS      │
                         │ PA0 (CTS) ◄────TXB── │ CTS      │
                         │              │ 0104   │          │
                         │ PC0  → PWRKEY──────── │ PWRKEY   │
                         │ PC3  → RESET_N─────── │ RESET_N  │
                         │ PC1  ← STATUS ◄────── │ STATUS   │
                         │ PC2  ← NETLIGHT ◄──── │ NETLIGHT │
                         │ PC9  → LDO EN ──────► │ 4.0V     │
                         └──────────────┘        └──────────┘
```

**Neden STM32L476:**
- Ultra-low-power (~30mA aktif, 2µA standby)
- Dual-bank flash (512KB × 2) → güvenli OTA firmware update
- Donanım AES + RNG (SBSFU secure boot)
- LQFP-64 → elle lehimlenebilir prototip için uygun
- RDP Level 2 → üretimde geri dönüşümsüz koruma

**Ek Pinler:**
| Pin | Görev |
|-----|-------|
| PA4 (ADC) | Batarya voltaj ölçüm |
| PA5 (ADC) | Li-Po NTC sıcaklık |
| PA6 (ADC) | Modem NTC sıcaklık |
| PA7 (EXTI) | Modem RI (Ring Indicator) |
| PA8 | Modem DTR (deep sleep) |
| PB6/PB7 (I2C) | OLED SSD1306 |
| PB0-PB7 (GPIO) | 4×4 tuş matrisi |
| PC5/PC6 | Reed/Limit switch (tamper) |
| PC7/PC8 | TPL5010 watchdog (WAKE/DONE) |
| PC10 | Recovery button |
| PC11 | SIM Card Detect |
| PC12 | Modem W_DISABLE# |
| PC13 | FPGA kill_signal |
| PD1 (UART4) | Debug test pad |
| PB12-15 (SPI2) | W25Q16 OTA staging flash |

### 12.8 4G Modem (Quectel EC25-E)

**Spesifikasyon:**
- LTE Cat 4: 150 Mbps DL / 50 Mbps UL
- Bantlar: B1/B3/B7/B8/B20 (Türkiye + Avrupa tam uyumlu)
- UART: 115200 varsayılan → 921600 yapılandırılabilir
- Güç: 3.3-4.3V, tipik 250mA, pik 2A (TX burst)
- Sıcaklık: -40°C ~ +85°C
- 3 anten portu: MAIN (TX/RX), DIV (RX only), GNSS

**Güvenlik Önlemleri:**
- AT komut whitelisting (STM32 firmware'de filtreleme)
- DMA devre dışı — modem UART DMA kullanmaz (buffer overflow koruması)
- Ayrı güç domaini — MIC29302 LDO ile MCU'dan bağımsız açma/kapama
- W_DISABLE# pini ile RF acil kapatma

**Modem Kontrol Sırası:**
```
T+0ms:   MCU boot → FPGA SPI handshake
T+150ms: PC9 HIGH → MIC29302 ENABLE → 4.0V ON
T+200ms: PC0 HIGH → PWRKEY 500ms pulse
T+700ms: PC0 LOW → modem boot başlar
T+2000ms: AT+CFUN=1 → hücresel kayıt
T+5000ms: AT+CREG? → ağ kaydı tamamlandı
```

### 12.9 Anten + RF Zinciri

```
Baz İstasyonu ──► Yagi 12 dBi ──► SMA ──► GDT (90V) ──► TVS1 (5V)
                                                              │
                    ┌── TX path (direkt) ◄───── RF Switch ◄───┘
                    │                         (SKY13351)
                    │   RX path ──► SAW (1800MHz) ──► TVS2 (3.3V) ──► LNA (+15dB)
                    │                                                      │
                    └──────────────────────── EC25 MAIN ANT ◄──────────────┘
```

**Bileşen Detayları:**

| Bileşen | Model | Görev |
|---------|-------|-------|
| RF Switch | SKY13351-378LF | TX/RX yol ayrımı, LNA koruması |
| SAW Filtre | Murata SAFFB1G84 | B3 1800MHz bant seçici |
| LNA | SKY67151-396LF | +15 dB kazanç, NF <1 dB |
| GDT | Bourns 2027-09-CLF | Yıldırım/surge (90V, 5kA) |
| TVS1 | PESD5V0U1UA | Kaba ESD (5V clamp, <0.5pF) |
| TVS2 | PESD3V3U1UA | İnce LNA koruma (3.3V, <0.2pF) |
| Anten (Main) | Yagi 800-2600MHz | 12 dBi, SMA bağlantılı |
| Anten (DIV) | PCB dipole | 3 dBi, multipath diversity |
| Kablo | LMR-195 | 0.6 dB/m @ 1800MHz |

**Link Budget:**
```
TX gücü (baz):    +43 dBm
Path loss (10km): -138 dB
Anten:            +12 dB
Kablo (3m):       -1.8 dB
GDT+TVS:          -0.2 dB
RF Switch:         -0.3 dB
SAW:               -1.5 dB
LNA:              +15 dB
═══════════════════════
Alıcı gücü:       -71.8 dBm
EC25 hassasiyeti:  -106 dBm
Margin:            +34.2 dB ✅
```

### 12.10 PCB Tasarımı

```
┌───────────────────────────────────────────────────┐
│    RED ZONE              ║ MOAT ║    BLACK ZONE   │
│                          ║      ║                 │
│  FPGA (RED UART tarafı)  ║ GND  ║  EC25 Modem    │
│  Keypad (4x4)            ║ cut  ║  SMA Anten     │
│  OLED Ekran              ║ 5mm  ║  LNA + RF SW   │
│  Batarya                 ║      ║  SIM Slot      │
│                          ║      ║                 │
│        ┌──────────┐      ║      ║                 │
│        │ STM32    │─────║─UART─║──── (TXB0104)   │
│        │ MCU      │      ║ ONLY ║                 │
│        └──────────┘      ║      ║                 │
└──────────────────────────║──────║─────────────────┘
```

**Spesifikasyon:**
- 4 katman: TOP / GND / POWER / GND
- Boyut: 10×8 cm
- RF izolasyon gap: ≥15mm (FPGA ↔ modem)
- RED/BLACK moat: 5mm bakır boşluk (dört katmanda)
- Modem altı termal pad + 5×5 via array
- SIM slot tamper bölgesi içinde (kapak açılırsa kill)

### 12.11 MCU Firmware Mimarisi

```
firmware/
├── main.c              — FreeRTOS init, task'lar
├── uart_fpga.c/.h      — FPGA UART + DMA ring buffer (921600)
├── uart_modem.c/.h     — Modem UART + RTS/CTS
├── at_engine.c/.h      — AT komut state machine
├── tcp_session.c/.h    — TCP soket yönetimi
├── cobs_framing.c/.h   — COBS encode/decode (Rust ile simetrik)
├── sim_manager.c/.h    — SIM detect, PIN, voltaj
├── band_config.c/.h    — Band/operatör kilidi, 2G fallback
├── jamming_detect.c/.h — RSSI anomali tespiti
├── modem_thermal.c/.h  — AT+QTEMP izleme, throttle
├── modem_monitor.c/.h  — STATUS/NETLIGHT/RI pin izleme
├── display.c/.h        — OLED SSD1306 driver
├── keypad.c/.h         — 4×4 tuş tarama
├── power.c/.h          — Batarya, güç yönetimi, PVD
├── thermal.c/.h        — Li-Po + modem NTC izleme
├── tamper.c/.h         — Reed/Limit switch → kill
├── secure_boot.c/.h    — SBSFU: ECDSA-P256 doğrulama
├── watchdog_ext.c/.h   — TPL5010 harici watchdog
├── spi_flash.c/.h      — W25Q16 OTA staging
├── debug_log.c/.h      — Kara kutu event ring buffer
└── config.h            — IP, APN, port, band, timeout
```

**Güvenlik:** MCU sadece şifreli veri görür — açık metin FPGA'dan hiç çıkmaz. MCU kompromize olsa bile sadece ciphertext sızar.

### 12.12 Güç Sistemi

```
Li-Po 3.7V 5000mAh
    │
    ├──► TP4056 Şarj IC (USB-C)
    │
    ├──► MIC29302 LDO → 4.0V @ 3A → EC25 Modem
    │        ENABLE ← STM32 PC9 (power sequencing)
    │        + 1000µF + 10×100nF cap bank
    │
    ├──► AP2112K-3.3 ULDO → 3.3V → STM32 + OLED + Tuşlar
    │
    ├──► [Schottky] → [0.47F Supercap] → MCU + FPGA 3.3V
    │        (Last gasp: pil kesilince ~700ms graceful shutdown)
    │
    └──► MT3608 Boost → 5.0V → Arty A7 (prototip)
         Üretim: TPS62080 Buck → 1.0V/1.8V/3.3V (bare FPGA)
```

**Pil Ömrü (FPGA dahil):**

| Mod | Toplam | Süre |
|-----|--------|------|
| Standby | ~300mA | ~16 saat |
| Aktif iletişim | ~600mA | ~8 saat |
| MCU Sleep + Modem PSM | ~260mA | ~19 saat |

> [!NOTE]
> Detaylı Callwhite planı: `docs/Callwhite_Cellular_Module_Plan.md`

---

## 13. V14.2 Mimari Güçlendirme ★ YENİ ★

V14.2 güncellemesi ile 5 yeni güvenlik modülü eklenerek kalan mimari boşluklar kapatılmıştır:

### 13.1 2nd-Order DOM Masked S-Box

| Parametre | Değer |
|-----------|-------|
| Dosya | `aes_sbox_masked_2nd.vhd` |
| Maskeleme Seviyesi | 2nd-Order Domain-Oriented Masking |
| Mask Payları | `mask_a` + `mask_b` (bağımsız, TRNG kaynaklı) |
| Doğrulama | 1280 check (256 giriş × 5 mask çifti), GHDL PASS |
| CPA Direnci | 1st-order → 2nd-order: 2. ve 3. istatistiksel momentler korunur |

**Etki**: 1st-order DOM sadece 1. momentte korelasyonu kırar. 2nd-order DOM, 2 bağımsız mask payı ile **t-test leakage detection**'da bile sızan bilgiyi sıfırlar.

### 13.2 SEU Configuration Memory Scrubber

| Parametre | Değer |
|-----------|-------|
| Dosya | `seu_scrubber.vhd` |
| Xilinx Primitive | FRAME_ECCE2 (7-Series ECC) |
| Tarama Periyodu | Her 1M clock cycle (~20ms @ 50MHz) |
| Single-Bit Error | Otomatik düzeltme + sayaç artırma |
| Multi-Bit Error | `kill_out` assertion (geri dönüşümsüz) |
| Simülasyon | FSM wrapper (GHDL uyumlu), 5/5 test PASS |

**Etki**: Kozmik ışınlar veya kasıtlı radyasyon ile oluşan bitflip'ler algılanır ve düzeltilir. Çoklu hata → kill chain tetiklenir.

### 13.3 Extended SVN Counter (Hash Chain)

| Parametre | Değer |
|-----------|-------|
| Dosya | `svn_extended.vhd` |
| Mekanizma | BRAM-backed SHA-256 hash chain |
| Formül | `new_hash = SHA-256(old_hash ∥ new_counter)` |
| Kapasite | Sınırsız (eFUSE 32-bit sınırını aşar) |
| Rollback Tespiti | Beklenen hash ≠ saklanan hash → `rollback_kill` |
| Doğrulama | 5/5 GHDL test PASS (genesis, increment, mismatch) |

**Etki**: eFUSE'nun 32-bit güncelleme sınırı ortadan kalkar. Her yeni versiyon bir öncekinin hash'ine bağlı → tek yönlü zincir.

### 13.4 Radio Silence Mode

| Parametre | Değer |
|-----------|-------|
| Dosya | `radio_silence.h` (MCU firmware) |
| Mekanizma | GaN FET ile modem güç kesme (donanımsal RF kill) |
| Aktifleştirme | Keypad `*#7370#` veya yazılımsal API |
| Fallback | LoRa / Iridium stub'ları (gelecek entegrasyon) |
| Takip | Kümülatif sessiz süre sayacı |

**Etki**: Modem konum sızıntısı (cell tower triangulation, IMSI catcher) **donanım seviyesinde** engellenir. RF devre tamamen ölür.

### 13.5 Backside Attack Protection

| Parametre | Değer |
|-----------|-------|
| Dosya | `backside_shield.h` (MCU firmware) |
| Sensör | STM32 TSC (Touch Sensing Controller) |
| Ölçüm | BGA substrat kapasitansı (pF) |
| Kalibrasyon | Fabrika referans değeri (EMA) |
| Alarm Eşiği | ±%5 sapma → uyarı, ±%15 → kill |

**Etki**: FIB (Focused Ion Beam) arka yüz saldırısı, BGA substratının kapasitans profilini değiştirir. Bu değişim TSC ile algılanır → kill.

### 13.6 V14.2 Doğrulama Durumu

| Test | Sonuç |
|------|:-----:|
| 2nd-Order DOM S-Box (1280 check) | ✅ PASS |
| SEU Scrubber FSM (5 test) | ✅ PASS |
| SVN Extended Counter (5 test) | ✅ PASS |
| **Toplam Regresyon** | **17/17 PASS** |

---

*Bu döküman TITAN V14 sisteminin tüm katmanlarını —fiziksel donanımdan FPGA firmware'ine, analog watchdog'lardan post-quantum hazırlığa, V14.2 mimari güçlendirmesine— tek bir referans noktasında birleştirir. 58 VHDL modülü, 49 MCU firmware modülü ve 27 saldırı vektörünün tamamı kapsam altındadır.*

**© 2026 PROJECT TITAN — Tüm Hakları Saklıdır**

