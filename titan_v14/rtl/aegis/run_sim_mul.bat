@echo off
REM ============================================================
REM AEGIS Phase 2.1: GHDL Simulation Script
REM Shift-Add Multiplier Verification
REM ============================================================
REM Prerequisites: GHDL installed and on PATH
REM Usage: run_sim_mul.bat
REM ============================================================

echo ============================================================
echo  AEGIS: Shift-Add Multiplier GHDL Simulation
echo ============================================================

REM Step 1: Analyze (compile) VHDL sources
echo [1/4] Analyzing shift_add_multiplier.vhd...
ghdl -a --std=08 shift_add_multiplier.vhd
if %ERRORLEVEL% NEQ 0 (
    echo FAILED: shift_add_multiplier.vhd analysis
    exit /b 1
)

echo [2/4] Analyzing tb_shift_add_multiplier.vhd...
ghdl -a --std=08 tb_shift_add_multiplier.vhd
if %ERRORLEVEL% NEQ 0 (
    echo FAILED: tb_shift_add_multiplier.vhd analysis
    exit /b 1
)

REM Step 2: Elaborate
echo [3/4] Elaborating testbench...
ghdl -e --std=08 tb_shift_add_multiplier
if %ERRORLEVEL% NEQ 0 (
    echo FAILED: elaboration
    exit /b 1
)

REM Step 3: Run simulation
echo [4/4] Running simulation (1000 test vectors)...
ghdl -r --std=08 tb_shift_add_multiplier --stop-time=500ms --wave=mul_sim.ghw
if %ERRORLEVEL% NEQ 0 (
    echo FAILED: simulation
    exit /b 1
)

echo.
echo ============================================================
echo  Simulation complete! Check output above for PASS/FAIL.
echo  Waveform saved: mul_sim.ghw
echo ============================================================
