# Air-Gapped Key Ceremony — PROJECT HİDRA

## Amaç
Root anahtarları offline HSM'de üretmek — network saldırısı imkansız.

## Katılımcılar
- 5 Key Custodian (3-of-5 Shamir threshold)
- 1 Ceremony Coordinator
- 2 Independent Witness

## Donanım
- Air-gapped laptop (WiFi/BT donanım removed)
- YubiHSM 2 (FIPS 140-2 Level 3)
- 5x IronKey encrypted USB
- Faraday cage (EM emanation protection)

## Prosedür

### 1. Root Key Generation
```
YubiHSM2> generate-asymmetric-key \
  --algorithm=ed25519 \
  --label="HIDRA-ROOT-2024" \
  --domains=1 \
  --capabilities=sign-ecdsa
```

### 2. Shamir Secret Sharing (3-of-5)
```
# hidra_core::shamir modülü ile
shares = shamir_split(root_key, threshold=3, total=5)
# Her share farklı IronKey'e yazılır
```

### 3. Share Dağıtımı
| Custodian | Share # | Lokasyon |
|-----------|---------|----------|
| C1 | 1 | Kasa A (İstanbul) |
| C2 | 2 | Kasa B (Ankara) |
| C3 | 3 | Kasa C (İzmir) |
| C4 | 4 | Escrow (Noterlik) |
| C5 | 5 | Yedek (CEO kasası) |

### 4. MCU OTP Programming
```
# USB → air-gapped programmer → STM32 OTP
stm32_otp_write --addr=0x1FFF7800 --data=derived_device_key
# OTP bir kez yazılır, geri okunamaz
```

### 5. Doğrulama
- Root public key → tüm cihazlara embed
- 3 custodian ile test reconstruct
- Ceremony video kaydı (offline archive)
- YubiHSM audit log export

## Acil Durum
Root key compromise durumunda:
1. 3 custodian toplanır
2. Yeni root key üretilir
3. Tüm cihazlara OTA revocation + yeni key
