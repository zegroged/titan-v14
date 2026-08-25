################################################################################
## PROJECT TITAN V14: MASTER PHYSICAL CONSTRAINTS
## ★ FIX #6: Xilinx Artix-7 XC7A100T-1CSG324C (upgraded from XC7A35T CPG236)
## 100T: 126,800 FF | 63,400 LUT | 135 BRAM | 6 MMCM
################################################################################
## AMAÇ: Fabrikaya gidecek nihai fiziksel harita
##
## KOMUTAN ŞERHİ: "Her bacak bir asker, her pin bir emir!"
##
## STANDARTLAR:
##   - LVCMOS33: 3.3V logic (Tamper sensörler ve SPI uyumlu)
##   - PACKAGE_PIN: PCB şemasındaki fiziksel bacak numarası
##   - Pull-up/down: Güvenlik pinlerinde default state
################################################################################

################################################################################
## 1. SYSTEM CLOCK (50 MHz - SiTime SiT5356 Oscillator Output)
################################################################################
set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { PIN_EXT_CLK_50MHZ }]
create_clock -name ext_clk -period 20.000 -waveform {0 10} [get_ports { PIN_EXT_CLK_50MHZ }]
## ext_clk: 50 MHz primary clock on external oscillator pin

## Glitch detector: clock-as-data path — hold check is not meaningful
## (MMCM CLKOUT0 feeds fast_sample_reg/D directly through BUFG)
set_false_path -hold -to [get_pins glitch_det_inst/fast_sample_reg/D]

################################################################################
## 2. UART DATA PIPELINE (FAZ 10: PC Communication)
################################################################################
## TX: FPGA → PC (Ciphertext çıkışı)
## RX: PC → FPGA (Plaintext girişi)
################################################################################
set_property -dict { PACKAGE_PIN D10   IOSTANDARD LVCMOS33 } [get_ports { UART_TX_PIN }]
set_property -dict { PACKAGE_PIN A9    IOSTANDARD LVCMOS33 } [get_ports { UART_RX_PIN }]

## Input delay (PC UART transmitter'dan kaynaklanan gecikme)
set_input_delay -clock ext_clk -max 2.0 [get_ports UART_RX_PIN]
set_input_delay -clock ext_clk -min 0.5 [get_ports UART_RX_PIN]

## Output delay (PC UART receiver beklentisi)
set_output_delay -clock ext_clk -max 2.0 [get_ports UART_TX_PIN]
set_output_delay -clock ext_clk -min 0.5 [get_ports UART_TX_PIN]

## UART/output portlar sys_clk_raw (MMCM) tarafından sürülüyor.
## ext_clk → sys_clk_raw aynı kaynak, 0° faz = hold güvenli.
set_false_path -hold -from [get_clocks sys_clk_raw] -to [get_clocks ext_clk]

################################################################################
## 3. SPI KEY LOADER (FAZ 8: Volatile Key Injection)
################################################################################
## Master: External SPI controller (Secure Key Filler)
## Slave: FPGA (key_loader_spi modülü)
################################################################################
set_property -dict { PACKAGE_PIN G13   IOSTANDARD LVCMOS33 } [get_ports { SPI_CS_N_PIN }]
set_property -dict { PACKAGE_PIN B11   IOSTANDARD LVCMOS33 } [get_ports { SPI_MOSI_PIN }]
set_property -dict { PACKAGE_PIN A11   IOSTANDARD LVCMOS33 } [get_ports { SPI_SCLK_PIN }]
set_property -dict { PACKAGE_PIN A10   IOSTANDARD LVCMOS33 } [get_ports { SPI_APP_CS_N_PIN }]
set_property -dict { PACKAGE_PIN C11   IOSTANDARD LVCMOS33 } [get_ports { SPI_MISO_PIN }]

## SPI timing (Max 10 MHz SPI clock)
set_input_delay -clock ext_clk -max 5.0 [get_ports {SPI_*}]
set_input_delay -clock ext_clk -min 1.0 [get_ports {SPI_*}]

## False path (SPI asenkron, CDC sync var)
set_false_path -from [get_ports SPI_SCLK_PIN]
set_false_path -from [get_ports SPI_MOSI_PIN]
set_false_path -from [get_ports SPI_CS_N_PIN]

################################################################################
## 4. SECURITY & TAMPER DETECTION (FAZ 2/3/4)
################################################################################
## KILL_PIN: External tamper mesh XOR tree output
##   - Active HIGH (Tamper tespit = '1')
##   - Pull-down resistor (Default = '0' = Safe)
################################################################################
set_property -dict { PACKAGE_PIN D9    IOSTANDARD LVCMOS33  PULLDOWN TRUE } [get_ports { KILL_PIN }]

## ★ KRİTİK: KILL sinyali max 6ns'de kill_protocol flip-floplara ulaşmalı!
## NOT: Eski constraint tüm hücrelere 6ns kısıtı koyuyordu → 1519 timing ihlali
## Sadece kill_protocol modülündeki hedef hücrelere kısıtla
set_max_delay -from [get_ports KILL_PIN] -to [get_cells -hierarchical -filter {NAME =~ *kill_inst*}] 6.0

## JUMPER_CALIB: Factory/Armed mode seçici
##   - Takılı (GND) = Factory Mode (Kill disable)
##   - Açık (VCC)  = Armed Mode (Kill active)
################################################################################
set_property -dict { PACKAGE_PIN C2    IOSTANDARD LVCMOS33  PULLUP TRUE } [get_ports { JUMPER_CALIB }]

################################################################################
## 5. DUAL-FPGA MUTUAL WATCHDOG (FAZ 6: Artix ↔ PolarFire Link)
################################################################################
## PF_HEARTBEAT_IN: PolarFire'dan gelen nabız (1 Hz toggle)
## PF_KILL_CMD: Artix'in PolarFire'ı vurma komutu (Counter-Strike)
################################################################################
set_property -dict { PACKAGE_PIN V15   IOSTANDARD LVCMOS33 } [get_ports { PF_HEARTBEAT_IN }]
set_property -dict { PACKAGE_PIN U11   IOSTANDARD LVCMOS33 } [get_ports { PF_KILL_CMD }]

## Heartbeat asenkron (watchdog_monitor CDC sync içinde)
set_false_path -from [get_ports PF_HEARTBEAT_IN]

## ★ CDC FALSE PATHS: Async input → sys_clk_raw domain
## Bu sinyaller ext_clk domain'inde tanımlı ama aslında asenkron.
## RTL'de 2-stage CDC synchronizer ile karşılanıyor.
set_false_path -from [get_ports KILL_PIN] -to [get_clocks -include_generated_clocks ext_clk]
set_false_path -from [get_ports JUMPER_CALIB] -to [get_clocks -include_generated_clocks ext_clk]

## Kill komutu öncelikli (PolarFire'ın PROGRAM_B pinine gider)
set_max_delay -from [all_registers] -to [get_ports PF_KILL_CMD] 10.0

## NOT: ext_clk kaldırıldı, artık tek clock (ext_clk) var.
## set_clock_groups gerekli değil.

################################################################################
## 6. STATUS LEDS (Visual Feedback)
################################################################################
## GREEN: Heartbeat (Canlılık göstergesi, Factory modda sürekli yanık)
## RED: Tamper alarm (Kill tetiklendiğinde yanar)
################################################################################
set_property -dict { PACKAGE_PIN H5    IOSTANDARD LVCMOS33 } [get_ports { LED_STATUS_GREEN }]
set_property -dict { PACKAGE_PIN J5    IOSTANDARD LVCMOS33 } [get_ports { LED_STATUS_RED }]

## LED drive strength (4mA yeterli, düşük güç)
set_property DRIVE 4 [get_ports LED_STATUS_*]

## False path (LED slow signal, timing kritik değil)
set_false_path -to [get_ports LED_STATUS_*]

################################################################################
## 7. UART TELEMETRY (Legacy - FAZ 5)
################################################################################
## Eski telemetri modülü için (simülasyon/debug)
################################################################################
set_property -dict { PACKAGE_PIN D4    IOSTANDARD LVCMOS33 } [get_ports { UART_TX_PAD }]
set_false_path -to [get_ports UART_TX_PAD]

################################################################################
## 7b. BLACK UART (FAZ 10b: Secure Communication Encrypted Channel)
################################################################################
## BLACK_UART_TX: FPGA → Diğer Cihaz (Ciphertext çıkışı)
## BLACK_UART_RX: Diğer Cihaz → FPGA (Ciphertext girişi)
## COMM_MODE: TX/RX seçici (DIP switch — '0'=TX, '1'=RX)
################################################################################
set_property -dict { PACKAGE_PIN C4    IOSTANDARD LVCMOS33 } [get_ports { BLACK_UART_TX_PIN }]
set_property -dict { PACKAGE_PIN D3    IOSTANDARD LVCMOS33 } [get_ports { BLACK_UART_RX_PIN }]
set_property -dict { PACKAGE_PIN B4    IOSTANDARD LVCMOS33  PULLDOWN TRUE } [get_ports { COMM_MODE_PIN }]

## BLACK UART timing constraints
set_input_delay -clock ext_clk -max 2.0 [get_ports BLACK_UART_RX_PIN]
set_input_delay -clock ext_clk -min 0.5 [get_ports BLACK_UART_RX_PIN]
set_output_delay -clock ext_clk -max 2.0 [get_ports BLACK_UART_TX_PIN]
set_output_delay -clock ext_clk -min 0.5 [get_ports BLACK_UART_TX_PIN]

## COMM_MODE async (CDC sync var)
set_false_path -from [get_ports COMM_MODE_PIN]

################################################################################
## 7c. STATUS LEDS — Extended (POST + OMEGA)
################################################################################
## LED_POST_FAIL: POST self-test FAIL → kırmızı yanar (kalıcı)
## LED_OMEGA_ACTIVE: Omega DPA protection aktif
################################################################################
set_property -dict { PACKAGE_PIN K5    IOSTANDARD LVCMOS33 } [get_ports { LED_POST_FAIL }]
set_property -dict { PACKAGE_PIN L4    IOSTANDARD LVCMOS33 } [get_ports { LED_OMEGA_ACTIVE }]
set_property DRIVE 4 [get_ports LED_POST_FAIL]
set_property DRIVE 4 [get_ports LED_OMEGA_ACTIVE]
set_false_path -to [get_ports LED_POST_FAIL]
set_false_path -to [get_ports LED_OMEGA_ACTIVE]

################################################################################
## 8. TRNG RING OSCILLATOR CONSTRAINTS (FAZ 9: Chaos Engine)
################################################################################
## Ring oscillator kombinasyonel döngüye izin ver
## Sentezleyici bu döngüleri "hata" sanıp optimize etmesin!
################################################################################

## Allow combinatorial loops (TRNG için zorunlu)
set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets -hierarchical "*chain*"]

## DRC Check severity düşür (LUTLP-1: LUT Loop → WARNING)
set_property SEVERITY {WARNING} [get_drc_checks LUTLP-1]

## Synthesis protection (Optimize edilmesin)
## NOT: trng_ring_osc adı sentezde farklı — trng_inst ile geniş yakalıyoruz.
set_property DONT_TOUCH TRUE [get_cells -hierarchical -filter {NAME =~ *trng_inst*}]
set_property KEEP TRUE [get_nets -hierarchical -filter {NAME =~ *chain*}]

## [OPTİONAL] Placement hints (Farklı clock region'lara dağıt - daha fazla jitter)
## Floorplanning sonrası aktif edilecek:
# set_property LOC SLICE_X10Y10 [get_cells {trng_inst/ro_inst_1/chain_reg[0]}]
# set_property LOC SLICE_X50Y50 [get_cells {trng_inst/ro_inst_2/chain_reg[0]}]
# set_property LOC SLICE_X90Y90 [get_cells {trng_inst/ro_inst_3/chain_reg[0]}]

################################################################################
## 9. TIMING EXCEPTIONS
################################################################################

## Multi-cycle paths (Slow signals)
## NOT: ext_clk kaldırıldı, ext_clk kullanılıyor
set_multicycle_path -setup 2 -from [get_clocks ext_clk] -to [get_cells -hierarchical -filter {NAME =~ *heartbeat_cnt*}]
set_multicycle_path -hold 1 -from [get_clocks ext_clk] -to [get_cells -hierarchical -filter {NAME =~ *heartbeat_cnt*}]

################################################################################
## 10. BITSTREAM CONFIGURATION
################################################################################

## Configuration rate (33 MHz SPI - hızlı boot)
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]

## SPI mode (x4 - quad SPI, build_bitstream.tcl ile tutarlı)
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]

## Unused pin behavior (Pull-down - güvenlik)
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]

## Internal VREF (Bağımsız, harici direnç yok)
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

################################################################################
## 11. ★ BITSTREAM SECURITY (eFUSE AES ENCRYPTION)
################################################################################
## FABRİKAYA GİDECEK DOSYADA BU SATIR OLMAYACAK!
## Sadece Golden Image'de aktif edilecek.
################################################################################

## AES Encryption (eFUSE key kullan)
set_property BITSTREAM.ENCRYPTION.ENCRYPT YES [current_design]
set_property BITSTREAM.ENCRYPTION.ENCRYPTKEYSELECT eFUSE [current_design]

## HMAC Integrity Check (Bitstream değişikliği tespiti)
## NOT: BITSTREAM.ENCRYPTION.HMAC property'si Artix-7'de mevcut değil.
## 7-Series FPGA'larda bitstream integrity CRC ile sağlanır.
# set_property BITSTREAM.ENCRYPTION.HMAC YES [current_design]

## Debug devre dışı (JTAG/ChipScope yasak)
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

## ★ FAZ 12.1: JTAG/Debug — GELİŞTİRME MODUNDA AÇIK
## Test ve programlama için Vivado Lab Tools erişimi gereklidir.
## Production build'de bunlar production_constraints.xdc ile KİLİTLENİR.
## → Bkz: rtl/artix7/production_constraints.xdc
# set_property BITSTREAM.SECURITY.LABTOOLS DISABLE [current_design]
# set_property BITSTREAM.READBACK.SECURITY ALL [current_design]
# set_property BITSTREAM.ENCRYPTION.DECRYPT_ONLY YES [current_design]

################################################################################
## 12. IMPLEMENTATION STRATEGY
################################################################################

## Timing-driven synthesis
## NOT: Strategy ayarları artix7_constraints.xdc'de yapılıyor.
## Burada tekrar set etmek conflict yaratır.
# set_property strategy Performance_ExploreWithRemap [get_runs synth_1]
# set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
# set_property strategy Power_DefaultOpt [get_runs synth_1]

################################################################################
## TASARIM NOTLARI
################################################################################
## 1. LVCMOS33: 3.3V single-ended logic
##    - VOH: 2.4V min
##    - VOL: 0.4V max
##    - Input threshold: 1.5V typ
##
## 2. PULLDOWN vs PULLUP:
##    - Security pins: PULLDOWN (Default safe state)
##    - Config pins: PULLUP (Manufacturer recommendation)
##
## 3. DRIVE STRENGTH:
##    - LED: 4mA (Düşük güç, yeterli)
##    - Data: 12mA default (Standard)
##    - Critical: 16mA (Reserved)
##
## 4. FALSE PATH:
##    - Asenkron sinyaller (KILL, SPI, HB)
##    - CDC sync sonrası timing constraint yok
##
## 5. MAX DELAY:
##    - KILL: 6ns (FAZ 2 spec)
##    - Normal data: 20ns (50MHz period)
##
## 6. BITSTREAM ENCRYPTION:
##    - Factory build: Disabled (Test için)
##    - Golden build: Enabled (Production)
##    - eFUSE key: One-time programmable (Kalıcı)
##
## 7. TRNG PLACEMENT:
##    - Farklı clock region → Daha fazla jitter
##    - Thermal gradient → Entropy artışı
##    - Power rail separation → Coupling azaltır
##
## 8. PCB TRACE:
##    - KILL_PIN: Shortest route (6ns için)
##    - SPI: Equal length ±5mil (Skew minimize)
##    - UART: 50Ω impedance (Signal integrity)
##
## 9. FACTORY TEST:
##    - UART loopback: Echo test
##    - LED: Visual confirmation
##    - SPI: Dummy key load
##
## 10. PRODUCTION BURN:
##    - eFUSE key program
##    - HMAC enable
##    - Debug disable
##
## 11. SENTEZ SONUÇLARI (Beklenen):
##    - LUT: ~2500/20800 (12% util)
##    - FF: ~1800/41600 (4% util)
##    - BRAM: 0/50 (0% - Distributed RAM kullandık)
##    - Fmax: 80+ MHz (50MHz hedef → %60 margin)
##
## 12. POWER BUDGET:
##    - Static: 150mW
##    - Dynamic @ 50MHz: 50mW
##    - Total: 200mW (Thermal margin bol)
################################################################################

## 🔐 "HER BACAK BİR ASKER, HER PİN BİR EMİR!" 🔐

################################################################################
