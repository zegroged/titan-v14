@echo off
REM AEGIS Phase 3.1: GHDL Simulation — Chaotic PRNG

echo ============================================================
echo  AEGIS: Chaotic PRNG GHDL Simulation
echo ============================================================

echo [1/4] Analyzing chaotic_prng.vhd...
ghdl -a --std=08 chaotic_prng.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/4] Analyzing tb_chaotic_prng.vhd...
ghdl -a --std=08 tb_chaotic_prng.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/4] Elaborating...
ghdl -e --std=08 tb_chaotic_prng
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/4] Running simulation...
ghdl -r --std=08 tb_chaotic_prng --stop-time=100ms --wave=prng_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Simulation complete!
echo ============================================================
