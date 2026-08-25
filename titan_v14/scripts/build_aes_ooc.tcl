set part xc7a100tcsg324-1
set top artix7_top_v14
set src_dir {C:/Temp/aegis_build/src}
set prj_dir {C:/Temp/aegis_build/vivado_aes_prj}
set rpt_dir {C:/Temp/aegis_build/reports_aes}

# Clean previous
file delete -force $prj_dir
file mkdir $rpt_dir

# Create project
create_project titan_v14_aes $prj_dir -part $part -force
set_property target_language VHDL [current_project]

# Add sources
set vhd_files [glob -directory $src_dir *.vhd]
add_files -norecurse $vhd_files
set_property file_type {VHDL 2008} [get_files *.vhd]

# Add OOC constraints inline
set xdc_file "$rpt_dir/ooc_constraints.xdc"
set fp [open $xdc_file w]
puts $fp {create_clock -period 20.000 -name sys_clk [get_ports CLK_100MHZ]}
puts $fp {set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets -hierarchical -filter {NAME =~ *ring*}]}
puts $fp {set_property SEVERITY {Warning} [get_drc_checks LUTLP-1]}
puts $fp {set_false_path -from [get_clocks sys_clk] -to [get_clocks sys_clk]}
close $fp
add_files -fileset constrs_1 $xdc_file

# Set top
set_property top $top [current_fileset]

# Configure synthesis
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]

# Launch synthesis
launch_runs synth_1 -jobs 2
wait_on_run synth_1

# Check status
if {[get_property STATUS [get_runs synth_1]] eq "synth_design Complete!"} {
    puts "=== SYNTHESIS PASSED ==="
    open_run synth_1

    report_utilization -file "$rpt_dir/utilization.rpt"
    report_utilization -hierarchical -file "$rpt_dir/utilization_hierarchical.rpt"
    report_timing_summary -file "$rpt_dir/timing_summary.rpt"
    report_clock_utilization -file "$rpt_dir/clock_utilization.rpt"
    write_checkpoint -force "$rpt_dir/titan_v14_aes_synth.dcp"

    puts "=== ALL REPORTS GENERATED ==="
} else {
    puts "=== SYNTHESIS FAILED ==="
    puts [get_property STATUS [get_runs synth_1]]
}

close_project
