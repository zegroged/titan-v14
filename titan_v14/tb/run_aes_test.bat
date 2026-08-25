@echo off
REM ============================================================================
REM  PROJECT TITAN V14: AES-256 NIST KAT Standalone Test
REM ============================================================================
REM  NIST FIPS-197 Appendix C.3 doğrulama testi.
REM  AES core'u bağımsız olarak test eder (wrapper/comm yok).
REM ============================================================================

set GHDL=ghdl
set SRC=..\rtl\common
set TB_SIM=sim
set WORKDIR=work_aes_test
set STD=--std=08

echo.
echo ====================================================
echo   TITAN V14 — AES-256 NIST KAT Test
echo ====================================================
echo.

REM Temiz başla
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%

echo [1/5] Analiz: AES S-Box...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd
if errorlevel 1 goto :fail

echo [2/5] Analiz: AES Key Expand...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_key_expand.vhd
if errorlevel 1 goto :fail

echo [3/5] Analiz: AES Round...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_round.vhd
if errorlevel 1 goto :fail

echo [4/5] Analiz: AES-256 Core...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes256_core.vhd
if errorlevel 1 goto :fail

echo [5/5] Analiz: Standalone Testbench...
%GHDL% -a %STD% --workdir=%WORKDIR% aes256_standalone_tb.vhd
if errorlevel 1 goto :fail

echo.
echo ====================================================
echo   Elaboration...
echo ====================================================
%GHDL% -e %STD% --workdir=%WORKDIR% aes256_standalone_tb
if errorlevel 1 goto :fail

echo.
echo ====================================================
echo   NIST KAT Testi Basliyor...
echo ====================================================
echo.
%GHDL% -r %STD% --workdir=%WORKDIR% aes256_standalone_tb --stop-time=10ms --assert-level=failure 2>&1
if errorlevel 1 (
    echo.
    echo [!] Test assertion failure ile bitti
    goto :end
)

echo.
echo ====================================================
echo   AES NIST KAT TESTI TAMAMLANDI
echo ====================================================
goto :end

:fail
echo.
echo [HATA] Derleme/elaboration basarisiz!
echo.

:end
pause
