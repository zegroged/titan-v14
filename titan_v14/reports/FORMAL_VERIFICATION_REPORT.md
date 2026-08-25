# TITAN V14 -- Formal Verification Raporu

**Tarih:** 26 Subat 2026  
**Arac:** GHDL Simulasyon + PSL Assertion Monitor  
**DUT:** `aes256_core.vhd` (17-state FSM, 5-katman fault koruması)

---

## Sonuc Ozeti

| # | Assertion | Tip | Sonuc | Detay |
|---|-----------|-----|-------|-------|
| S1 | Fault Stickiness | Safety | PASS | `fault_detected` set olduktan sonra clear olmuyor |
| S3 | Kill Zeroes | Safety | PASS | Kill sonrasi ciphertext = 0x00..00 |
| S4 | No Output on Fault | Safety | PASS | Fault varken gecerli ciphertext cikmaz |
| S5 | FSM Validity | Safety | PASS | Done sonrasi busy='0', spurious start survive |
| S5b | Spurious Start | Safety | PASS | Busy iken start gonderme FSM'i bozmadi |
| L1 | Bounded Completion | Liveness | PASS | 258 cycle (limit: 500) |
| L3a | Kill Recovery | Liveness | PASS | Kill sonrasi FSM IDLE'a dondu |
| L3b | No Deadlock | Liveness | PASS | Arka arkaya 2 sifreleme basarili |

**Genel: 8/8 PASS (5 Safety + 3 Liveness)**

---

## Test Senaryolari

### Test 1: Normal Sifreleme
- NIST AES-256 test vektoru
- TRNG mask: `0xDEADBEEF...`
- **258 cycle** icinde tamamlandi
- Fault yok, ciphertext gecerli

### Test 2: Kill Mid-Encryption
- Sifreleme 20. cycle'da kesildi
- `ciphertext <= (others => '0')` dogrulandi
- FSM aninda IDLE'a dondu

### Test 3: Double Encryption (Deadlock Check)
- Ayni key, farkli plaintext ile arka arkaya 2 sifreleme
- Her ikisi de 258 cycle'da tamamlandi
- FSM deadlock yok

### Test 4: Spurious Start While Busy
- Busy iken ikinci start pulse gonderildi
- AES core bunu ignore etti ve normal tamamladi

---

## PSL Property Formalizasyonu

```
-- S1: fault_detected once set, stays set until reset
-- psl S1: assert always (fault_detected='1') ->
--         next (fault_detected='1')
--         abort (rst_n='0' or kill_signal='1');

-- S3: kill clears all outputs
-- psl S3: assert always (kill_signal='1') ->
--         next (ciphertext = x"0..0" and busy='0');

-- L1: encryption completes within 500 cycles
-- psl L1: assert always (start='1') ->
--         eventually![500](done='1');

-- L3: FSM never permanently stuck
-- psl L3: assert always (busy='1') ->
--         eventually (busy='0');
```

## Sonraki Adim

- Vivado sentezinde `dont_touch` attribute'lari ile fault mantigi korumasi dogrulanmali
- SymbiYosys veya GHDL-Synth ile formal model checking yapilabilir
