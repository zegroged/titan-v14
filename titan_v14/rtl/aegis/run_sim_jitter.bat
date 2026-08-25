@echo off
REM AEGIS Phase 3.2: GHDL Simulation — Clock Jitter Injector
REM Note: Uses behavioral MMCM model, no UNISIM needed

echo ============================================================
echo  AEGIS: Clock Jitter Injector GHDL Simulation
echo ============================================================

echo [1/4] Analyzing tb_clock_jitter.vhd (includes behavioral MMCM model)...
ghdl -a --std=08 tb_clock_jitter.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/4] Elaborating...
ghdl -e --std=08 tb_clock_jitter
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/4] Running simulation...
ghdl -r --std=08 tb_clock_jitter --stop-time=50us --wave=jitter_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Simulation complete! Open jitter_sim.ghw in GTKWave.
echo ============================================================
