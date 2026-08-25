@echo off
REM AEGIS Phase 3.4: GHDL Simulation — Omega Cloak Top
REM Requires behavioral MMCM model from tb_clock_jitter.vhd

echo ============================================================
echo  AEGIS: Omega Cloak Top Module GHDL Simulation
echo ============================================================

echo [1/8] Analyzing chaotic_prng.vhd...
ghdl -a --std=08 chaotic_prng.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/8] Analyzing clock_jitter_injector.vhd...
REM NOTE: For GHDL, replace UNISIM entities with behavioral stubs
REM ghdl -a --std=08 clock_jitter_injector.vhd

echo [3/8] Analyzing dummy_op_injector.vhd...
ghdl -a --std=08 dummy_op_injector.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/8] Analyzing omega_cloak_top.vhd...
ghdl -a --std=08 omega_cloak_top.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [5/8] Analyzing tb_omega_cloak.vhd...
ghdl -a --std=08 tb_omega_cloak.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [6/8] Elaborating...
ghdl -e --std=08 tb_omega_cloak
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [7/8] Running simulation...
ghdl -r --std=08 tb_omega_cloak --stop-time=100us --wave=omega_cloak_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [8/8] Running CPA Analysis...
python ..\..\scripts\aegis\cpa_omega_analysis.py

echo.
echo  Omega Cloak simulation complete!
echo ============================================================
