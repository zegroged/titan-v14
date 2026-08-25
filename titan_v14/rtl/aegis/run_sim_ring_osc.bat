@echo off
REM AEGIS Phase 4.1: GHDL Simulation — Ring Oscillator Frequency Counter

echo ============================================================
echo  AEGIS: Ring Oscillator Frequency Counter Simulation
echo ============================================================

echo [1/4] Analyzing ring_osc_counter.vhd...
ghdl -a --std=08 ring_osc_counter.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/4] Analyzing tb_ring_osc_counter.vhd...
ghdl -a --std=08 tb_ring_osc_counter.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/4] Elaborating...
ghdl -e --std=08 tb_ring_osc_counter
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/4] Running simulation (this may take a while: 1ms windows)...
ghdl -r --std=08 tb_ring_osc_counter --stop-time=20ms --wave=ring_osc_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Simulation complete! Open ring_osc_sim.ghw in GTKWave.
echo ============================================================
