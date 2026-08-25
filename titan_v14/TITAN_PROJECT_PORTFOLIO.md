# TITAN V14 — Proje Portfolyosu

**Proje Adı**: PROJECT TITAN  
**Versiyon**: V14 (Artix-7 Implementation)  
**Organizasyon**: PROJECT HİDRA — Sovereign Security R&D  
**Tarih**: Şubat 2026

---

## Proje Tanımı

TITAN V14, devlet düzeyindeki siber tehditlere karşı tamamen donanım tabanlı güvenlik sağlayan bir şifreli haberleşme terminalidir. Tüm kriptografik operasyonlar FPGA silikon seviyesinde gerçekleştirilir — yazılıma hiçbir anahtar veya açık metin sızmaz.

---

## Teknik Öne Çıkanlar

### Donanım Güvenlik Mimarisi
- **AES-256-CTR** şifreleme — NIST FIPS 197 uyumlu, 3 bağımsız test vektörü doğrulanmış
- **SHA-256 + HMAC-SHA256** bütünlük koruması — FIPS 180-4 ve RFC 4231 uyumlu
- **Kill Protocol**: 14 bağımsız kaynak, <20ns zeroization — asenkron flip-flop temizleme
- **Volatile-Only Keys**: Anahtarlar sadece flip-flop'larda yaşar, kalıcı bellek kullanılmaz
- **SPI Key Injection**: Split-key AES-wrapped güvenli anahtar yükleme

### AEGIS Side-Channel Koruma Sistemi
- **Masked S-Box**: 2nd-Order Domain-Oriented Masking (DOM) — CPA saldırılarına karşı
- **Omega Cloak**: Kaotik dummy round injection — güç analizi bozucu
- **Clock Jitter Injection**: Zamanlama saldırılarına karşı
- **PVT Monitor**: Sıcaklık/voltaj anomali tespiti
- **ESN Anomaly Detection**: Echo State Network tabanlı davranış analizi

### Doğrulama Metrikleri
- **17/17 GHDL Simülasyon Testi** — Tümü PASS
- **Vivado Sentez + P&R**: WNS=+0.239ns, WHS=+0.052ns (Timing MET)
- **Bitstream**: 2.8 MB (COMPRESS=TRUE)
- **Kaynak Kullanımı**: LUT %28, FF %17, BRAM %9

---

## Teknoloji Yığını

| Katman | Teknoloji |
|--------|-----------|
| FPGA | Xilinx Artix-7 100T (TSMC 28nm) |
| HDL | VHDL-2008 (58 kaynak modül) |
| Sentez | Vivado 2025.2 |
| Simülasyon | GHDL (open-source, 17 test) |
| Firmware | C (STM32L4 MCU — 49 modül) |
| Haberleşme | AES-256-CTR over UART (921600 baud) |

---

## MCU Firmware Ekosistemi

### callwhite_mcu (STM32L4 C Firmware)
- 49 modül: config, tamper, keypad, OLED, modem kontrol
- Boot PIN + Duress PIN, operator binding
- UART firewall (AT whitelist), IMSI catcher algılama
- Radio silence (GaN FET modem power cut)
- Backside attack protection (TSC capacitive sensing)
- Dead man switch, sealed recovery, USB surge koruması

---

## Yol Haritası

| Faz | Durum | Açıklama |
|-----|-------|----------|
| Phase 1-6 | ✅ Tamamlandı | Temel güvenlik altyapısı |
| Phase 7: AES-256 | ✅ Tamamlandı | Real kripto motoru |
| Phase 8: SPI Key | ✅ Tamamlandı | Volatile key injection |
| Phase 9: TRNG | ✅ Tamamlandı | Entropy generation |
| Phase 10: Pipeline | ✅ Tamamlandı | RED/BLACK separation |
| Phase 11: Factory | ✅ Tamamlandı | eFUSE, IP protection |
| AEGIS: Side-Channel | ✅ Tamamlandı | 4-layer protection |
| V14.2: Hardening | ✅ Tamamlandı | SEU, SVN, Radio Silence, Backside Shield, 2nd-Order DOM |
| Vivado P&R | ✅ Tamamlandı | Bitstream generated |
| Board Test | ⏳ Bekliyor | Hardware gerekli |
| Production | 📋 Planlandı | PCB + enclosure |

---

## İletişim

**Proje**: PROJECT HİDRA — Sovereign Secure Communication
**Platform**: Windows + Vivado 2025.2 + GHDL + Rust
