################################################################################
## PROJECT TITAN V14: Vivado Constraints — AEGIS/Omega/PVT Additions
## Import this AFTER artix7_constraints.xdc
################################################################################

########################################
## ★ FIX #7: V14 PIN ASSIGNMENTS — ACTIVE (XC7A100T-CSG324 Bank 14/15)
## Previously commented out; now active with conflict-free pin assignments.

## Ring Oscillator Inputs (PVT Monitor — 4 adet)
## Bank 14 — ayrı SPI/UART pin'lerinden uzak, CDC synchronizer var
set_property -dict { PACKAGE_PIN T14   IOSTANDARD LVCMOS33 } [get_ports {RING_OSC_IN[0]}]
set_property -dict { PACKAGE_PIN T15   IOSTANDARD LVCMOS33 } [get_ports {RING_OSC_IN[1]}]
set_property -dict { PACKAGE_PIN U14   IOSTANDARD LVCMOS33 } [get_ports {RING_OSC_IN[2]}]
set_property -dict { PACKAGE_PIN R13   IOSTANDARD LVCMOS33 } [get_ports {RING_OSC_IN[3]}]

## Omega Cloak Master Enable (DIP switch)
## Bank 15 — quasi-static, false_path zaten tanımlı
set_property -dict { PACKAGE_PIN L16   IOSTANDARD LVCMOS33 } [get_ports OMEGA_ENABLE_PIN]

## AEGIS Enable (DIP switch)
set_property -dict { PACKAGE_PIN M13   IOSTANDARD LVCMOS33 } [get_ports AEGIS_ENABLE_PIN]

## LED_OMEGA_ACTIVE: already assigned in master_constraints.xdc (L4)
## Do NOT re-assign here to avoid pin conflict

########################################
## V14 FALSE PATH: Ring Oscillator CDC
########################################
## RING_OSC_IN sinyalleri tamamen asenkron.
## 2-stage synchronizer ile CDC yapılıyor, timing analizi gereksiz.
set_false_path -from [get_ports {RING_OSC_IN[*]}]

## Ring oscillator internal CDC synchronizer'lar — ASYNC_REG olarak işaretli
## Vivado otomatik olarak FDRE bitişik yerleştirme yapacak
## (ASYNC_REG attribute VHDL'de zaten tanımlı)

########################################
## V14 INPUT DELAY: Control Pins
########################################
set_input_delay -clock ext_clk 5.000 [get_ports OMEGA_ENABLE_PIN]
set_input_delay -clock ext_clk 5.000 [get_ports AEGIS_ENABLE_PIN]

## Quasi-static: bu sinyaller çalışma sırasında nadiren değişir
set_false_path -from [get_ports OMEGA_ENABLE_PIN]
set_false_path -from [get_ports AEGIS_ENABLE_PIN]

########################################
## V14 OUTPUT DELAY: LED
########################################
set_output_delay -clock ext_clk 2.000 [get_ports LED_OMEGA_ACTIVE]

########################################
## V14 OMEGA CLOAK: MMCM Constraints
########################################
## Omega Cloak'un MMCME2_ADV'si (clock_jitter_injector) ikinci MMCM
## Artix-7 100T: 6 MMCM, V14 kullanım: 2/6

## Omega jittered clock: Vivado auto-derives generated clocks from MMCME2_ADV.
## Manual constraint removed — pin hierarchy path was incorrect after synthesis.
## set_clock_uncertainty applied to the auto-derived clock instead.
# create_generated_clock -name omega_jittered_clk \
#     -source [get_pins omega_inst/u_jitter/u_mmcm/CLKIN1] \
#     -master_clock sys_clk \
#     [get_pins omega_inst/u_jitter/u_mmcm/CLKOUT0]
# set_clock_uncertainty 2.0 [get_clocks omega_jittered_clk]

########################################
## V14 PVT MONITOR: DONT_TOUCH
########################################
## PVT ring oscillator counter'lar optimize edilmemeli
set_property DONT_TOUCH TRUE [get_cells -hierarchical -filter {NAME =~ *pvt_inst*}]
## NOT: ring_osc_counter pvt_inst içinde, ayrı wildcard gereksiz.
# set_property DONT_TOUCH TRUE [get_cells -hierarchical -filter {NAME =~ *ring_osc_counter*}]

########################################
## V14 AEGIS: Multi-Cycle Paths
########################################
## ESN reservoir MAC operations can take multiple cycles
## (Relaxed timing — ESN output rate << clock rate)
# set_multicycle_path -setup 4 -from [get_cells -hierarchical -filter {NAME =~ *aegis_inst*reservoir*}]
# set_multicycle_path -hold 3 -from [get_cells -hierarchical -filter {NAME =~ *aegis_inst*reservoir*}]

########################################
## V14 OMEGA CLOAK: DONT_TOUCH (Shadow Datapath)
########################################
## Dummy operation shadow datapath optimize edilmemeli
## (Optimize edilirse power profile farklılaşır → DPA koruması zayıflar!)
## ★ FIX #3: Aktifleştirildi — Vivado bu logic'i optimize edemez
set_property DONT_TOUCH TRUE [get_cells -hierarchical -filter {NAME =~ *omega_inst*shadow*}]
set_property DONT_TOUCH TRUE [get_cells -hierarchical -filter {NAME =~ *omega_inst*dummy*}]

## Chaotic PRNG optimize edilmemeli (chaos orbit bozulur)
set_property DONT_TOUCH TRUE [get_cells -hierarchical -filter {NAME =~ *omega_inst*prng*}]

################################################################################
## V14 KAYNAK KULLANIM TAHMİNİ
################################################################################
## V13:    1 MMCM,   ~350 FF,   ~200 LUT
## V14:    2 MMCM, ~2,500 FF, ~3,500 LUT
## Artix-7 100T: 6 MMCM, 126,800 FF, 63,400 LUT
## Utilization: <4% (hedef: <80%)
################################################################################

########################################
## V15 CALLWHITE: BLACK UART CTS/RTS
########################################
## MCU <-> FPGA flow control for Callwhite cellular module
## Bank 15 — LVCMOS33, same bank as other control pins
set_property -dict { PACKAGE_PIN N14   IOSTANDARD LVCMOS33 } [get_ports BLACK_UART_CTS_PIN]
set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports BLACK_UART_RTS_PIN]

## I/O timing
set_input_delay -clock ext_clk 5.000 [get_ports BLACK_UART_CTS_PIN]
set_output_delay -clock ext_clk 2.000 [get_ports BLACK_UART_RTS_PIN]

