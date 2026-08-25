@echo off
REM TITAN V14 Master Regression
setlocal EnableDelayedExpansion

set PASS=0
set FAIL=0
set SKIP=0
set TB_DIR=%~dp0
set RTL_DIR=%~dp0..\rtl

echo ============================================================================
echo  TITAN V14 MASTER REGRESSION
echo  %date% %time%
echo ============================================================================

cd /d "%TB_DIR%"

REM Analyze RTL
ghdl -a --std=08 "%RTL_DIR%\common\aes_sbox.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\aes_sbox_masked.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\sha256_core.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\hmac_sha256.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\glitch_detector.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\secure_key_storage.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\hmac_heartbeat_ctrl.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\pf_hmac_responder.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\uart_driver.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\data_gearbox.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\kill_protocol.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\key_loader_spi.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\comm_protocol.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\firmware_integrity.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\common\post_self_test.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\esn_weight_pkg.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\tanh_lut_pkg.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\chaotic_prng.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\clock_jitter_injector.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\dummy_op_injector.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\omega_cloak_top.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\ring_osc_counter.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\pvt_monitor_top.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\shift_add_multiplier.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\tanh_lut_rom.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\esn_reservoir_core.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\esn_readout.vhd" 2>nul
ghdl -a --std=08 "%RTL_DIR%\aegis\anomaly_detector.vhd" 2>nul

echo RTL analysis complete.
echo.

REM Function to run a TB
call :run_tb tb_glitch_detector 100us
call :run_tb tb_secure_key_storage 100us
call :run_tb tb_aes_sbox_masked 500us
call :run_tb tb_hmac_heartbeat_ctrl 5ms
call :run_tb tb_pf_hmac_responder 5ms
call :run_tb tb_pvt_monitor_top 10ms
call :run_tb tb_chaotic_prng 200us
call :run_tb tb_omega_cloak_top 200us
call :run_tb tb_clock_jitter_injector 50us
call :run_tb tb_dummy_op_injector 50us
call :run_tb tb_ring_osc_counter 10ms
call :run_tb tb_uart_driver 5ms
call :run_tb tb_shift_add_multiplier 100us
call :run_tb tb_tanh_lut_rom 500us
call :run_tb tb_anomaly_detector 100us
call :run_tb tb_esn_reservoir_core 500us
call :run_tb tb_esn_readout 200us
call :run_tb tb_sha256 5ms
call :run_tb tb_hmac_rfc4231 10ms
call :run_tb tb_sbox_exhaustive 500us
call :run_tb tb_data_gearbox 500us
call :run_tb tb_comm_protocol 500us
call :run_tb tb_firmware_integrity 500us
call :run_tb tb_key_loader_spi 500us
call :run_tb tb_kill_chain_full 5ms
call :run_tb tb_trng_health 500us
call :run_tb tb_post_supervisor 500us
call :run_tb tb_watchdog_v2 5ms

echo.
echo ============================================================================
echo  REGRESSION SUMMARY
echo  PASS: !PASS!  FAIL: !FAIL!  SKIP: !SKIP!
echo ============================================================================
if !FAIL! gtr 0 (
    echo  REGRESSION FAILED
    exit /b 1
) else (
    echo  ALL TESTS PASSED
    exit /b 0
)

goto :eof

:run_tb
set _TB=%~1
set _TIME=%~2
if not exist %_TB%.vhd (
    echo [SKIP] %_TB%
    set /a SKIP+=1
    goto :eof
)
ghdl -a --std=08 %_TB%.vhd 2>nul
ghdl -e --std=08 %_TB% 2>nul
ghdl -r --std=08 %_TB% --stop-time=%_TIME% 2>&1 | findstr /C:"PASSED" >nul
if !errorlevel! equ 0 (
    echo [PASS] %_TB%
    set /a PASS+=1
) else (
    echo [FAIL] %_TB%
    set /a FAIL+=1
)
goto :eof
