@echo off
REM AEGIS Phase 3.3: GHDL Simulation — Dummy Operation Injector

echo ============================================================
echo  AEGIS: Dummy Operation Injector GHDL Simulation
echo ============================================================

echo [1/4] Analyzing dummy_op_injector.vhd...
ghdl -a --std=08 dummy_op_injector.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/4] Analyzing tb_dummy_op_injector.vhd...
ghdl -a --std=08 tb_dummy_op_injector.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/4] Elaborating...
ghdl -e --std=08 tb_dummy_op_injector
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/4] Running simulation...
ghdl -r --std=08 tb_dummy_op_injector --stop-time=50us --wave=dummy_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Simulation complete!
echo ============================================================
