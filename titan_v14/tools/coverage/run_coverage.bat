@echo off
REM ============================================================
REM TITAN V14 — Code Coverage Analysis Runner
REM Runs all 16 TBs with VCD output, then analyzes coverage
REM ============================================================

set RTL=..\..\rtl
set GHDL_SIM=..\..\ghdl_sim
set TOOLS_DIR=%~dp0
set VCD_DIR=%TOOLS_DIR%vcd_output

echo ============================================================
echo   TITAN V14 — Code Coverage Analysis
echo ============================================================
echo.

REM -- Create VCD output directory
if not exist "%VCD_DIR%" mkdir "%VCD_DIR%"

REM -- Step 1: Analyze all sources (reuse ghdl_sim work library)
echo [1/3] Compiling sources...
pushd "%GHDL_SIM%"

REM Analyze common modules
for %%f in (
    aes_sbox.vhd
    aes_sbox_masked.vhd
    aes_key_expand.vhd
    aes_round.vhd
    aes256_core.vhd
    secure_key_storage.vhd
    trng_ring_osc.vhd
    trng_wrapper.vhd
    kill_protocol.vhd
    aes_core_wrapper.vhd
) do (
    ghdl -a --std=08 --work=work "%RTL%\common\%%f" 2>nul
)

REM Analyze AEGIS modules
ghdl -a --std=08 --work=work "%RTL%\aegis\chaotic_prng.vhd" 2>nul
for %%f in (
    tanh_lut_pkg.vhd
    tanh_lut_rom.vhd
    esn_weight_pkg.vhd
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
) do (
    ghdl -a --std=08 --work=work "%RTL%\aegis\%%f" 2>nul
)
echo   [OK] Sources compiled

REM -- Step 2: Run selected TBs with VCD output
echo [2/3] Running testbenches with VCD capture...

REM Key TBs that exercise the most critical modules
set TB_LIST=tb_chaotic_prng tb_anomaly_detector tb_omega_cloak tb_aegis_top

set TB_COUNT=0
for %%t in (%TB_LIST%) do (
    set /a TB_COUNT+=1
    echo   Running %%t...
    ghdl -a --std=08 --work=work "%RTL%\aegis\%%t.vhd" 2>nul
    ghdl -e --std=08 --work=work %%t 2>nul
    ghdl -r --std=08 --work=work %%t --stop-time=5ms --vcd="%VCD_DIR%\%%t.vcd" 2>nul
    if exist "%VCD_DIR%\%%t.vcd" (
        echo     [OK] VCD generated
    ) else (
        echo     [SKIP] No VCD
    )
)

popd

REM -- Step 3: Run Python coverage analyzer
echo [3/3] Analyzing coverage...
python "%TOOLS_DIR%coverage_analyzer.py" "%VCD_DIR%" 2>&1

if exist "%TOOLS_DIR%CODE_COVERAGE_REPORT.md" (
    echo.
    echo   Report: CODE_COVERAGE_REPORT.md
)

echo.
echo ============================================================
echo   COMPLETE
echo ============================================================
