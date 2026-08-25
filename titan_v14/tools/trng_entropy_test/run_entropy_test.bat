@echo off
REM ============================================================
REM TITAN V14 — TRNG Entropy Test Runner
REM Compiles TB, runs GHDL simulation, and executes Python analysis
REM ============================================================

set RTL=..\..\rtl
set TOOLS_DIR=%~dp0

echo ============================================================
echo   TITAN V14 — TRNG Entropy Test
echo ============================================================
echo.

REM -- Step 1: Analyze required source files
echo [1/4] Compiling VHDL sources...
ghdl -a --std=08 --work=work "%RTL%\common\trng_ring_osc.vhd" 2>&1
if errorlevel 1 (echo [FAIL] trng_ring_osc.vhd & exit /b 1)

ghdl -a --std=08 --work=work "%RTL%\common\trng_wrapper.vhd" 2>&1
if errorlevel 1 (echo [FAIL] trng_wrapper.vhd & exit /b 1)

ghdl -a --std=08 --work=work "%TOOLS_DIR%tb_trng_capture.vhd" 2>&1
if errorlevel 1 (echo [FAIL] tb_trng_capture.vhd & exit /b 1)

echo   [OK] All sources compiled

REM -- Step 2: Elaborate
echo [2/4] Elaborating testbench...
ghdl -e --std=08 --work=work tb_trng_capture 2>&1
if errorlevel 1 (echo [FAIL] Elaborate failed & exit /b 1)
echo   [OK] Elaboration complete

REM -- Step 3: Run simulation
echo [3/4] Running GHDL simulation (capturing 128K bits)...
ghdl -r --std=08 --work=work tb_trng_capture --stop-time=10ms 2>&1
if errorlevel 1 (echo [FAIL] Simulation failed & exit /b 1)
echo   [OK] Simulation complete

REM -- Step 4: Run Python analysis
echo [4/4] Running NIST entropy analysis...
python "%TOOLS_DIR%nist_entropy_test.py" trng_output.txt 2>&1
if errorlevel 1 (
    echo   [WARN] Some entropy tests failed
) else (
    echo   [OK] All entropy tests passed
)

REM -- Copy report
if exist TRNG_ENTROPY_REPORT.md (
    echo.
    echo   Report: TRNG_ENTROPY_REPORT.md
)

echo.
echo ============================================================
echo   COMPLETE
echo ============================================================
