@echo off
REM ============================================================================
REM  PROJECT TITAN V15: GHDL Simulation Script (Stub TRNG)
REM ============================================================================
REM  Kullanım: run_sim.bat
REM
REM  TRNG ring oscillator STUB kullanır (tb\sim\trng_ring_osc.vhd)
REM  Gerçek ring osc yerine LFSR toggle → simülasyon 100x+ hızlı
REM ============================================================================

set GHDL=ghdl
set SRC=..\rtl\common
set TB_SIM=sim
set WORKDIR=work
set STD=--std=08

echo.
echo ====================================================
echo   TITAN V15 — GHDL Simülasyon (Stub TRNG)
echo ====================================================
echo.

REM Temiz başla
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%

echo [1/10] Analiz: AES S-Box...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd
if errorlevel 1 goto :fail

echo [2/10] Analiz: AES S-Box Masked...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox_masked.vhd
if errorlevel 1 goto :fail

echo [3/10] Analiz: TRNG Ring Osc STUB (simülasyon)...
%GHDL% -a %STD% --workdir=%WORKDIR% %TB_SIM%\trng_ring_osc.vhd
if errorlevel 1 goto :fail

echo [4/10] Analiz: AES Key Expand...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_key_expand.vhd
if errorlevel 1 goto :fail

echo [5/10] Analiz: AES Round...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_round.vhd
if errorlevel 1 goto :fail

echo [5/9] Analiz: AES-256 Core (Fault Protected)...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes256_core.vhd
if errorlevel 1 goto :fail

echo [6/9] Analiz: Chaotic PRNG (Omega Cloak)...
%GHDL% -a %STD% --workdir=%WORKDIR% ..\rtl\aegis\chaotic_prng.vhd
if errorlevel 1 goto :fail

echo [7/9] Analiz: AES Core Wrapper (+ Omega Cloak)...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_core_wrapper.vhd
if errorlevel 1 goto :fail

echo [8/9] Analiz: Comm Protocol...
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\comm_protocol.vhd
if errorlevel 1 goto :fail

echo [9/9] Analiz: Testbench...
%GHDL% -a %STD% --workdir=%WORKDIR% comm_protocol_tb.vhd
if errorlevel 1 goto :fail

echo.
echo ====================================================
echo   Elaboration...
echo ====================================================
%GHDL% -e %STD% --workdir=%WORKDIR% comm_protocol_tb
if errorlevel 1 goto :fail

echo.
echo ====================================================
echo   Simülasyon Başlıyor (stop-time=50ms)...
echo ====================================================
echo   (TRNG stub aktif — metavalue spam yok)
echo.
%GHDL% -r %STD% --workdir=%WORKDIR% comm_protocol_tb --stop-time=100ms --assert-level=error 2>&1
if errorlevel 1 (
    echo.
    echo [!] Simülasyon assertion failure ile bitti
    goto :end
)

echo.
echo ====================================================
echo   SIMÜLASYON TAMAMLANDI
echo ====================================================
goto :end

:fail
echo.
echo [HATA] Derleme/elaboration başarısız!
echo.

:end
pause
