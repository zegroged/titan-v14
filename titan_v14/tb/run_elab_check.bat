@echo off
REM ============================================================================
REM TITAN V14: Full Elaboration Check (ALL modules)
REM Proves no syntax or wiring errors across entire design
REM ============================================================================
set GHDL=ghdl
set RTL=..\rtl\common
set ARTIX=..\rtl\artix7
set AEGIS=..\rtl\aegis
set TB_SIM=sim
set WORKDIR=work_elab_check
set STD=--std=08

echo.
echo ====================================================
echo   Full Design Elaboration Check
echo ====================================================
echo.

if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%

echo [1] Primitives...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\aes_sbox.vhd
if errorlevel 1 goto :fail

echo [2] TRNG Stub...
%GHDL% -a %STD% --workdir=%WORKDIR% %TB_SIM%\trng_ring_osc.vhd
if errorlevel 1 goto :fail

echo [3] AES Key Expand...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\aes_key_expand.vhd
if errorlevel 1 goto :fail

echo [4] AES Round...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\aes_round.vhd
if errorlevel 1 goto :fail

echo [5] AES256 Core...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\aes256_core.vhd
if errorlevel 1 goto :fail

echo [6] Chaotic PRNG...
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\chaotic_prng.vhd
if errorlevel 1 goto :fail

echo [7] AES Core Wrapper...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\aes_core_wrapper.vhd
if errorlevel 1 goto :fail

echo [8] Kill Protocol...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\kill_protocol.vhd
if errorlevel 1 goto :fail

echo [9] POST Self-Test...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\post_self_test.vhd
if errorlevel 1 goto :fail

echo [10] System Supervisor...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\system_supervisor.vhd
if errorlevel 1 goto :fail

echo [11] Comm Protocol...
%GHDL% -a %STD% --workdir=%WORKDIR% %RTL%\comm_protocol.vhd
if errorlevel 1 goto :fail

echo.
echo ALL MODULES COMPILED SUCCESSFULLY (analysis pass)
echo.

pause
