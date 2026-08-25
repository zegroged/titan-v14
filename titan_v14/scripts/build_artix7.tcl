################################################################################
# PROJECT TITAN V13: Vivado Build Script (Artix-7)
# Amaç: Tam otomatik sentez, implementation ve raporlama
################################################################################

puts "=========================================="
puts "  PROJECT TITAN V13: Vivado Build"
puts "=========================================="

# Önceki projeyi kapat (varsa)
close_project -quiet

################################################################################
## PROJE OLUŞTUR
################################################################################

set project_name "titan_v13_artix7"
set project_dir "./vivado_artix7"
set part_number "xc7a100tcsg324-1"

# Dizini temizle (tam yeniden oluşturacağız)
file delete -force $project_dir

# Yeni proje oluştur
create_project $project_name $project_dir -part $part_number -force

puts "INFO: Proje '$project_name' oluşturuldu"

################################################################################
## RTL DOSYALARINI EKLE
################################################################################

# VHDL dosyaları (common + artix7 modüller)
add_files {
    ../rtl/common/kill_protocol.vhd
    ../rtl/common/uart_telemetry.vhd
    ../rtl/common/crypto_core_stub.vhd
    ../rtl/common/system_supervisor.vhd
    ../rtl/artix7/artix7_clocking.vhd
    ../rtl/artix7/artix7_top.vhd
}

puts "INFO: RTL dosyaları eklendi (6 modül)"

# VHDL dilini VHDL-2008 olarak ayarla
set_property file_type {VHDL 2008} [get_files *.vhd]

################################################################################
## CONSTRAINT DOSYALARINI EKLE
################################################################################

add_files -fileset constrs_1 {
    ../rtl/artix7/artix7_constraints.xdc
}

puts "INFO: Constraint dosyası eklendi"

################################################################################
## TOP MODULE AYARLA
################################################################################
set_property top artix7_top [current_fileset]
update_compile_order -fileset sources_1

puts "INFO: Top module 'artix7_top' ayarlandı"

################################################################################
## SENTEZ (SYNTHESIS)
################################################################################

puts "=========================================="
puts "  SENTEZ BAŞLATILIYOR..."
puts "=========================================="

# Sentez parametreleri
set_property strategy Performance_ExploreWithRemap [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AlternateRoutability [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]

# Sentez çalıştır
launch_runs synth_1 -jobs 4
wait_on_run synth_1

# Sentez kontrolü
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Sentez başarısız!"
    return -code error
}

puts "SUCCESS: Sentez tamamlandı"

################################################################################
## RAPORLAR (Sentez Sonrası)
################################################################################

# Rapor dizini oluştur
file mkdir reports

open_run synth_1 -name synth_1

# Utilization Report (BUFG kontrolü için kritik!)
report_utilization -file reports/synth_utilization.rpt
report_utilization -hierarchical -file reports/synth_utilization_hierarchical.rpt

puts "✓ Utilization Report → reports/synth_utilization.rpt"

# Clock Utilization (BUFG sayısı burada)
report_clock_utilization -file reports/synth_clock_util.rpt

puts "✓ Clock Utilization Report → reports/synth_clock_util.rpt"
puts "  KRİTİK: BUFG kullanımı kontrol edilecek!"

# Timing Estimate
report_timing_summary -delay_type min_max -file reports/synth_timing_summary.rpt

puts "✓ Timing Summary → reports/synth_timing_summary.rpt"

################################################################################
## FLOORPLANNING UYGULA
################################################################################

puts "=========================================="
puts "  FLOORPLANNING UYGULAN IYO..."
puts "=========================================="

source {../scripts/floorplan_artix7.tcl}

puts "SUCCESS: Floorplan uygulandı"

################################################################################
## IMPLEMENTATION (Placement + Routing)
################################################################################

puts "=========================================="
puts "  IMPLEMENTATION BAŞLATILIYOR..."
puts "=========================================="

# Implementation parametreleri
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AlternateCLBRouting [get_runs impl_1]

# Implementation çalıştır
launch_runs impl_1 -jobs 4
wait_on_run impl_1

# Implementation kontrolü
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation başarısız!"
    return -code error
}

puts "SUCCESS: Implementation tamamlandı"

################################################################################
## RAPORLAR (Implementation Sonrası)
################################################################################

open_run impl_1

# Utilization Report (Final)
report_utilization -file reports/impl_utilization.rpt

puts "✓ Implementation Utilization → reports/impl_utilization.rpt"

# Timing Summary (KOMUTAN'IN İSTEDİĞİ RAPOR #2)
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 10 -input_pins -routable_nets \
    -file reports/impl_timing_summary.rpt

puts "✓✓ TIMING SUMMARY (Kritik!) → reports/impl_timing_summary.rpt"
puts "   Positive Slack var mı kontrol edilecek"

# Clock Skew Report (KOMUTAN'IN İSTEDİĞİ RAPOR #3)
report_clock_networks -file reports/impl_clock_networks.rpt

puts "✓✓ CLOCK SKEW REPORT → reports/impl_clock_networks.rpt"
puts "   KILL sinyali skew <500ps olmalı"

# DRC (Design Rule Check)
report_drc -file reports/impl_drc.rpt

puts "✓ DRC Report → reports/impl_drc.rpt"

# Power Analysis
report_power -file reports/impl_power.rpt

puts "✓ Power Report → reports/impl_power.rpt"


################################################################################
## BİTSTREAM OLUŞTUR
################################################################################

puts "=========================================="
puts "  BİTSTREAM OLUŞTURULUYOR..."
puts "=========================================="

# Bitstream generation
write_bitstream -force $project_dir/titan_v13.bit

puts "✓✓ BITSTREAM → $project_dir/titan_v13.bit"
puts "   Boyut: [file size $project_dir/titan_v13.bit] bytes"

################################################################################
## ÖZET RAPOR
################################################################################

puts ""
puts "=========================================="
puts "  BUILD TAMAMLANDI!"
puts "=========================================="
puts ""
puts "KOMUTAN'IN İSTEDİĞİ 3 İSTİHBARAT:"
puts "  1. Utilization Report: reports/impl_utilization.rpt"
puts "     → BUFG kullanımını kontrol edin"
puts ""
puts "  2. Timing Summary: reports/impl_timing_summary.rpt"
puts "     → Worst Negative Slack (WNS): Pozitif olmalı"
puts "     → KILL_PIN max_delay <6ns olmalı"
puts ""
puts "  3. Clock Skew: reports/impl_clock_networks.rpt"
puts "     → KILL sinyali skew <500ps olmalı"
puts ""
puts "=========================================="
puts ""

# Proje directoryi geçerli path olarak ayarla
cd $project_dir
puts "Vivado GUI açmak için: vivado $project_name.xpr"

################################################################################
## SCRIPT SONU
################################################################################
