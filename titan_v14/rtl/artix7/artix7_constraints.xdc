################################################################################
## PROJECT TITAN V13: Vivado Constraints (Xilinx Artix-7)
## Timing, Placement, and Synthesis Constraints
################################################################################

########################################
## FAZ 9: TRNG RING OSCILLATOR CONSTRAINTS
########################################
## Ring oscillator intentionally uses combinatorial loops for entropy generation
## Sentezleyiciye "Bu bir hata değil, özellik!" diyoruz

## 1. Allow Combinatorial Loops (Ring Oscillator için zorunlu)
set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets -hierarchical "*chain*"]

## 2. DRC Check Severity (LUTLP-1: LUT Loop hatası → WARNING'e düşür)
set_property SEVERITY {WARNING} [get_drc_checks LUTLP-1]

## 3. Ring Oscillator Synthesis Protection
## trng_ring_osc instance'larının içindeki chain sinyallerini koru
## NOT: Bu constraint'ler master_constraints.xdc'de güncel haliyle tanımlı.
## Eski hücre adları artık geçersiz → master_constraints.xdc kullanılıyor.
# set_property DONT_TOUCH TRUE [get_cells -hierarchical -filter {NAME =~ *trng_ring_osc*}]
# set_property KEEP TRUE [get_nets -hierarchical -filter {NAME =~ *chain*}]

## 4. LUT Placement (Daha fazla jitter için dağılım)
## Her ring oscillator'ı farklı clock region'a yerleştir
## NOT: Bu constraint'ler floorplanning ile manuel optimize edilmeli
# set_property LOC SLICE_X10Y10 [get_cells ro_inst_1/chain[0]]
# set_property LOC SLICE_X50Y50 [get_cells ro_inst_2/chain[0]]
# set_property LOC SLICE_X90Y90 [get_cells ro_inst_3/chain[0]]

########################################
## CLOCK CONSTRAINTS
########################################
## 50 MHz harici saat (SiTime SiT5356)
create_clock -period 20.000 -name ext_clk [get_ports PIN_EXT_CLK_50MHZ]

## Derived clocks (PLL çıkışları - gelecekte)
# create_generated_clock -name sys_clk -source [get_pins clk_inst/CLKIN1] -divide_by 1 [get_pins clk_inst/CLKOUT0]

########################################
## INPUT DELAY CONSTRAINTS
########################################
## Tamper sensörü ve kontrol sinyalleri (asenkron inputs)
set_input_delay -clock ext_clk 2.000 [get_ports KILL_PIN]
set_input_delay -clock ext_clk 2.000 [get_ports JUMPER_CALIB]
set_input_delay -clock ext_clk 2.000 [get_ports PF_HEARTBEAT_IN]

## SPI Inputs (FAZ 8: Key Injection)
set_input_delay -clock ext_clk 2.000 [get_ports SPI_SCLK_PIN]
set_input_delay -clock ext_clk 2.000 [get_ports SPI_MOSI_PIN]
set_input_delay -clock ext_clk 2.000 [get_ports SPI_CS_N_PIN]

########################################
## OUTPUT DELAY CONSTRAINTS
########################################
set_output_delay -clock ext_clk 2.000 [get_ports UART_TX_PAD]
set_output_delay -clock ext_clk 2.000 [get_ports LED_STATUS_RED]
set_output_delay -clock ext_clk 2.000 [get_ports LED_STATUS_GREEN]
set_output_delay -clock ext_clk 2.000 [get_ports PF_KILL_CMD]

########################################
## FALSE PATH CONSTRAINTS (Asenkron Clock Domain Crossings)
########################################
## TRNG → AES (TRNG sürekli güncelleniyor, timing critical değil)
## NOT: Hücre adları RTL'de değişti. Güncel false path'ler master_constraints.xdc'de.
# set_false_path -from [get_cells -hierarchical -filter {NAME =~ *trng_wrapper/shift_reg*}] -to [get_cells -hierarchical -filter {NAME =~ *aes_inst/ctr_block*}]

## Kill Signal (Asenkron tamper detector), reset ile benzer
## NOT: Pin adı RTL'de değişti → master_constraints.xdc'de CDC false path tanımlı.
# set_false_path -from [get_ports KILL_PIN] -to [get_pins -hierarchical */kill_signal]

## Factory Mode Jumper (Quasi-static signal)
## NOT: Pin adı RTL'de değişti → master_constraints.xdc'de CDC false path tanımlı.
# set_false_path -from [get_ports JUMPER_CALIB] -to [get_pins -hierarchical */factory_mode]

########################################
## MULTI-CYCLE PATH (Gevşek timing constraints)
########################################
## Telemetri UART (9600 baud → timing çok gevşek)
## NOT: uart_inst artık uart_drv_inst → master_constraints.xdc'de güncellendi.
# set_multicycle_path -setup 8 -from [get_clocks ext_clk] -to [get_pins uart_inst/*]
# set_multicycle_path -hold 7 -from [get_clocks ext_clk] -to [get_pins uart_inst/*]

########################################
## PIN ASSIGNMENTS (Physical Location)
########################################
## NOT: Gerçek PCB tasarımı sonrası güncellenecek
## Şu an placeholder pinler

## Clock
# set_property PACKAGE_PIN E3 [get_ports PIN_EXT_CLK_50MHZ]
# set_property IOSTANDARD LVCMOS33 [get_ports PIN_EXT_CLK_50MHZ]

## Security
# set_property PACKAGE_PIN J15 [get_ports KILL_PIN]
# set_property IOSTANDARD LVCMOS33 [get_ports KILL_PIN]

## SPI
# set_property PACKAGE_PIN A14 [get_ports SPI_SCLK_PIN]
# set_property PACKAGE_PIN A15 [get_ports SPI_MOSI_PIN]
# set_property PACKAGE_PIN A16 [get_ports SPI_CS_N_PIN]
# set_property IOSTANDARD LVCMOS33 [get_ports SPI_*]

## LEDs
# set_property PACKAGE_PIN H17 [get_ports LED_STATUS_RED]
# set_property PACKAGE_PIN K15 [get_ports LED_STATUS_GREEN]
# set_property IOSTANDARD LVCMOS33 [get_ports LED_STATUS_*]

########################################
## SYNTHESIS STRATEGY
########################################
## Güvenlik için optimize et (area değil performance)
## NOT: get_runs XDC içinde desteklenmiyor → TCL script'te tanımlanmalı.
## synth_security.tcl içinde set_property strategy zaten ayarlanıyor.
# set_property STRATEGY Flow_PerfOptimized_high [get_runs synth_1]
# set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]

########################################
## IMPLEMENTATION STRATEGY
########################################
## NOT: get_runs XDC içinde desteklenmiyor → TCL script'te tanımlanmalı.
# set_property STRATEGY Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

########################################
## BITSTREAM GENERATION
########################################
## Bitstream şifreleme (Production - gelecek)
# set_property BITSTREAM.ENCRYPTION.ENCRYPT YES [current_design]
# set_property BITSTREAM.ENCRYPTION.ENCRYPTKEYSELECT eFUSE [current_design]

## Unused pin protection (Floating pinler güvenlik riski)
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLDOWN [current_design]

################################################################################
## END OF CONSTRAINTS
################################################################################
