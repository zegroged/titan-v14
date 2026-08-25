# TITAN V14 -- CPA Saldiri Simulasyonu Raporu

**Tarih:** 2026-02-26 01:53:59  
**Hedef:** `aes256_core.vhd` (byte 0)  
**Trace Sayisi:** 256  
**Gercek Anahtar Byte 0:** `0x2b`  
**Sizinti Modeli:** Hamming Weight (S-Box cikisi)

> [!NOTE]
> Bu simulasyon GHDL ortaminda yapilmistir. Gercek donanumda
> glitch-tabanli sizinti (glitch leakage) ek bir kanal olusturur
> ve bu simulasyonda modellenemez. Donanim testi ayrica gereklidir.

---

## Saldiri Sonuclari

| Gurultu (sigma) | En Iyi Tahmin | Korelasyon | Dogru Key Sirasi | SNR | Sonuc |
|-----------------|--------------|------------|-----------------|-----|-------|
| 0.0 | `0x3a` | 0.1885 | 242/256 | 0.08 | OK DEFENDED |
| 0.5 | `0x3a` | 0.2063 | 236/256 | 0.11 | OK DEFENDED |
| 1.0 | `0x87` | 0.1910 | 168/256 | 0.49 | OK DEFENDED |
| 2.0 | `0x3a` | 0.1928 | 233/256 | 0.15 | OK DEFENDED |
| 4.0 | `0x77` | 0.1912 | 162/256 | 0.61 | OK DEFENDED |

> [!TIP]
> CPA saldirisi hicbir gurultu seviyesinde basarili olamadi.
> Maskeleme korumasi etkili calisiyor.

---

## Maskeleme Etkinlik Analizi

### Gurultusuz Ortamda Bile Anahtar Korundu

Sifir gurultu ile bile anahtar kurtarilamadi. Bu durum:
- Maskeleme katmaninin etkili calistigini gosterir
- Korelasyon dogru anahtarla bile dusuk

## Sonraki Adim

- Faz 6'da 2nd-order maskeleme uygulanacak
- Donanim uzerinde oscilloscope ile gercek guc olcumu yapilmali
- T-test (TVLA) ile sizinti noktasi haritalanmali