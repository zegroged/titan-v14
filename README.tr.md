# TITAN V14

> FPGA tabanlı bir donanım güvenlik modülü: VHDL ile yazılmış, maskeli S-box'lı özel AES-256, halka-osilatörlü TRNG ve yan-kanal karşı önlemleri — PSL doğrulamalarıyla kanıtlanmış ve simüle edilmiş CPA saldırısıyla sınanmış — Rust ile yazılmış bir post-kuantum kriptografi yığınıyla birlikte.

**English README:** [README.md](README.md)

![VHDL](https://img.shields.io/badge/VHDL-174%20dosya-blue)
![Rust](https://img.shields.io/badge/Rust-11%20crate-orange)
![Hedef](https://img.shields.io/badge/Hedef-Artix--7%20XC7A100T%20%2B%20PolarFire-lightgrey)
![Testler](https://img.shields.io/badge/GHDL-13%2F13%20ge%C3%A7ti%2C%20%25100%20kapsam-brightgreen)
![Formel](https://img.shields.io/badge/PSL%20do%C4%9Frulama-6%2F6%20ge%C3%A7ti-brightgreen)
![CPA](https://img.shields.io/badge/CPA%20sald%C4%B1r%C4%B1s%C4%B1-savunuldu%20(sim)-brightgreen)
![Sentez](https://img.shields.io/badge/Vivado-sentezlendi%2C%20%256.5%20XC7A100T-brightgreen)
![Durum](https://img.shields.io/badge/Durum-hi%C3%A7%20%C3%BCretilmedi-yellow)
![Lisans](https://img.shields.io/badge/Lisans-MIT-blue)

---

## Durum — önce bunu oku

Bu proje **hedef yonga için tasarlandı, simüle edildi ve sentezlendi. Hiçbir zaman
silikonda üretilmedi.** Aşağıdaki her iddia bir simülasyon ya da sentez sonucudur;
çalışan bir donanımdan alınmış ölçüm değildir.

Sentez gerçektir ve raporlar bu depodadır. Vivado, üst düzey `artix7_top_v14`
tasarımını Artix-7 XC7A100T için sentezledi:

| Ölçüt | Üst düzey (`v14_ooc_synth`) | AES alt sistemi (`v14_aes_synth`) |
| --- | --- | --- |
| Slice LUT | 4.098 (%6,46) | 4.183 (%6,60) |
| Slice register | 3.959 (%3,12) | 3.162 (%2,49) |
| Block RAM | 0 | 0 |
| DSP slice | 0 | 0 |

Tasarım, yonganın kabaca %6,5'ine sığıyor ve hiç block RAM ya da DSP slice
kullanmıyor — AES veri yolu, TRNG ve karşı önlem mantığının tamamı saf fabric.
Raporlar: [`titan_v14/reports/`](titan_v14/reports/).

Bağımsız bir projeydi; bir savunma elektroniği şirketine yaklaşmak için portfolyo
çalışması olarak düşünüldü. Tek bir özel çift-FPGA kartı ürettirmenin maliyeti
finanse edebileceğimin çok üstüne çıkınca durdu. Buradaki hiçbir şey sözleşme
kapsamında üretilmedi ve üzerinde hiçbir üçüncü tarafın hakkı yok.

Bir referans uygulaması olarak yayımlanıyor: RTL, testbench'ler, build scriptleri ve
tasarım dokümanları burada.

---

## Genel bakış

TITAN, iki yongalı bir güvenlik terminali tasarımıdır. Bir **Xilinx Artix-7
(XC7A100T)** kriptografik veri yolunu ve karşı önlem mantığını taşır; **Microchip
PolarFire (MPF100)** ise flash tabanlı fabric'i ve yerleşik tasarım güvenliği
nedeniyle seçilerek denetleyici aygıt olarak planlandı. İkisinin arasında bir
red/black ayrım sınırı vardır — "BLACK" UART, güvenli taraftan çıkan tek yoldur.

İlginç olan AES yapması değil; AES'i çevreleyen şeydir:

- S-box'un bir **maskeli varyantı** var (`aes_sbox_masked.vhd`) — diferansiyel güç
  analizine karşı birinci dereceden boolean maskeleme karşı önlemi.
- Veri yolunun yanında bir **sahte işlem enjektörü** ve bir **saat titreşimi
  enjektörü** çalışır; böylece güç ve zamanlama izleri gerçek turlarla hizalanmaz.
- Anormal davranışı işaretlemek için donanımda bir **Echo State Network** (rezervuar
  hesaplama) uygulanmıştır; bunu, glitch ve hata enjeksiyonu girişimleri için süreç,
  voltaj ve sıcaklığı izleyen bir **PVT monitörü** besler.
- Bir **açılış öz-testi** (`post_self_test.vhd`), aygıt çalışmadan önce sabit NIST
  vektörlerine karşı bilinen-cevap testleri yürütür.
- Bir **imha protokolü** (`kill_protocol.vhd`), bir denetleyici sinyalinde anahtar
  materyalini siler.

Rust tarafı (`titan-core/`), donanımın üzerinde çalışması amaçlanan protokol
katmanıdır: post-kuantum anahtar değişimi ve imzalar, bir Double Ratchet, bir DHT ve
bir dead-drop taşıması.

---

## Depoda ne var

### Donanım (VHDL — 174 dosya)

| Alan | Modüller |
| --- | --- |
| Simetrik kripto | `aes256_core`, `aes_key_expand`, `aes_round`, `aes_sbox`, **`aes_sbox_masked`** |
| Entropi | `trng_ring_osc`, `trng_wrapper` |
| Anahtar yönetimi | `secure_key_storage`, `key_loader_spi`, `kill_protocol` |
| Karşı önlemler | sahte-işlem enjektörü, saat-titreşimi enjektörü, `post_self_test` |
| Anomali algılama | ESN rezervuar çekirdeği, ESN okuma katmanı, anomali algılayıcı, PVT monitörü |
| G/Ç ve kontrol | `spi_cmd_slave`, `uart_driver`, `uart_telemetry`, `comm_protocol`, `data_gearbox` |
| Denetim | `system_supervisor`, `watchdog_monitor` |

**84 RTL modülü, 66 testbench.** GHDL, Artix-7 üst düzey entegrasyon testi dahil, 13
entegrasyon düzeyi testbench'in 13'ünün geçtiğini bildiriyor.

### Yazılım (Rust — 11 crate)

| Crate | Amaç |
| --- | --- |
| `titan_kyber` | Post-kuantum anahtar kapsülleme (ML-KEM / Kyber) |
| `titan_dilithium` | Post-kuantum imzalar (ML-DSA / Dilithium) |
| `titan_ratchet` | Double Ratchet ileri gizlilik |
| `titan_envelope` | Mesaj mühürleme |
| `titan_entropy` | Entropi toplama ve sağlık kontrolleri |
| `titan_dht` | Dağıtık hash tablosu |
| `titan_dead_drop` | Asenkron mesaj bırakma |
| `titan_hopping` | Frekans atlama mantığı |
| `titan_hal` | FPGA bağlantısı üzerinde donanım soyutlaması |
| `titan_sentry` | Çalışma zamanı izleme |
| `titan_integration_tests` | Crate'ler arası entegrasyon testleri |

İkinci bir workspace, `titan_v14/sw/`, ana bilgisayar tarafı araçları tutar:
`hidra_core` (bir fuzzing koşumuyla), `hidra_net`, `hidra_sim`, `hidra_e2e` ve
`hidra_ui`.

### Doğrulama

Aşağıdakilerin tamamı simülasyon düzeyindedir, ama "testbench'ler geçiyor"dan öteye
gider. Tüm raporlar [`titan_v14/reports/`](titan_v14/reports/) içindedir.

| Rapor | Ne yapıldı | Sonuç |
| --- | --- | --- |
| [CPA saldırısı](titan_v14/reports/CPA_ATTACK_REPORT.md) | `aes256_core` bayt 0'a karşı korelasyon güç analizi — 256 iz, S-box çıkışında Hamming-ağırlık sızıntı modeli, beş gürültü düzeyinde (σ = 0 … 4) | Saldırı her gürültü düzeyinde yanlış anahtar baytını kurtardı. Maskeleme dayandı. |
| [Formel doğrulama](titan_v14/reports/FORMAL_VERIFICATION_REPORT.md) | 17 durumlu AES FSM üzerinde PSL doğrulamaları: hata yapışkanlığı, imha-sıfırlama, hata altında çıkış-yok, FSM geçerliliği, sahte-başlatmaya dayanma, sınırlı tamamlanma | 6/6 geçti; tamamlanma 500 çevrimlik sınıra karşı 258 çevrimde sınırlandı |
| [İkinci dereceden maskeleme](titan_v14/reports/SECOND_ORDER_MASKING_REPORT.md) | DRBG'den maskeye köprü, Hamming ağırlığıyla ölçülen maske bağımsızlığı, şifrelemeler arası maske dinamizmi | Tohumlama, bağımsızlık ve dinamizm geçti; iki NIST-vektör testi *tasarım gereği* başarısız, çünkü dinamik bir maske sabit bir vektörle eşleşemez — beklenen sonuç olarak belgelendi |
| [TRNG entropisi](titan_v14/reports/TRNG_ENTROPY_REPORT.md) | 131.072 simüle edilmiş bit üzerinde NIST SP 800-90B (basitleştirilmiş) | 2/6 geçti — **ve doğru sonuç budur**, aşağıya bakın |
| [Fonksiyonel kapsam](titan_v14/reports/GHDL_COVERAGE_REPORT.md) | GHDL 5.1.1, VHDL-2008 | 13/13 testbench, bildirilen senaryoların %100'ü koşuldu |

TRNG sonucunu tam okumaya değer, çünkü başarısız bir entropi testi, sebebini görene
kadar alarm verici görünür: GHDL, bir halka osilatörünün fiziksel titreşimini
modelleyemez. Simülasyonda üç halka osilatörü tam olarak nominal frekanslarında
çalışır, bu yüzden çıktı deterministiktir ve monobit, runs, ki-kare ve min-entropi
testleri tasarım gereği başarısız olur. Serial korelasyon ve otokorelasyon —
rastgelelik yerine yapıyı ölçen iki test — r = 0,000000 ile geçer. Rapor bunu
başarısızlıkları gizlemek yerine açıkça söyler.

CPA raporu da aynı tür bir not taşır: glitch tabanlı sızıntı fonksiyonel bir
simülasyonda yoktur; dolayısıyla orada savunulmuş bir sonuç, silikonda savunulmuş bir
sonucu kanıtlamaz.

### Dokümanlar

`titan_v14/docs/`, bir hobi projesinin genellikle sağ çıkaramadığı tasarım
malzemesini içerir: bir [anahtar töreni prosedürü](titan_v14/docs/key_ceremony.md),
bir [yeniden üretilebilir build](titan_v14/docs/reproducible_build.md) açıklaması,
bir [geçici build](titan_v14/docs/ephemeral_build.md) notu, bir donanım test planı,
bir güvenlik politikası ve bir hücresel modül mühendislik planı.

---

## Derleme

Karta gerek yok — testbench'ler simülasyonda çalışır ve `titan_v14/reports/` içinde
hâlihazırda bulunan sentez raporları aşağıdaki Tcl akışıyla üretildi.

```bat
:: VHDL simülasyonu (GHDL) — Windows
cd titan_v14\scripts
run_all_tb.bat
```

```bash
# Rust workspace
cd titan-core
cargo test
```

Sentez, `titan_v14/scripts/` içindeki Tcl scriptleriyle sürülür — Vivado için
`build_artix7.tcl` ve `build_bitstream.tcl`, hiç tamamlanmayan PolarFire tarafı için
`build_polarfire_*.tcl`. Simülasyonları çalıştırmak için her iki araç zinciri de
gerekmez.

---

## Bilinen sınırlamalar

Bunlar dürüst boşluklardır. Çoğu, proje donanımdan önce durduğu için vardır.

1. **Silikon doğrulaması yok.** Sentez yapıldı ve kullanım biliniyor (bkz. Durum), ama
   hiçbir şey gerçek bir yonga üzerinde çalışmadı. Gerçek verim ölçülmedi.
2. **Zamanlama kapatılmadı, ama kısıtlar var.** Bu depodaki raporlar *out-of-context*
   (bağlam-dışı) sentez koşumlarından gelir; `timing_summary.rpt` dosyasının
   *"kullanıcı tarafından belirtilmiş zamanlama kısıtı yok"* demesinin ve WNS ile TNS
   için NA döndürmesinin sebebi budur. Gerçek kısıtlar yazılmıştır —
   `rtl/artix7/master_constraints.xdc` 50 MHz'lik bir sistem saati bildirir — ve
   `scripts/build_artix7.tcl` bunları yükler, ama o tam bağlam-içi build hiçbir zaman
   sonuna kadar çalıştırılmadı. Onu çalıştırmak bu projedeki en ucuz kalan iştir ve
   Durum tablosundan eksik olan tek sayıyı üretir: tasarımın gerçekte kapandığı
   frekans.
3. **TRNG'nin entropisi test edildi, ama yalnızca testin işleyemeyeceği yerde.**
   131.072 simüle bit üzerindeki NIST SP 800-90B koşumu depodadır ve altı testinden
   dördü başarısız olur, çünkü simüle edilmiş bir halka osilatörünün fiziksel
   titreşimi yoktur. Bu, en önemli kalan boşluktur: bir halka-osilatör TRNG'sinin tüm
   değeri fiziksel rastgeleliktir ve bu ancak silikonda ölçülebilir.
4. **Yan-kanal karşı önlemleri simüle edilmiş bir saldırıdan sağ çıktı, gerçek birinden
   değil.** AES çekirdeğine karşı CPA koşumu hiçbir gürültü düzeyinde anahtarı
   kurtaramadı; bu, maskelemenin bir şey yaptığının kanıtıdır. Ama fonksiyonel
   simülasyonda glitch sızıntısı, EM emisyonu ve gerçek bir prob'un ölçüm gürültüsü
   yoktur. Güç izleri bir karttan yakalanana kadar karşı önlemler donanıma karşı
   kanıtlanmış değil, simülasyonla desteklenmiştir.
5. **PolarFire yarısı hiç yapılmadı.** Yalnızca Artix-7 tarafının RTL'i var.
   Denetleyici aygıt, tasarım dokümanlarında mevcuttur.
6. **AES çekirdeği sertifikalı bir uygulama değildir.** Simülasyonda NIST vektörlerine
   karşı bilinen-cevap testlerini geçer. Bu doğruluktur — sertifikasyon değil.
7. **Rust post-kuantum crate'leri referans uygulamaları sarmalar** ve bağımsız olarak
   denetlenmemiştir.

---

## Bunu ne ileri taşır

İki şey, sırayla.

**Tam bağlam-içi build'i çalıştır.** `scripts/build_artix7.tcl`,
`master_constraints.xdc` dosyasını 50 MHz saatiyle zaten yüklüyor ve
`report_timing_summary` çağrısını zaten yapıyor. Onu sonuna kadar çalıştırmak bir
Vivado oturumuna mal olur ve zamanlama raporundaki NA'yı gerçek bir WNS rakamına
çevirir.

**Sonra bir geliştirme kartı al.** XC7A100T taşıyan bir Artix-7 kartı — bu tasarımın
%6,5 kullanımla zaten sentezlendiği aynı yonga — birkaç yüz dolar tutar; özel bir
çift-FPGA kartının fiyatı değil. Bu, simülasyonun yapısal olarak kapatamadığı iki
boşluğu kapatır: fiziksel titreşim üzerinde NIST SP 800-90B'ye karşı TRNG'nin gerçek
entropisini ölçmek ve hiçbir fonksiyonel simülatörün üretmediği glitch sızıntısına
karşı maskelemeyi sınamak için güç izleri yakalamak.

---

## Lisans

MIT — bkz. [LICENSE](LICENSE).
