################################################################################
# PROJECT TITAN V14: Out-of-Context Synthesis Script (Project Mode)
# Target: Xilinx Artix-7 XC7A100TCSG324-1
# Mode:   OOC (no pin assignments needed)
# NOTE:   RTL pre-staged to C:/Temp/aegis_build/src by PowerShell
################################################################################

puts "=========================================================="
puts "  PROJECT TITAN V14: Out-of-Context Synthesis"
puts "  Target: xc7a100tcsg324-1"
puts "  Mode:   out_of_context (project mode)"
puts "=========================================================="

set output_dir "C:/Temp/aegis_build"
set src_dir "$output_dir/src"
set proj_dir "$output_dir/project"

## Clean previous project
file delete -force $proj_dir

################################################################################
## CREATE PROJECT
################################################################################
puts ""
puts "--- Creating Vivado Project ---"

create_project titan_v14 $proj_dir -part xc7a100tcsg324-1 -force
set_property target_language VHDL [current_project]

################################################################################
## ADD ALL VHDL-2008 SOURCES
################################################################################
puts ""
puts "--- Adding RTL Sources ---"

set vhdl_files [lsort [glob -directory $src_dir *.vhd]]
set count 0
foreach f $vhdl_files {
    add_files -norecurse $f
    puts "  [file tail $f]"
    incr count
}
puts "INFO: $count VHDL files added"

# Set VHDL-2008 for all files
set_property file_type {VHDL 2008} [get_files *.vhd]
set_property top artix7_top_v14 [current_fileset]

################################################################################
## OOC TIMING CONSTRAINTS
################################################################################
puts ""
puts "--- Writing OOC Constraints ---"

set ooc_xdc "$output_dir/ooc_timing.xdc"
set fp [open $ooc_xdc w]
puts $fp {## 50 MHz clock}
puts $fp {create_clock -period 20.000 -name ext_clk [get_ports PIN_EXT_CLK_50MHZ]}
puts $fp {}
puts $fp {## Ring oscillator loops}
puts $fp {set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets -hierarchical -quiet *chain*]}
puts $fp {set_property SEVERITY {WARNING} [get_drc_checks LUTLP-1]}
puts $fp {}
puts $fp {## False paths: async/quasi-static inputs}
puts $fp {set_false_path -from [get_ports {RING_OSC_IN[*]}]}
puts $fp {set_false_path -from [get_ports OMEGA_ENABLE_PIN]}
puts $fp {set_false_path -from [get_ports AEGIS_ENABLE_PIN]}
puts $fp {set_false_path -from [get_ports KILL_PIN]}
puts $fp {set_false_path -from [get_ports JUMPER_CALIB]}
puts $fp {}
puts $fp {## Config}
puts $fp {set_property CFGBVS VCCO [current_design]}
puts $fp {set_property CONFIG_VOLTAGE 3.3 [current_design]}
close $fp

add_files -fileset constrs_1 -norecurse $ooc_xdc
puts "INFO: OOC constraints added"

################################################################################
## SYNTHESIS
################################################################################
puts ""
puts "=========================================================="
puts "  SYNTH_DESIGN: xc7a100tcsg324-1 (OOC)"
puts "=========================================================="

set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]

launch_runs synth_1 -jobs 2
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
set synth_progress [get_property PROGRESS [get_runs synth_1]]
puts "Synth status: $synth_status ($synth_progress)"

if {$synth_progress != "100%"} {
    puts "ERROR: Synthesis did not complete!"
    exit 1
}

puts "SUCCESS: synth_design completed"

################################################################################
## OPEN SYNTHESIZED DESIGN AND GENERATE REPORTS
################################################################################
puts ""
puts "--- Generating Reports ---"

open_run synth_1

file mkdir $output_dir/reports
report_utilization -file $output_dir/reports/utilization.rpt
report_utilization -hierarchical -file $output_dir/reports/utilization_hierarchical.rpt
report_timing_summary -delay_type min_max -file $output_dir/reports/timing_summary.rpt
report_clock_utilization -file $output_dir/reports/clock_utilization.rpt

puts "  utilization.rpt"
puts "  utilization_hierarchical.rpt"
puts "  timing_summary.rpt"
puts "  clock_utilization.rpt"

################################################################################
## SCREEN OUTPUT
################################################################################
puts ""
puts "=========================================================="
puts "  UTILIZATION SUMMARY"
puts "=========================================================="
puts [report_utilization -return_string]

puts ""
puts "=========================================================="
puts "  TIMING SUMMARY"
puts "=========================================================="
puts [report_timing_summary -return_string]

################################################################################
## CHECKPOINT
################################################################################
write_checkpoint -force $output_dir/titan_v14_synth.dcp

puts ""
puts "=========================================================="
puts "  BUILD COMPLETE"
puts "=========================================================="
puts "  Reports:    $output_dir/reports/"
puts "  Checkpoint: $output_dir/titan_v14_synth.dcp"
puts "=========================================================="
