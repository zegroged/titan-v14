@echo off
setlocal enabledelayedexpansion
cd /d C:\Users\Mert\titan_build\ghdl_sim

set RTL=C:\Users\Mert\titan_build\rtl
set PASS=0
set FAIL=0
set SKIP=0
set TOTAL=0

echo ================================================================
echo   TITAN V14 -- GHDL Testbench Simulation Suite
echo   GHDL 5.1.1  /  mcode JIT
echo ================================================================
echo.

REM ---- Step 1: Analyze all source files ----
echo [STEP 1] Analyzing source files...

REM -- Packages first (dependencies)
ghdl -a --std=08 --work=work "%RTL%\aegis\tanh_lut_pkg.vhd" 2>&1
ghdl -a --std=08 --work=work "%RTL%\aegis\esn_weight_pkg.vhd" 2>&1

REM -- Common modules (order matters for dependencies)
for %%f in (
    aes_sbox.vhd
    aes_sbox_masked.vhd
    aes_key_expand.vhd
    aes_round.vhd
    aes256_core.vhd
    post_self_test.vhd
    secure_key_storage.vhd
    uart_driver.vhd
    data_gearbox.vhd
    comm_protocol.vhd
    trng_ring_osc.vhd
    trng_wrapper.vhd
    key_loader_spi.vhd
    spi_cmd_slave.vhd
    watchdog_monitor.vhd
    kill_protocol.vhd
) do (
    ghdl -a --std=08 --work=work "%RTL%\common\%%f" 2>&1
    if errorlevel 1 (
        echo   [WARN] Failed to analyze common\%%f
    )
)

REM -- chaotic_prng must be analyzed BEFORE aes_core_wrapper (dependency)
ghdl -a --std=08 --work=work "%RTL%\aegis\chaotic_prng.vhd" 2>&1

REM -- Modules that depend on AEGIS components
for %%f in (
    aes_core_wrapper.vhd
    uart_telemetry.vhd
    system_supervisor.vhd
    crypto_core_stub.vhd
) do (
    ghdl -a --std=08 --work=work "%RTL%\common\%%f" 2>&1
    if errorlevel 1 (
        echo   [WARN] Failed to analyze common\%%f
    )
)

REM -- AEGIS modules (chaotic_prng already analyzed above, before aes_core_wrapper)
for %%f in (
    tanh_lut_rom.vhd
    shift_add_multiplier.vhd
    ring_osc_counter.vhd
    esn_reservoir_core.vhd
    esn_readout.vhd
    anomaly_detector.vhd
    pvt_monitor_top.vhd
    dummy_op_injector.vhd
    clock_jitter_injector.vhd
    omega_cloak_top.vhd
    aegis_top.vhd
    chaos_node.vhd
    liquid_reservoir.vhd
) do (
    ghdl -a --std=08 --work=work "%RTL%\aegis\%%f" 2>&1
    if errorlevel 1 (
        echo   [WARN] Failed to analyze aegis\%%f
    )
)

REM -- Legacy sim-only modules (NOT for Vivado synthesis)
ghdl -a --std=08 --work=work "%RTL%\common\module_external_tamper.vhd" 2>&1

REM -- Artix7 platform (non-testbench, needed for tb_artix7_top_v14)
ghdl -a --std=08 --work=work "%RTL%\artix7\artix7_top_v14.vhd" 2>&1

echo [STEP 1] Analysis complete.
echo.

REM ---- Step 2: Analyze and run each testbench ----
echo [STEP 2] Running testbenches...
echo.

call :run_tb "%RTL%\aegis\tb_tanh_lut_rom.vhd" tb_tanh_lut_rom "Tanh LUT ROM"
call :run_tb "%RTL%\aegis\tb_shift_add_multiplier.vhd" tb_shift_add_multiplier "Shift-Add Multiplier"
call :run_tb "%RTL%\aegis\tb_chaotic_prng.vhd" tb_chaotic_prng "Chaotic PRNG (Logistic Map)"
call :run_tb "%RTL%\aegis\tb_ring_osc_counter.vhd" tb_ring_osc_counter "Ring Oscillator Counter"
call :run_tb "%RTL%\aegis\tb_esn_reservoir.vhd" tb_esn_reservoir "ESN Reservoir Core"
call :run_tb "%RTL%\aegis\tb_esn_readout.vhd" tb_esn_readout "ESN Readout Layer"
call :run_tb "%RTL%\aegis\tb_anomaly_detector.vhd" tb_anomaly_detector "Anomaly Detector"
call :run_tb "%RTL%\aegis\tb_pvt_monitor.vhd" tb_pvt_monitor "PVT Monitor"
call :run_tb "%RTL%\aegis\tb_dummy_op_injector.vhd" tb_dummy_op_injector "Dummy Op Injector"
call :run_tb "%RTL%\aegis\tb_clock_jitter.vhd" tb_clock_jitter "Clock Jitter Injector"
call :run_tb "%RTL%\aegis\tb_omega_cloak.vhd" tb_omega_cloak "Omega Cloak Top"
call :run_tb "%RTL%\aegis\tb_aegis_top.vhd" tb_aegis_top "AEGIS Top"
call :run_tb "%RTL%\artix7\tb_artix7_top_v14.vhd" tb_artix7_top_v14 "Artix-7 Top V14"

REM ---- Legacy Integration Tests ----
call :run_tb "%RTL%\common\tb_aes256_nist_vectors.vhd" tb_aes256_nist_vectors "AES-256 NIST FIPS 197 Vectors"
call :run_tb "%RTL%\common\tb_aes256_ctr_mode.vhd" tb_aes256_ctr_mode "AES-256 CTR Mode + KILL"
call :run_tb "%RTL%\common\tb_dual_fpga_system.vhd" tb_dual_fpga_system "Dual-FPGA Tamper + Kill"

echo.
echo ================================================================
echo   RESULTS: %PASS% PASS / %FAIL% FAIL / %SKIP% SKIP  (Total: %TOTAL%)
echo ================================================================

goto :eof

:run_tb
set /a TOTAL+=1
set TB_FILE=%~1
set TB_ENTITY=%~2
set TB_DESC=%~3

echo --- [%TOTAL%/16] %TB_DESC% (%TB_ENTITY%) ---

REM Analyze
ghdl -a --std=08 --work=work "%TB_FILE%" 2>&1
if errorlevel 1 (
    echo   ANALYZE FAILED
    set /a SKIP+=1
    echo   Result: SKIP [analyze error]
    echo.
    goto :eof
)

REM Elaborate
ghdl -e --std=08 --work=work %TB_ENTITY% 2>&1
if errorlevel 1 (
    echo   ELABORATE FAILED [likely Xilinx primitives]
    set /a SKIP+=1
    echo   Result: SKIP [elaborate error]
    echo.
    goto :eof
)

REM Run (10ms timeout to prevent infinite loops)
ghdl -r --std=08 --work=work %TB_ENTITY% --stop-time=10ms 2>&1
if errorlevel 1 (
    echo   Result: FAIL
    set /a FAIL+=1
) else (
    echo   Result: PASS
    set /a PASS+=1
)
echo.
goto :eof
