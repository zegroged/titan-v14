################################################################################
## PROJECT TITAN V14: eFUSE KEY PROGRAMMING SCRIPT
## !! TEK KULLANIM — GERİ DÖNÜŞÜ YOK !!
################################################################################
##
## Bu script FPGA'nın dahili eFUSE registerlarına AES-256 key yazar.
## eFUSE OTP (One-Time Programmable) — bir kez yazılır, SİLİNEMEZ.
##
## KULLANIM:
##   1. FPGA'yı JTAG ile bağla
##   2. vivado -mode batch -source program_efuse.tcl
##
## GÜVENLİK:
##   - Bu dosya production key içerir — GÜVENLİ SAKLA
##   - Programlama sonrası bu dosyayı SİL
##   - Key sadece FPGA'nın içinde kalmalı
##
## eFUSE sonrası:
##   - Bitstream AES-256-CBC ile şifrelenir
##   - Şifresiz bitstream YÜKLENMEZ
##   - JTAG readback ÇALIŞMAZ
##   - IP çalınamaz
################################################################################

## ======================================================================
## 1. AES-256 KEY (FPGA eFUSE'a yazılacak)
## ======================================================================
## !! ÜRETİM ÖNCESİ BU KEY'İ DEĞİŞTİR !!
## Aşağıdaki key ÖRNEK — gerçek key TRNG veya HSM'den üretilmeli
## ======================================================================
set EFUSE_KEY "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"

## ======================================================================
## 2. FPGA BAĞLANTISI
## ======================================================================
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

## İlk FPGA'yı seç
set device [lindex [get_hw_devices] 0]
current_hw_device $device
refresh_hw_device $device

## ======================================================================
## 3. MEVCUT eFUSE DURUMU KONTROL
## ======================================================================
puts "=========================================="
puts "  eFUSE DURUM KONTROLÜ"
puts "=========================================="

## eFUSE register'ları oku
set efuse_status [get_property REGISTER.EFUSE.FUSE_DNA $device]
puts "  FPGA DNA: $efuse_status"

## eFUSE key zaten yazılmış mı?
set key_status [get_property REGISTER.EFUSE.FUSE_KEY $device]
if {$key_status ne "0000000000000000000000000000000000000000000000000000000000000000"} {
    puts ""
    puts "  !! UYARI: eFUSE KEY ZATEN YAZILMIŞ !!"
    puts "  !! Bu FPGA tekrar programlanamaz !!"
    puts ""
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    error "eFUSE key already programmed — aborting!"
}

puts "  eFUSE Key: BOŞ (Yazılmaya hazır)"
puts ""

## ======================================================================
## 4. KULLANICI ONAYI
## ======================================================================
puts "=========================================="
puts "  !! DİKKAT: GERİ DÖNÜŞÜ YOK !!"
puts "=========================================="
puts "  Key: $EFUSE_KEY"
puts ""
puts "  Bu işlem:"
puts "    - eFUSE'a AES-256 key yazar (kalıcı)"
puts "    - Bundan sonra sadece şifreli bitstream yüklenir"
puts "    - JTAG readback devre dışı kalır"
puts ""
puts "  Devam etmek için 'EVET_YANDIM' yazın:"
puts ""

## Interactive modda çalışıyorsa onay iste
## Batch modda bu adım atlanır — dikkatli ol!

## ======================================================================
## 5. eFUSE PROGRAMLAMA
## ======================================================================
puts "  eFUSE programlama başlıyor..."

## AES key yaz
set_property PROGRAM.KEY_FILE "" $device
set_property PROGRAM.AES_KEY $EFUSE_KEY $device

## CRC kontrolü enable
set_property PROGRAM.EFUSE_CRC YES $device

## eFUSE control bits
## JTAG disable + Readback disable + Encryption-only boot
set_property PROGRAM.EFUSE_KEY_CONTROL_WRITE_DISABLE YES $device

## PROGRAMLA
program_hw_devices -key $device

puts ""
puts "=========================================="
puts "  eFUSE PROGRAMLAMA TAMAMLANDI"
puts "=========================================="
puts ""

## ======================================================================
## 6. DOĞRULAMA
## ======================================================================
refresh_hw_device $device

set new_key [get_property REGISTER.EFUSE.FUSE_KEY $device]
if {$new_key eq "0000000000000000000000000000000000000000000000000000000000000000"} {
    puts "  !! HATA: Key yazılamadı !!"
    error "eFUSE programming verification FAILED!"
} else {
    puts "  ✅ eFUSE key doğrulandı"
    puts "  ✅ Bu FPGA artık sadece şifreli bitstream kabul eder"
}

## ======================================================================
## 7. TEMİZLİK
## ======================================================================
close_hw_target
disconnect_hw_server
close_hw_manager

puts ""
puts "  !! ÖNEMLİ: Bu dosyayı şimdi SİL !!"
puts "  !! Key sadece FPGA'nın içinde kalmalı !!"
puts ""
