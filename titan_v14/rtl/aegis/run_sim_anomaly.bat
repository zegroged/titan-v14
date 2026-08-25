@echo off
REM AEGIS Phase 2.5: GHDL Simulation — Anomaly Detector

echo ============================================================
echo  AEGIS: Anomaly Detector GHDL Simulation
echo ============================================================

echo [1/4] Analyzing anomaly_detector.vhd...
ghdl -a --std=08 anomaly_detector.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [2/4] Analyzing tb_anomaly_detector.vhd...
ghdl -a --std=08 tb_anomaly_detector.vhd
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [3/4] Elaborating...
ghdl -e --std=08 tb_anomaly_detector
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo [4/4] Running simulation...
ghdl -r --std=08 tb_anomaly_detector --stop-time=10ms --wave=anomaly_sim.ghw
if %ERRORLEVEL% NEQ 0 (echo FAILED & exit /b 1)

echo.
echo  Simulation complete!
echo ============================================================
