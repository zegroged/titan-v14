@echo off
REM ============================================================
REM AEGIS Phase 2.2: GHDL Simulation — tanh LUT ROM
REM ============================================================

echo ============================================================
echo  AEGIS: tanh LUT ROM GHDL Simulation
echo ============================================================

echo [1/5] Analyzing tanh_lut_pkg.vhd...
ghdl -a --std=08 tanh_lut_pkg.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/5] Analyzing tanh_lut_rom.vhd...
ghdl -a --std=08 tanh_lut_rom.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/5] Analyzing tb_tanh_lut_rom.vhd...
ghdl -a --std=08 tb_tanh_lut_rom.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/5] Elaborating...
ghdl -e --std=08 tb_tanh_lut_rom
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [5/5] Running simulation...
ghdl -r --std=08 tb_tanh_lut_rom --stop-time=10ms --wave=tanh_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Simulation complete!
echo ============================================================
