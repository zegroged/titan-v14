@echo off
REM AEGIS Phase 4.2: GHDL Simulation — PVT Monitor Top

echo ============================================================
echo  AEGIS: PVT Monitor Top GHDL Simulation
echo ============================================================

echo [1/5] Analyzing ring_osc_counter.vhd...
ghdl -a --std=08 ring_osc_counter.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/5] Analyzing pvt_monitor_top.vhd...
ghdl -a --std=08 pvt_monitor_top.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/5] Analyzing tb_pvt_monitor.vhd...
ghdl -a --std=08 tb_pvt_monitor.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/5] Elaborating...
ghdl -e --std=08 tb_pvt_monitor
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [5/5] Running simulation (may take time: 1ms measurement windows)...
ghdl -r --std=08 tb_pvt_monitor --stop-time=30ms --wave=pvt_monitor_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  PVT Monitor simulation complete!
echo ============================================================
