@echo off
REM AEGIS Phase 2.6: GHDL Simulation — AEGIS Top Module (Full Pipeline)

echo ============================================================
echo  AEGIS: Top Module End-to-End GHDL Simulation
echo ============================================================

echo [1/9] Analyzing tanh_lut_pkg.vhd...
ghdl -a --std=08 tanh_lut_pkg.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/9] Analyzing esn_weight_pkg.vhd...
ghdl -a --std=08 esn_weight_pkg.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/9] Analyzing esn_reservoir_core.vhd...
ghdl -a --std=08 esn_reservoir_core.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/9] Analyzing esn_readout.vhd...
ghdl -a --std=08 esn_readout.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [5/9] Analyzing anomaly_detector.vhd...
ghdl -a --std=08 anomaly_detector.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [6/9] Analyzing aegis_top.vhd...
ghdl -a --std=08 aegis_top.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [7/9] Analyzing tb_aegis_top.vhd...
ghdl -a --std=08 tb_aegis_top.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [8/9] Elaborating...
ghdl -e --std=08 tb_aegis_top
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [9/9] Running simulation...
ghdl -r --std=08 tb_aegis_top --stop-time=100ms --wave=aegis_top_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Full pipeline simulation complete!
echo ============================================================
