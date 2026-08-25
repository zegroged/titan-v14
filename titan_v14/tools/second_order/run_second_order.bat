@echo off
REM ============================================================
REM TITAN V14 -- Second-Order Masking Verification Runner
REM ============================================================

set RTL=..\..\rtl
set TOOLS_DIR=%~dp0

echo ============================================================
echo   TITAN V14 -- 2nd-Order Masking Verification
echo ============================================================
echo.

echo [1/3] Compiling sources...
pushd "%TOOLS_DIR%"

ghdl -a --std=08 --work=work "%RTL%\common\aes_sbox.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\aes_sbox_masked.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\aes_key_expand.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\aes_round.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\aes256_core.vhd" 2>nul
ghdl -a --std=08 --work=work "%RTL%\common\trng_drbg_bridge.vhd" 2>&1
if errorlevel 1 (echo [FAIL] DRBG bridge compile error & popd & exit /b 1)
ghdl -a --std=08 --work=work "%TOOLS_DIR%tb_aes256_second_order.vhd" 2>&1
if errorlevel 1 (echo [FAIL] TB compile error & popd & exit /b 1)
echo   [OK] Sources compiled

echo [2/3] Elaborating...
ghdl -e --std=08 --work=work tb_aes256_second_order 2>&1
if errorlevel 1 (echo [FAIL] Elaborate error & popd & exit /b 1)
echo   [OK] Elaboration complete

echo [3/3] Running verification...
ghdl -r --std=08 --work=work tb_aes256_second_order --stop-time=5ms 2>&1

popd

echo.
echo ============================================================
echo   COMPLETE
echo ============================================================
