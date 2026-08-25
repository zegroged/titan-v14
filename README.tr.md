# PROJECT HİDRA — TITAN V14 Sovereign Security Terminal

![Tests](https://img.shields.io/badge/GHDL_Tests-13%2F13_PASS-brightgreen)
![Version](https://img.shields.io/badge/Version-V14.1--stable-blue)
![FPGA](https://img.shields.io/badge/FPGA-Artix--7_XC7A100T-orange)

## 📋 Proje Tanımı

**TITAN V14**, devlet düzeyinde güvenlik gereksinimleri için tasarlanmış, çift-FPGA (Artix-7 + PolarFire) mimarisine sahip egemen güvenlik terminalidir. AES-256-CTR şifreleme, AEGIS AI anomali algılama, Omega Cloak DPA koruması, PVT izleme ve donanım düzeyinde imha mekanizmalarını içerir.

## 🏗️ Dizin Yapısı

```
PROJECT HİDRA/
├── common/              ← Ortak VHDL modülleri (AES, SPI, UART, TRNG, vb.)
├── titan_v14/
│   ├── rtl/             ← RTL kaynak kodları (Artix-7, AEGIS)
│   ├── tb/              ← Test-bench dosyaları
│   ├── scripts/         ← Build & simülasyon scriptleri
│   ├── reports/         ← Sentez & implementasyon raporları
│   ├── docs/            ← Teknik dokümantasyon
│   ├── sw/              ← Yazılım (Rust, Python)
│   └── tools/           ← Yardımcı araçlar
└── README.md            ← Bu dosya
```

## 🔧 Build Talimatları

### Vivado Sentez & İmplementasyon
```bat
cd C:\Users\Mert\titan_build
run_vivado.bat
```
> **vivado_build.tcl** sentez → yerleştirme → rotalama → bitstream üretimini otomatik yapar.

### GHDL Simülasyon (Tüm Test-Bench'ler)
```bat
cd C:\Users\Mert\titan_build\ghdl_sim
run_all_tb.bat
```
> 13 adet test-bench otomatik olarak analiz, elaborate ve run edilir.

## 🧪 Test Sonuçları

| # | Test-bench | Sonuç |
|---|-----------|-------|
| 1 | Tanh LUT ROM | ✅ PASS |
| 2 | Shift-Add Multiplier | ✅ PASS |
| 3 | Chaotic PRNG (Logistic Map) | ✅ PASS |
| 4 | Ring Oscillator Counter | ✅ PASS |
| 5 | ESN Reservoir Core | ✅ PASS |
| 6 | ESN Readout Layer | ✅ PASS |
| 7 | Anomaly Detector | ✅ PASS |
| 8 | PVT Monitor | ✅ PASS |
| 9 | Dummy Op Injector | ✅ PASS |
| 10 | Clock Jitter Injector | ✅ PASS |
| 11 | Omega Cloak Top | ✅ PASS |
| 12 | AEGIS Top | ✅ PASS |
| 13 | Artix-7 Top V14 (Integration) | ✅ PASS |

**Toplam: 13 PASS / 0 FAIL / 0 SKIP**

## 🏛️ Temel Modüller

| Modül | Açıklama |
|-------|----------|
| `aes256_core` | AES-256 şifreleme çekirdeği (fault detection + masking) |
| `aes_core_wrapper` | CTR modunda AES + Omega Cloak DPA koruması |
| `spi_cmd_slave` | SPI komut arayüzü (heartbeat, key injection) |
| `watchdog_monitor` | Dual-FPGA karşılıklı izleme |
| `trng_wrapper` | Donanım TRNG (ring oscillator tabanlı) |
| `system_supervisor` | Global reset & kill-chain yönetimi |
| `comm_protocol` | RED/BLACK UART veri akışı (CDC) |
| `aegis_top` | ESN AI anomali algılama üst modülü |
| `omega_cloak_top` | DPA side-channel koruması |
| `pvt_monitor_top` | Voltaj/sıcaklık/frekans izleme |

## 📜 Lisans

Bu proje gizli/özel kullanım içindir. Yetkisiz dağıtım yasaktır.

---
*Son güncelleme: 2026-02-25 — Antigravity ile oluşturuldu.*
