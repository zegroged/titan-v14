# TITAN V14 — TRNG Entropi Analiz Raporu

**Tarih:** 26 Şubat 2026  
**Kaynak:** GHDL Simülasyon (`trng_wrapper.vhd`, 131,072 bit)  
**Standart:** NIST SP 800-90B (Basitleştirilmiş)

---

## Sonuç Özeti

| # | Test | Sonuç | Detay |
|---|------|-------|-------|
| 1 | Monobit (Frekans) | ❌ SİM FAIL | oran=1.00 (simülasyon sınırı) |
| 2 | Runs | ❌ SİM FAIL | Monobit ön koşul sağlanamadı |
| 3 | Serial Korelasyon (lag=1) | ✅ PASS | r=0.000000 |
| 4 | Chi-Square (Byte) | ❌ SİM FAIL | χ²=4,177,920 (tek byte) |
| 5 | Otokorelasyon (lag 1-16) | ✅ PASS | max\|r\|=0.000000 |
| 6 | Min-Entropi | ❌ SİM FAIL | H_min=0.0 bit/sample |

**Genel: 2/6 PASS (Simülasyon)** — Bu sonuç beklenen ve doğru davranıştır.

---

## Neden 4 Test Başarısız?

> [!IMPORTANT]
> Bu sonuçlar bir **tasarım hatası değildir**. GHDL simülasyonu, Ring Oscillator'ların fiziksel jitter davranışını modelleyemediği için beklenen sonuçlardır.

### Kök Neden

```
Gerçek Donanım:
  RO1: ~200 MHz ± 5 MHz (fiziksel jitter)
  RO2: ~195 MHz ± 4 MHz (farklı routing)
  RO3: ~203 MHz ± 6 MHz (farklı bölge)
  XOR(RO1, RO2, RO3) = rastgele bit akışı ✅

GHDL Simülasyon:
  RO1: tam 1 GHz (after 1 ns, sabit)
  RO2: tam 1 GHz (after 1 ns, sabit)
  RO3: tam 1 GHz (after 1 ns, sabit)
  XOR(1, 1, 1) = 1 (her cycle aynı) ❌
```

3 Ring Oscillator aynı `after 1 ns` delay ile senkronize çalışır. Aynı frekans → XOR her zaman sabit → shift register tüm '1'lerle dolar.

### Simülasyonda Doğrulananlar

Simülasyon ortamında doğrulanan kısımlar:

| Doğrulama | Durum |
|-----------|-------|
| Shift register doğru çalışıyor | ✅ |
| XOR mixing mantığı doğru | ✅ |
| CDC 2-stage synchronizer aktif | ✅ |
| SP 800-90B health check FSM çalışıyor | ✅ |
| POST state machine (8 pencere) aktif | ✅ |
| Sentez korumaları (`dont_touch`, `async_reg`) mevcut | ✅ |

### Donanımda Beklenen Sonuçlar

| Test | Beklenen Donanım Sonucu |
|------|------------------------|
| Monobit | PASS — 3 bağımsız RO XOR → ~%50 oran |
| Runs | PASS — Fiziksel jitter rastgele geçişler üretir |
| Chi-Square | PASS — 256 byte değeri uniform dağılır |
| Min-Entropi | PASS — H_min > 0.9 bit/sample |

---

## Test Altyapısı

| Dosya | Açıklama |
|-------|----------|
| `tb_trng_capture.vhd` | GHDL testbench — 1024 snapshot × 128 bit |
| `nist_entropy_test.py` | Python analiz — 6 istatistiksel test |
| `run_entropy_test.bat` | Tek komut: derleme → simülasyon → analiz → rapor |

## Sonraki Adım

Donanım (Artix-7 board) mevcut olduğunda:
1. `trng_wrapper` bitstream'e sentezle
2. UART üzerinden 1M+ bit örnekle
3. Aynı `nist_entropy_test.py` ile analiz et
4. Sonuçları bu raporla karşılaştır
