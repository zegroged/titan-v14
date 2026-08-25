@echo off
REM AEGIS Phase 2.3: GHDL Simulation — ESN Reservoir Core

echo ============================================================
echo  AEGIS: ESN Reservoir Core GHDL Simulation
echo ============================================================

echo [1/7] Analyzing tanh_lut_pkg.vhd...
ghdl -a --std=08 tanh_lut_pkg.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/7] Analyzing esn_weight_pkg.vhd...
ghdl -a --std=08 esn_weight_pkg.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/7] Analyzing tanh_lut_rom.vhd...
ghdl -a --std=08 tanh_lut_rom.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/7] Analyzing esn_reservoir_core.vhd...
ghdl -a --std=08 esn_reservoir_core.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [5/7] Analyzing tb_esn_reservoir.vhd...
ghdl -a --std=08 tb_esn_reservoir.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [6/7] Elaborating...
ghdl -e --std=08 tb_esn_reservoir
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [7/7] Running simulation...
ghdl -r --std=08 tb_esn_reservoir --stop-time=100ms --wave=esn_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Simulation complete!
echo ============================================================
