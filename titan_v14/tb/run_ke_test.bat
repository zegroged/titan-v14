@echo off
set GHDL=ghdl
set SRC=..\rtl\common
set WORKDIR=work_ke_test
set STD=--std=08

echo.
echo ====================================================
echo   AES-256 Key Expansion Debug Test
echo ====================================================
echo.

if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%

echo [1/3] Analiz: S-Box + Key Expand...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd
if errorlevel 1 goto :fail
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_key_expand.vhd
if errorlevel 1 goto :fail

echo [2/3] Analiz: Testbench...
%GHDL% -a %STD% --workdir=%WORKDIR% aes_key_expand_tb.vhd
if errorlevel 1 goto :fail

echo [3/3] Elaboration + Run...
%GHDL% -e %STD% --workdir=%WORKDIR% aes_key_expand_tb
if errorlevel 1 goto :fail

%GHDL% -r %STD% --workdir=%WORKDIR% aes_key_expand_tb --stop-time=10ms --assert-level=failure 2>&1
goto :end

:fail
echo [HATA] Derleme basarisiz!

:end
pause
