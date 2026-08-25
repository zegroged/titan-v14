################################################################################
# PROJECT TITAN V13: Microchip PolarFire Floorplanning Script
# Amaç: KILL_PROTOCOL modülünü I/O banklarına yakın yerleştirmek
################################################################################
# STRATEJI: Drilling attack'e karşı savunma
################################################################################

puts "=========================================="
puts "  TITAN V13: PolarFire Floorplan"
puts "=========================================="

################################################################################
## ADIM 1: Region Oluştur (PolarFire'da "Pblock" yerine "Region" kullanılır)
################################################################################

create_region -name REGION_KILL_PROTOCOL -type hard

puts "INFO: Region 'REGION_KILL_PROTOCOL' oluşturuldu (hard constraint)"

################################################################################
## ADIM 2: Region Koordinatları
################################################################################
## PolarFire MPF100T koordinat sistemi (örnek):
##   - Sol-Alt: (0, 0)
##   - Sağ-Üst: (100, 200) (yaklaşık)
##
## KILL_PIN I/O Bank 1 yakınında → Sol-Alt bölge
################################################################################

# Region alanını tanımla (x_min y_min x_max y_max)
set_region -region REGION_KILL_PROTOCOL -area {0 0 30 60}

puts "INFO: Region koordinatları: (0,0) → (30,60) [Sol-Alt bölge]"

################################################################################
## ADIM 3: KILL_PROTOCOL'ü Region'a Ata
################################################################################

# Kill protocol instance'ını region'a assign et
assign_region -region REGION_KILL_PROTOCOL [get_cells -hierarchical kill_protocol_inst]

puts "INFO: KILL_PROTOCOL instance 'kill_protocol_inst' region'a atandı"

################################################################################
## ADIM 4: Doğrulama ve Raporlama
################################################################################

# Region durumunu rapor et
report_region REGION_KILL_PROTOCOL

puts "SUCCESS: Floorplan tamamlandı!"
puts ""
puts "Libero GUI'de kontrol edin:"
puts "  Design → Floorplanner"
puts "  Region 'REGION_KILL_PROTOCOL' görünmeli"
puts ""

################################################################################
## NOT: PolarFire'da Xilinx kadar detaylı floorplan araçları yoktur.
##      Bu script temel yerleştirme için örnektir.
##      Daha detaylı kontrol için Libero GUI kullanılmalıdır.
################################################################################
