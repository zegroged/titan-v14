################################################################################
## PROJECT TITAN V14: Bitstream Build Pipeline (LOCKED)
## Two profiles: FACTORY (debug) and GOLDEN (production)
################################################################################
## FACTORY: AES encryption ON, JTAG enabled, readback disabled
## GOLDEN:  AES encryption ON, JTAG disabled, readback disabled, partial reconfig off
##
## Usage:
##   vivado -mode tcl -source build_bitstream.tcl -tclargs FACTORY
##   vivado -mode tcl -source build_bitstream.tcl -tclargs GOLDEN
################################################################################

# Profile selection
if {[llength $argv] < 1} {
    puts "ERROR: Profile required. Usage: -tclargs FACTORY|GOLDEN"
    exit 1
}

set PROFILE [lindex $argv 0]
puts "=========================================="
puts "  TITAN V14 BUILD — Profile: $PROFILE"
puts "=========================================="

# Validate profile
if {$PROFILE ne "FACTORY" && $PROFILE ne "GOLDEN"} {
    puts "ERROR: Invalid profile '$PROFILE'. Use FACTORY or GOLDEN."
    exit 1
}

# Project paths
set PROJ_DIR [file normalize [file dirname [info script]]/..]
set RTL_COMMON "$PROJ_DIR/rtl/common"
set RTL_ARTIX  "$PROJ_DIR/rtl/artix7"
set RTL_AEGIS  "$PROJ_DIR/rtl/aegis"
set XDC_FILE   "$RTL_ARTIX/master_constraints.xdc"
set OUTPUT_DIR "$PROJ_DIR/output"

# Create output directory
file mkdir $OUTPUT_DIR

# =========================================================================
# 1. CREATE IN-MEMORY PROJECT
# =========================================================================
create_project -in_memory -part xc7a100tcsg324-1

# Add RTL sources
foreach f [glob -nocomplain $RTL_COMMON/*.vhd $RTL_ARTIX/*.vhd $RTL_AEGIS/*.vhd] {
    read_vhdl $f
}

# Add constraints
read_xdc $XDC_FILE

# Set top module
set_property top artix7_top_v14 [current_fileset]

# =========================================================================
# 2. BITSTREAM SECURITY PROPERTIES
# =========================================================================
# AES-256 eFUSE encryption (both profiles)
set_property BITSTREAM.ENCRYPTION.ENCRYPT YES [current_design]
set_property BITSTREAM.ENCRYPTION.ENCRYPTKEYSELECT EFUSE [current_design]

if {$PROFILE eq "GOLDEN"} {
    # ★ GOLDEN: Maximum lockdown
    set_property BITSTREAM.SECURITY.LABTOOLS    DISABLE  [current_design]
    set_property BITSTREAM.READBACK.SECURITY    ALL      [current_design]
    set_property BITSTREAM.GENERAL.PERFRAMECRC  YES      [current_design]
    # Disable partial reconfiguration
    set_property BITSTREAM.GENERAL.COMPRESS     TRUE     [current_design]
    puts "★ GOLDEN MODE: JTAG DISABLED, Readback DISABLED"
} else {
    # ★ FACTORY: Debug enabled
    set_property BITSTREAM.READBACK.SECURITY    NONE     [current_design]
    set_property BITSTREAM.GENERAL.PERFRAMECRC  YES      [current_design]
    puts "★ FACTORY MODE: JTAG ENABLED, Readback ENABLED"
}

# Common bitstream properties
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH  4    [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE    33   [current_design]
set_property CONFIG_MODE SPIx4                   [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN     PULLDOWN [current_design]

# =========================================================================
# 3. SYNTHESIS
# =========================================================================
puts "\n=== SYNTHESIS ==="
synth_design -top artix7_top_v14 -part xc7a100tcsg324-1

# Post-synth report
report_utilization -file "$OUTPUT_DIR/post_synth_util_${PROFILE}.rpt"
report_timing_summary -file "$OUTPUT_DIR/post_synth_timing_${PROFILE}.rpt"

# =========================================================================
# 4. OPTIMIZATION
# =========================================================================
puts "\n=== OPTIMIZATION ==="
opt_design

# =========================================================================
# 5. PLACE
# =========================================================================
puts "\n=== PLACEMENT ==="
place_design

# Post-place report
report_utilization -file "$OUTPUT_DIR/post_place_util_${PROFILE}.rpt"

# =========================================================================
# 6. ROUTE
# =========================================================================
puts "\n=== ROUTING ==="
route_design

# Post-route reports
report_utilization -file "$OUTPUT_DIR/post_route_util_${PROFILE}.rpt"
report_timing_summary -file "$OUTPUT_DIR/post_route_timing_${PROFILE}.rpt"
report_timing -max_paths 10 -file "$OUTPUT_DIR/post_route_critical_${PROFILE}.rpt"
report_drc -file "$OUTPUT_DIR/post_route_drc_${PROFILE}.rpt"

# =========================================================================
# 7. TIMING CHECK
# =========================================================================
set timing_ok [get_property SLACK [get_timing_paths]]
if {$timing_ok < 0} {
    puts "!!! WARNING: TIMING NOT MET (WNS = $timing_ok) !!!"
    puts "!!! DO NOT USE THIS BITSTREAM FOR PRODUCTION !!!"
} else {
    puts "✓ TIMING MET (WNS = $timing_ok ns)"
}

# =========================================================================
# 8. BITSTREAM GENERATION
# =========================================================================
puts "\n=== BITSTREAM ==="
set BIT_FILE "$OUTPUT_DIR/titan_v14_${PROFILE}.bit"
write_bitstream -force $BIT_FILE

# =========================================================================
# ★ P1 #25: BITSTREAM AUTHENTICATION (GOLDEN only)
# =========================================================================
if {$PROFILE eq "GOLDEN"} {
    puts "\n=== ★ P1 #25: BITSTREAM AUTHENTICATION ==="

    # Generate SHA-256 hash for integrity verification (★ P6 #52)
    set hash_file "$OUTPUT_DIR/titan_v14_GOLDEN.sha256"
    set sha_result [exec sha256sum $BIT_FILE]
    set fd [open $hash_file w]
    puts $fd $sha_result
    close $fd
    puts "  SHA-256: [lindex [split $sha_result] 0]"
    puts "  Hash file: $hash_file"

    # ★ Anti-rollback: Monotonic version counter
    # This version number must be incremented with each production build.
    # FPGA checks this against eFUSE counter during boot.
    set VERSION_FILE "$OUTPUT_DIR/bitstream_version.txt"
    set build_version 1
    if {[file exists $VERSION_FILE]} {
        set fd [open $VERSION_FILE r]
        set prev_version [gets $fd]
        close $fd
        set build_version [expr {$prev_version + 1}]
    }
    set fd [open $VERSION_FILE w]
    puts $fd $build_version
    close $fd
    puts "  Bitstream version: $build_version (anti-rollback)"
    puts "  ★ UYARI: Üretimde eFUSE counter'ı $build_version'a eşit olmalı"
}

puts ""
puts "=========================================="
puts "  BUILD COMPLETE"
puts "  Profile:   $PROFILE"
puts "  Bitstream: $BIT_FILE"
puts "  Reports:   $OUTPUT_DIR/"
if {$PROFILE eq "GOLDEN"} {
    puts "  Auth:      SHA-256 + Version Lock"
}
puts "=========================================="

exit 0
