# Titan Mobile — iPhone (iOS) Sürümü

**Durum**: ⏳ FAZ 2 — Android tamamlandıktan sonra

## Notlar

- Android'de çalışan özellikler iOS'ta farklı implementasyon gerektirebilir
- iOS kısıtlamaları: Arka plan Tor, Doze modu, sensör erişimi
- Ayrı native uygulama (Swift + Rust FFI)
- Secure Enclave entegrasyonu (StrongBox yerine)

## iOS'a Özel Zorluklar

| Konu | Android | iOS |
|------|---------|-----|
| Tor arka plan | Foreground Service | Background App Refresh (kısıtlı) |
| Sensör entropi | Tam erişim | Kamera/Mikrofon izin kısıtlamaları |
| Secure Element | StrongBox / TEE | Secure Enclave |
| Dahili klavye | Custom InputMethod | Custom Keyboard Extension |
| USB HSM | USB HID direkt | Lightning/USB-C MFi kısıtlaması |
| Rust köprü | JNI | C-FFI (cbindgen / UniFFI) |

## Yapılacaklar

- [ ] iOS mimari planı oluştur
- [ ] Swift + Rust FFI köprüsü araştır
- [ ] Secure Enclave API araştır
- [ ] Background Tor çözümü araştır
- [ ] TestFlight dağıtım planı
