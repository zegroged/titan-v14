################################################################################
## PROJECT TITAN V14: PRODUCTION SECURITY CONSTRAINTS
## ★ FAZ 12.1: Sadece ÜRETİM bitstreaminde kullanılır
################################################################################
## AMAC: Test/geliştirme constraint'lerine EK olarak yüklenir.
##       Vivado'da: Add Sources → Add Constraints → production_constraints.xdc
##       Sadece "Golden Image" (fabrika delivery) build'inde aktif edilir.
##
## KULLANIM:
##   GELİŞTİRME: master_constraints.xdc (JTAG AÇIK)
##   ÜRETİM:     master_constraints.xdc + production_constraints.xdc (JTAG KİLİTLİ)
##
## DİKKAT: Bu dosya aktifken Vivado ile debug/program YAPILAMAZ.
##         eFUSE yakıldıktan sonra GERİ DÖNÜŞ YOKTUR.
################################################################################

## ═══════════════════════════════════════════════════════════════════════════
## 1. JTAG / DEBUG TAM KİLİT
## ═══════════════════════════════════════════════════════════════════════════

## Vivado Lab Tools (ILA, VIO, ChipScope) engellenir
## Saldırgan IC debugger ile internal register'ları okuyamaz
set_property BITSTREAM.SECURITY.LABTOOLS DISABLE [current_design]

## Bitstream readback tamamen kapalı
## Programlanmış bitstream FPGA'dan geri okunamaz
set_property BITSTREAM.READBACK.SECURITY ALL [current_design]

## ═══════════════════════════════════════════════════════════════════════════
## 2. DECRYPT-ONLY MODE (Tek Yönlü Geçit)
## ═══════════════════════════════════════════════════════════════════════════

## FPGA sadece eFUSE key ile şifrelenmiş bitstream kabul eder
## Şifresiz veya farklı key ile şifrelenmiş bitstream → REJECT
## ★ DİKKAT: eFUSE yakıldıktan sonra bu ayar kalıcıdır!
set_property BITSTREAM.ENCRYPTION.DECRYPT_ONLY YES [current_design]

## ═══════════════════════════════════════════════════════════════════════════
## 3. eFUSE AES-256 ENCRYPTION (Tekrar — production override)
## ═══════════════════════════════════════════════════════════════════════════

## AES-256 bitstream encryption aktif (eFUSE key)
set_property BITSTREAM.ENCRYPTION.ENCRYPT YES [current_design]
set_property BITSTREAM.ENCRYPTION.ENCRYPTKEYSELECT eFUSE [current_design]

## ═══════════════════════════════════════════════════════════════════════════
## 4. STARTUP SEQUENCEGÜVENLİĞİ
## ═══════════════════════════════════════════════════════════════════════════

## GTS (Global Three-State) → configuration tamamlanana kadar I/O tri-state
## Yarım yüklenmiş bitstream ile pin'ler aktif olmasın
set_property BITSTREAM.STARTUP.GTS_CYCLE Done [current_design]

## GWE (Global Write Enable) → Done sonrası write enable
set_property BITSTREAM.STARTUP.GWE_CYCLE Done [current_design]

################################################################################
## 🔐 "ÜRETİM BİTSTREAMİ: TEK YÖNLÜ GEÇİT — GERİ DÖNÜŞ YOK" 🔐
################################################################################
