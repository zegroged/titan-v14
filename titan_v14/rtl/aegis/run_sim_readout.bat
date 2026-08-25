@echo off
REM AEGIS Phase 2.4: GHDL Simulation — ESN Readout Layer

echo ============================================================
echo  AEGIS: ESN Readout Layer GHDL Simulation
echo ============================================================

echo [1/5] Analyzing esn_weight_pkg.vhd...
ghdl -a --std=08 esn_weight_pkg.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/5] Analyzing esn_readout.vhd...
ghdl -a --std=08 esn_readout.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/5] Analyzing tb_esn_readout.vhd...
ghdl -a --std=08 tb_esn_readout.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/5] Elaborating...
ghdl -e --std=08 tb_esn_readout
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [5/5] Running simulation...
ghdl -r --std=08 tb_esn_readout --stop-time=10ms --wave=readout_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Simulation complete!
echo ============================================================
