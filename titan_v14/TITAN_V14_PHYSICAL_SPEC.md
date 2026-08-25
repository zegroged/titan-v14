# TITAN V14 — Physical Hardware Specification

**Version**: 14.0 (Artix-7 Implementation)
**Date**: 2026-02-22
**Status**: Bitstream Generated — Awaiting Board Test
**Bitstream**: titan_v14.bit (2,836,989 bytes)

---

## 1. System Overview

TITAN V14, devlet düzeyindeki tehditlere karşı tasarlanmış donanım tabanlı şifreli iletişim terminalidir. Tüm kriptografik işlemler FPGA silikon seviyesinde gerçekleştirilir — yazılım katmanına hiçbir anahtar veya plaintext sızmaz.

### 1.1 Temel Tasarım İlkeleri
- **Zero-Trust Architecture**: Yazılıma güvenme, donanıma güven
- **Volatile Key Only**: Anahtar sadece flip-flop'larda yaşar, kalıcı bellek kullanılmaz
- **Kill-or-Leak**: Tehdit algılandığında 20ns içinde zeroization
- **Defense-in-Depth**: 4 katmanlı AEGIS koruma sistemi

---

## 2. Target FPGA Platform

### 2.1 Primary: Xilinx Artix-7 (Mevcut Implementation)

| Parametre | Değer |
|-----------|-------|
| Part Number | xc7a100tcsg324-1 |
| Logic Cells | 101,440 |
| Block RAM | 4,860 Kb |
| DSP Slices | 240 |
| I/O Pins | 210 |
| Speed Grade | -1 (Commercial) |
| Package | CSG324 (15mm × 15mm BGA) |
| Process | TSMC 28nm |
| Dev Board | Digilent Arty A7-100T |

### 2.2 Auditor: Microchip PolarFire (Gelecek Evrim)

| Parametre | Değer |
|-----------|-------|
| Part Number | MPF100T-FCVG484 |
| Logic Elements | 108,600 |
| Process | UMC 28nm Flash-based |
| Rad-Hard | SEU immune (Flash config) |
| Role | Watchdog auditor |

### 2.3 Logic Wall (Discrete Comparison — Gelecek Evrim)
- 33× 74HC688 (8-bit Magnitude Comparators)
- Chip Diversity: TI + NXP + Toshiba interleaved
- Voting Logic: 74HC11 (Triple AND Gate)
- Any 1-bit mismatch → physical KILL line

---

## 3. Clock Architecture

### 3.1 External Clock
- **Source**: SiTime SiT5356 MEMS Oscillator, 100 MHz
- **Prescaler**: 74VHC74 D-Type Flip-Flop → 50 MHz
- **Routing**: Length-matched traces (±50ps skew max)

### 3.2 Internal Clocking (Artix-7)
- **MMCME2_BASE**: Direct primitive instantiation (no Clocking Wizard)
- **VCO**: 1000 MHz (50 MHz × 20)
- **CLKOUT0**: 50 MHz system clock
- **BUFG Feedback**: Zero-delay buffer for minimal I/O skew
- **PLL_LOCKED**: Critical heartbeat — loss = immediate tamper event

### 3.3 Clock Constraints (XDC)
```tcl
create_clock -period 20.000 -name ext_clk [get_ports ext_clk]
set_property IOSTANDARD LVCMOS33 [get_ports ext_clk]
set_property PACKAGE_PIN E3 [get_ports ext_clk]
```

---

## 4. Resource Utilization (Post-Route)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUT | ~18,000 | 63,400 | ~28% |
| FF | ~22,000 | 126,800 | ~17% |
| BRAM | ~12 | 135 | ~9% |
| DSP | 0 | 240 | 0% |
| MMCM | 1 | 6 | 17% |
| IO | ~6 | 210 | ~3% |

### 4.1 Timing Summary
- **WNS (Setup)**: +0.239 ns (MET)
- **WHS (Hold)**: +0.052 ns (MET)
- **Failed Nets**: 0
- **DRC Errors**: 0

---

## 5. Module Architecture

### 5.1 Kriptografi Modülleri

| Modül | Dosya | İşlev |
|-------|-------|-------|
| AES-256-CTR | `aes256_core.vhd` | 14-round şifreleme motoru |
| AES S-Box | `aes_sbox.vhd` | Temel S-Box lookup |
| AES S-Box Masked | `aes_sbox_masked.vhd` | DOM (d+1) maskelemeli S-Box |
| AES S-Box 2nd-Order | `aes_sbox_masked_2nd.vhd` | 2nd-Order DOM maskelemeli S-Box |
| AES Key Expand | `aes_key_expand.vhd` | 15 round key üretimi |
| AES Round | `aes_round.vhd` | SubBytes/ShiftRows/MixColumns |
| SHA-256 | `sha256_core.vhd` | NIST FIPS 180-4 uyumlu hash |
| HMAC-SHA256 | `hmac_sha256.vhd` | RFC 4231 uyumlu MAC |
| Secure Key Storage | `secure_key_storage.vhd` | 1920-bit FF tabanlı anahtar deposu |
| AES Core Wrapper | `aes_core_wrapper.vhd` | AES motor sarmalayıcı |

### 5.2 Güvenlik Modülleri

| Modül | Dosya | İşlev |
|-------|-------|-------|
| Kill Protocol | `kill_protocol.vhd` | 14 kaynaklı zeroization (<1 cycle) |
| Watchdog (MAD) | `watchdog_monitor.vhd` | Karşılıklı heartbeat izleme |
| Glitch Detector | `glitch_detector.vhd` | Voltaj/clock saldırı algılama |
| POST Self-Test | `post_self_test.vhd` | FIPS 140-3 boot doğrulama |
| Firmware Integrity | `firmware_integrity.vhd` | SHA-256 config hash kontrolü |
| System Supervisor | `system_supervisor.vhd` | Boot sequence + PLL lock yönetimi |
| HMAC Heartbeat | `hmac_heartbeat_ctrl.vhd` | HMAC tabanlı heartbeat kontrolörü |
| PF HMAC Responder | `pf_hmac_responder.vhd` | PolarFire HMAC yanıt modülü |
| SEU Scrubber | `seu_scrubber.vhd` | FRAME_ECCE2 yapılandırma belleği koruması |
| SVN Extended | `svn_extended.vhd` | BRAM-backed hash chain anti-rollback |

### 5.3 AEGIS Side-Channel Koruması

| Modül | Dosya | İşlev |
|-------|-------|-------|
| Omega Cloak | `omega_cloak_top.vhd` | Kaotik dummy round injection |
| Clock Jitter | `clock_jitter_injector.vhd` | Güç analizi bozucu |
| Chaotic PRNG | `chaotic_prng.vhd` | Logistic map tabanlı rastgelelik |
| ESN Reservoir | `esn_reservoir_core.vhd` | Echo State Network anomali tespiti |
| ESN Readout | `esn_readout.vhd` | ESN çıkış hesaplayıcı |
| ESN Weight Pkg | `esn_weight_pkg.vhd` | ESN ağırlık sabitleri |
| Ring Osc Counter | `ring_osc_counter.vhd` | PVT sensörü + entropi kaynağı |
| PVT Monitor | `pvt_monitor_top.vhd` | Sıcaklık/voltaj anomali takibi |
| Anomaly Detector | `anomaly_detector.vhd` | AXI-S pipeline anomali sınıflandırıcı |
| Dummy Op Injector | `dummy_op_injector.vhd` | Sahte operasyon enjektörü |
| Shift-Add Mult | `shift_add_multiplier.vhd` | DSP-free çarpma |
| Tanh LUT | `tanh_lut_rom.vhd` + `tanh_lut_pkg.vhd` | ESN aktivasyon fonksiyonu |

### 5.4 İletişim Modülleri

| Modül | Dosya | İşlev |
|-------|-------|-------|
| TRNG | `trng_wrapper.vhd` + `trng_ring_osc.vhd` | 3× ring oscillator + DRBG fallback |
| SPI Key Loader | `key_loader_spi.vhd` | Volatile key injection (split-key) |
| SPI Key Unwrap | `spi_key_unwrap.vhd` | AES-wrapped key açma |
| SPI Cmd Slave | `spi_cmd_slave.vhd` | SPI komut protokolü |
| Comm Protocol | `comm_protocol.vhd` | Full-duplex UART + AES arb |
| Data Gearbox | `data_gearbox.vhd` | Byte→128-bit PKCS#7 padding |
| UART Telemetry | `uart_telemetry.vhd` | Debug/telemetri çıkışı |
| UART Driver | `uart_driver.vhd` | Temel UART TX/RX sürücü |

---

## 6. Pin Assignment (Arty A7-100T)

### 6.1 Clock & Reset
| Signal | Pin | Standard | Not |
|--------|-----|----------|-----|
| ext_clk | E3 | LVCMOS33 | 100 MHz onboard oscillator |
| reset_n | — | — | Internal POR |

### 6.2 UART (RED — PC Haberleşme)
| Signal | Pin | Standard | Not |
|--------|-----|----------|-----|
| UART_RX_PIN | A9 | LVCMOS33 | USB-UART bridge |
| UART_TX_PIN | D10 | LVCMOS33 | USB-UART bridge |

### 6.3 UART Telemetry (Legacy)
| Signal | Pin | Standard | Not |
|--------|-----|----------|-----|
| UART_TX_PAD | D4 | LVCMOS33 | Debug telemetry |

### 6.4 BLACK UART (Şifreli Kanal)
| Signal | Pin | Standard | Not |
|--------|-----|----------|-----|
| BLACK_UART_TX_PIN | C4 | LVCMOS33 | Ciphertext çıkış |
| BLACK_UART_RX_PIN | D3 | LVCMOS33 | Ciphertext giriş |

### 6.5 SPI Key Injection
| Signal | Pin | Standard | Not |
|--------|-----|----------|-----|
| SPI_CLK_PIN | — | LVCMOS33 | PMOD connector |
| SPI_MOSI_PIN | — | LVCMOS33 | PMOD connector |
| SPI_CS_N_PIN | — | LVCMOS33 | PMOD connector |

### 6.6 AEGIS / PVT (V14 Eklentileri)
| Signal | Pin | Standard | Not |
|--------|-----|----------|-----|
| RING_OSC_IN[0] | T14 | LVCMOS33 | PVT ring osc input |
| RING_OSC_IN[1] | T15 | LVCMOS33 | PVT ring osc input |
| RING_OSC_IN[2] | U14 | LVCMOS33 | PVT ring osc input |
| RING_OSC_IN[3] | R13 | LVCMOS33 | PVT ring osc input |
| OMEGA_ENABLE_PIN | L16 | LVCMOS33 | DIP switch |
| AEGIS_ENABLE_PIN | M13 | LVCMOS33 | DIP switch |

---

## 7. Floorplanning

### 7.1 Artix-7 Pblock Layout
```
┌──────────────────────────────────────┐
│  KILL_ZONE (I/O Bank proximity)      │
│  kill_protocol, glitch_detector      │
│  Slice: X0Y0 – X15Y49               │
├──────────────────────────────────────┤
│  CRYPTO_ZONE                         │
│  aes256_core, sha256, hmac,          │
│  secure_key_storage                  │
│  Slice: X16Y0 – X49Y49              │
├──────────────────────────────────────┤
│  AEGIS_ZONE                          │
│  omega_cloak, pvt_monitor,           │
│  ring_osc_counter, esn_reservoir     │
│  Slice: X0Y50 – X49Y99              │
├──────────────────────────────────────┤
│  COMM_ZONE                           │
│  comm_protocol, uart, spi,           │
│  data_gearbox, trng                  │
│  Slice: X50Y0 – X65Y99              │
└──────────────────────────────────────┘
```

### 7.2 Floorplan Tasarım İlkeleri
- KILL logic I/O pad'lerine en yakın konumda → fiziksel matkap saldırısı savunması
- Crypto zone merkeze yerleştirilir → EM emanasyon minimizasyonu
- AEGIS zone crypto'ya bitişik → side-channel koruması fiziksel yakınlık gerektirir
- Ring oscillator'lar birbirinden uzak → entropi bağımsızlığı

---

## 8. PCB Design Requirements

### 8.1 Katman Yapısı
- **Minimum**: 6 katman (Signal-GND-Signal-Signal-GND-Signal)
- **İdeal**: 12 katman HDI
- **Grounding**: Star ground topology

### 8.2 Güç Dağıtımı
| Rail | Voltaj | Kaynak | Tüketim |
|------|--------|--------|---------|
| VCCINT | 1.0V | LDO regulator | ~500mA |
| VCCAUX | 1.8V | LDO regulator | ~100mA |
| VCCO (Bank 14,34) | 3.3V | LDO | ~50mA |
| VCC5V0 | 5.0V | USB | Input |

### 8.3 EMI/Fiziksel Koruma
- **Kaplama**: MG Chemicals 832HD Black Epoxy (anti-X-ray)
- **Kalkan**: Mu-Metal (manyetik) + Copper Mesh (RF)
- **Tamper mesh**: PCB üzerinde kesme teli → KILL tetikleyici

---

## 9. Sequential Destruction Protocol (The Reaper)

### 9.1 Elektronik Zeroization (T+0)
- KILL assertion → tüm FF'ler async clear/preset
- AES key = 0x000...000
- SHA state = 0x000...000
- Session counter = 0
- **Süre**: <20ns (1 clock cycle @ 50 MHz)

### 9.2 Güç Kesme (T+150ns)
- GaN Systems GS61008P transistor modem gücünü keser
- Veri sızıntısını önler

### 9.3 Fiziksel İmha (T+10ms — Gelecek Evrim)
- Omron G6D-1A-ASI röle
- 1000V kapasitör bankası → RAM/Flash VCC hatlarına deşarj
- Silikon die'ları fiziksel olarak parçalar

---

## 10. Bill of Materials (BOM) — Geliştirme Aşaması

### 10.1 Temel Gereksinimler (Şimdi Alınacak)

| Parça | Model | Fiyat (USD) | Not |
|-------|-------|-------------|-----|
| FPGA Dev Board | Digilent Arty A7-100T | ~$130 | Ana geliştirme kartı |
| USB-SPI Adapter | Adafruit FT232H | ~$15 | SPI key injection |
| Logic Analyzer | Saleae Logic 8 | ~$45 | Debug/doğrulama |
| Breadboard + Jumper | — | ~$10 | Bağlantı |
| USB Cable (Micro-B) | — | ~$5 | Kart bağlantısı |
| **TOPLAM** | | **~$205** | |

### 10.2 İleri Test Donanımı (Opsiyonel)

| Parça | Model | Fiyat (USD) | Not |
|-------|-------|-------------|-----|
| Side-Channel Kit | ChipWhisperer Pro | ~$300 | CPA saldırı testi |
| Oscilloscope | Rigol DS1054Z | ~$350 | Analog sinyal analizi |
| EM Probe | Langer EMV | ~$200 | EM emanasyon testi |
| Thermal Chamber | — | ~$2,000+ | -40°C to +85°C testi |

### 10.3 Üretim BOM (Gelecek Fazlar)

| Kategori | Bileşenler | Not |
|----------|-----------|-----|
| Logic Wall | 33× 74HC688 + 74HC11 | Discrete comparison |
| Clock Distribution | SiTime SiT5356 + 74VHC74 | MEMS oscillator |
| Analog Watchdogs | LM2907N-8, REF3325, LTC1540 | F-to-V + comparator |
| Phase Detector | 74VHC86 + RC filter | XOR + leaky bucket |
| Destruction | GS61008P + G6D-1A-ASI + cap bank | Sequential reaper |
| PCB | 12-layer HDI, mu-metal shield | Custom design |
| Enclosure | CNC aluminum + tamper mesh | IP67 rated |

---

## 11. Verification Status

### 11.1 Simülasyon (GHDL)
| Test | Standart | Sonuç |
|------|----------|-------|
| AES S-Box Exhaustive (256/256) | FIPS 197 Table 4 | ✅ PASS |
| AES-256 Key Expansion (15 keys) | FIPS 197 A.3 | ✅ PASS |
| AES-256 Multi-Vector KAT | 3 NIST Sources | ✅ PASS |
| SHA-256 (2 vectors + kill) | FIPS 180-4 | ✅ PASS |
| HMAC-SHA256 (4 vectors) | RFC 4231 | ✅ PASS |
| POST Self-Test | FIPS 140-3 | ✅ PASS |
| Watchdog MAD Heartbeat | — | ✅ PASS |
| Kill Chain (14 sources) | FIPS 140-3 | ✅ PASS |
| TRNG Health + Reseed | SP 800-90B | ✅ PASS |
| Data Gearbox (PKCS#7) | RFC 5652 | ✅ PASS |
| SPI Key Loader (Split-Key) | — | ✅ PASS |
| Firmware Integrity (SHA-256) | — | ✅ PASS |
| Comm Protocol (Full-Duplex) | — | ✅ PASS |
| AEGIS Anomaly Detection (AXI-S) | — | ✅ PASS |
| 2nd-Order DOM Masked S-Box (1280 checks) | FIPS 197 | ✅ PASS |
| SEU Config Memory Scrubber (5 tests) | — | ✅ PASS |
| SVN Extended Counter (5 tests) | — | ✅ PASS |

**Sonuç: 17/17 PASS**

### 11.2 Vivado Synthesis (Post-Route)
- WNS: +0.239 ns (MET)
- WHS: +0.052 ns (MET)
- DRC: 0 error
- CDC: All interactions "Clean"
- Bitstream: 2,836,989 bytes (COMPRESS=TRUE)

### 11.3 Bekleyen Donanım Testleri
- [ ] FPGA board boot & POST doğrulama
- [ ] TRNG entropi (NIST SP 800-22)
- [ ] SPI key injection round-trip
- [ ] AES encrypt/decrypt end-to-end
- [ ] Kill protocol zeroization timing
- [ ] Watchdog 3-strike kill
- [ ] CPA side-channel analysis (ChipWhisperer)

---

## 12. Bitstream Configuration

```tcl
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
```

### 12.1 Üretim Güvenlik Ayarları (Gelecek)
```tcl
# JTAG kapatma
set_property BITSTREAM.CONFIG.USER_ACCESS_JTAG NONE [current_design]
# Readback engelleme
set_property BITSTREAM.READBACK.ACTIVE_CAPTURE NO [current_design]
# eFUSE şifreleme (irreversible)
set_property BITSTREAM.ENCRYPTION.ENCRYPT YES [current_design]
```
