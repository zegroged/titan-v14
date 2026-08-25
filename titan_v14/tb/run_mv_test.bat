@echo off
set GHDL=ghdl
set SRC=..\rtl\common
set WORKDIR=work_mv_test
set STD=--std=08

echo.
echo ====================================================
echo   AES-256 Multi-Vector Independent Verification
echo ====================================================
echo.

if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%

echo [1/5] AES S-Box...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd
if errorlevel 1 goto :fail

echo [2/5] AES Key Expand...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_key_expand.vhd
if errorlevel 1 goto :fail

echo [3/5] AES Round...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_round.vhd
if errorlevel 1 goto :fail

echo [4/5] AES-256 Core...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes256_core.vhd
if errorlevel 1 goto :fail

echo [5/5] Multi-Vector TB...
%GHDL% -a %STD% --workdir=%WORKDIR% aes256_multi_vector_tb.vhd
if errorlevel 1 goto :fail

echo.
%GHDL% -e %STD% --workdir=%WORKDIR% aes256_multi_vector_tb
if errorlevel 1 goto :fail

echo.
%GHDL% -r %STD% --workdir=%WORKDIR% aes256_multi_vector_tb --stop-time=30ms --assert-level=failure 2>&1
goto :end

:fail
echo [HATA] Derleme basarisiz!

:end
pause
