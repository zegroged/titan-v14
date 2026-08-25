################################################################################
# PROJECT TITAN V14: Artix-7 Floorplanning Script
# Amac: KILL_PROTOCOL + AEGIS + PVT modullerini korumak
################################################################################
# V14 DEGISIKLIK:
#   [NEW] AEGIS anomaly detection pblock (center die - max sensor coverage)
#   [NEW] PVT monitor pblock (vertical spanning - diverse RO placement)
#   [MOD] Header V13 -> V14
#
# STRATEJI: KILL logic'i I/O banklarina yakin yerlestir.
#           FPGA ortasi delinirse bile, kenar I/O banklari hayatta kalip
#           son emri (kill) verebilmeli.
#           AEGIS logic'i merkeze yerlestir (ESN sensor coverage maximize).
#
# KOMUTAN SERHI: "Sol Alt Kose diye ezbere yerlestirme! HARITAYI OKU!
#                 KILL_PIN fiziksel olarak hangi bank'taysa, logic o bank'in
#                 dibine yerlesecek."
################################################################################

puts "=========================================="
puts "  TITAN V14: Floorplan Script Baslatildi"
puts "=========================================="

################################################################################
## ADIM 1: KILL_PIN Fiziksel Konumunu Bul
################################################################################
## Bu script calistirilmadan once Vivado I/O Planning yapilmali
## KILL_PIN hangi I/O Bank'ta? (Ornek: Bank 14, Bank 34, vs.)
##
## ONEMLI: Asagidaki koordinatlar VARSAYIMDIR!
##         Gercek PCB'ye gore guncellenmelidir!
################################################################################

# KILL_PIN'in bagli oldugu I/O Bank (gercek PCB'den alinacak)
set kill_pin_bank "BANK14"  ;# Ornek: Bank 14 (Sol-Alt bolge)

puts "INFO: KILL_PIN I/O Bank: $kill_pin_bank"

################################################################################
## ADIM 2: Pblock Olustur (KILL_PROTOCOL icin)
################################################################################

# Pblock tanimla
create_pblock pblock_kill_protocol

puts "INFO: Pblock 'pblock_kill_protocol' olusturuldu"

################################################################################
## ADIM 3: Pblock Koordinatlari (I/O Bank'a Gore)
################################################################################
## Artix-7 100T (CSG324 package) koordinat sistemi:
##   - SLICE_X0Y0 -> Sol-alt kose
##   - SLICE_X100Y249 -> Sag-ust kose (yaklasik)
##
## Bank 14 (Sol-Alt) icin: X=0-20, Y=0-50
## Bank 34 (Sag-Ust) icin: X=80-100, Y=200-249
################################################################################

if {$kill_pin_bank == "BANK14"} {
    # Sol-Alt bolge (Bank 14 yakininda)
    resize_pblock pblock_kill_protocol -add {SLICE_X0Y0:SLICE_X20Y50}
    resize_pblock pblock_kill_protocol -add {RAMB18_X0Y0:RAMB18_X0Y10}
    puts "INFO: Pblock Bank 14 yakinina yerlestirildi (Sol-Alt)"
    
} elseif {$kill_pin_bank == "BANK34"} {
    # Sag-Ust bolge (Bank 34 yakininda)
    resize_pblock pblock_kill_protocol -add {SLICE_X80Y200:SLICE_X100Y249}
    resize_pblock pblock_kill_protocol -add {RAMB18_X5Y40:RAMB18_X5Y49}
    puts "INFO: Pblock Bank 34 yakinina yerlestirildi (Sag-Ust)"
    
} else {
    puts "WARNING: Bilinmeyen I/O Bank! Varsayilan yerlestirme (Sol-Alt) kullaniliyor."
    resize_pblock pblock_kill_protocol -add {SLICE_X0Y0:SLICE_X20Y50}
}

################################################################################
## ADIM 4: KILL_PROTOCOL Hiyerarsisini Pblock'a Ata
################################################################################

# Kill protocol hucrelerini bul ve Pblock'a ekle
set kill_cells [get_cells -hierarchical -filter {NAME =~ "*kill_inst*"}]

if {[llength $kill_cells] > 0} {
    add_cells_to_pblock pblock_kill_protocol $kill_cells
    puts "INFO: [llength $kill_cells] adet KILL_PROTOCOL hucresi Pblock'a eklendi"
} else {
    puts "WARNING: KILL_PROTOCOL hucreleri bulunamadi! Sentez tamamlanmis mi?"
}

################################################################################
## ADIM 5: Pblock Kisitlamalari (Routing Containment)
################################################################################

# Routing bu Pblock icinde SOFT kalacak (IS_SOFT default true)
# NOT: CONTAIN_ROUTING=true, dar pblock'larda unroutable net yaratir!
# set_property CONTAIN_ROUTING true [get_pblocks pblock_kill_protocol]
puts "INFO: Pblock kill_protocol IS_SOFT (routing esneklik)"

# Onceliklendirme: KILL_PROTOCOL once yerlestirilir (diger modullerden once)
# NOT: HD.PBLOCK_LEVEL Vivado 2025.2'de kaldirildi, catch ile sar
if {[catch {set_property HD.PBLOCK_LEVEL 1 [get_pblocks pblock_kill_protocol]} err]} {
    puts "WARNING: HD.PBLOCK_LEVEL desteklenmiyor (Vivado 2025.2+), atlaniyor: $err"
} else {
    puts "INFO: Pblock oncelik seviyesi 1 (En yuksek)"
}

################################################################################
## ADIM 6: Dogrulama ve Raporlama
################################################################################

# Pblock durumunu kontrol et
if {[get_pblocks -quiet pblock_kill_protocol] != ""} {
    puts "SUCCESS: Pblock basariyla yapilandirildi"
    
    # Utilization raporu
    file mkdir reports
    report_utilization -pblocks pblock_kill_protocol -file reports/pblock_kill_util.rpt
    puts "INFO: Pblock utilization raporu -> reports/pblock_kill_util.rpt"
    
} else {
    puts "ERROR: Pblock olusturulamadi!"
    return -code error
}

################################################################################
## ADIM 7: AEGIS Anomaly Detection Pblock (V14 NEW)
################################################################################
## AEGIS ESN + Readout + Anomaly modulleri merkeze yerlestirilir.
## Amac: Tum die'i kapsayan sensor metrik toplamak icin merkezi konum.
################################################################################

create_pblock pblock_aegis
resize_pblock pblock_aegis -add {SLICE_X30Y80:SLICE_X70Y170}
puts "INFO: AEGIS pblock olusturuldu (Center Die)"

set aegis_cells [get_cells -hierarchical -filter {NAME =~ "*aegis*"}]
if {[llength $aegis_cells] > 0} {
    add_cells_to_pblock pblock_aegis $aegis_cells
    puts "INFO: [llength $aegis_cells] adet AEGIS hucresi pblock'a eklendi"
} else {
    puts "WARNING: AEGIS hucreleri bulunamadi!"
}

################################################################################
## ADIM 8: PVT Monitor Pblock (V14 NEW)
################################################################################
## PVT ring osilatorleri farkli die bolgeleri icin cesitlilik saglamalidir.
## Dikey yayilim: farkli PVT kosullari gozlemlenir.
################################################################################

create_pblock pblock_pvt_monitor
resize_pblock pblock_pvt_monitor -add {SLICE_X90Y0:SLICE_X113Y149}
puts "INFO: PVT Monitor pblock olusturuldu (Right Edge, full vertical — device-aware)"

set pvt_cells [get_cells -hierarchical -filter {NAME =~ "*pvt*"}]
if {[llength $pvt_cells] > 0} {
    add_cells_to_pblock pblock_pvt_monitor $pvt_cells
    puts "INFO: [llength $pvt_cells] adet PVT hucresi pblock'a eklendi"
} else {
    puts "WARNING: PVT hucreleri bulunamadi!"
}

puts "=========================================="
puts "  Floorplan Tamamlandi!"
puts "  Pblocks: kill_protocol, aegis, pvt_monitor"
puts "=========================================="

################################################################################
## MANUEL DOGRULAMA KOMUTLARI (Vivado TCL Console'da)
################################################################################
# get_pblocks
# report_pblock_utilization pblock_kill_protocol
# report_pblock_utilization pblock_aegis
# report_pblock_utilization pblock_pvt_monitor
# get_property LOC [get_cells kill_protocol_inst/state_reg*]
################################################################################
