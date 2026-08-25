@echo off
REM ============================================================
REM TITAN V14 -- CPA Attack Simulation Runner
REM ============================================================

set RTL=..\..\rtl
set TOOLS_DIR=%~dp0

echo ============================================================
echo   TITAN V14 -- CPA Attack Simulation
echo ============================================================
echo.

echo [1/4] Compiling sources...
pushd "%TOOLS_DIR%"

ghdl -a --std=08 --work=work "%RTL%\common\aes_sbox.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\aes_sbox_masked.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\aes_key_expand.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\aes_round.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\aes256_core.vhd" 2>nul
ghdl -a --std=08 --work=work "%TOOLS_DIR%tb_aes_power_trace.vhd" 2>&1
if errorlevel 1 (echo [FAIL] Compile error & popd & exit /b 1)
echo   [OK] Sources compiled

echo [2/4] Elaborating...
ghdl -e --std=08 --work=work tb_aes_power_trace 2>&1
if errorlevel 1 (echo [FAIL] Elaborate error & popd & exit /b 1)
echo   [OK] Elaboration complete

echo [3/4] Running trace capture (256 encryptions)...
ghdl -r --std=08 --work=work tb_aes_power_trace --stop-time=200ms 2>&1
if errorlevel 1 (echo [WARN] Simulation issue)
echo   [OK] Trace capture complete

echo [4/4] Running CPA attack analysis...
python "%TOOLS_DIR%cpa_attack.py" power_traces.csv 2>&1

popd

echo.
echo ============================================================
echo   COMPLETE
echo ============================================================
