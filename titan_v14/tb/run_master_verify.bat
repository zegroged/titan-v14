@echo off
REM ============================================================================
REM  TITAN V14.3: MASTER VERIFICATION SUITE (REBUILT)
REM  IEEE 1076-2008 | NIST FIPS-197/180-4 | SP800-90B | RFC-4231 | FIPS 140-3
REM ============================================================================

set GHDL=ghdl
set SRC=..\rtl\common
set STD=--std=08
set PASS=0
set FAIL=0
set TOTAL=0

echo.
echo ====================================================================
echo   TITAN V14.3 MASTER VERIFICATION SUITE (REBUILT)
echo   Simulator: GHDL 5.1.1 ^| All vectors Python cross-verified
echo   Date: %DATE% %TIME%
echo ====================================================================
echo.

REM ====================================================================
REM  TEST 1: AES S-Box Exhaustive (NIST FIPS-197 Table 4)
REM ====================================================================
echo  TEST 1/14: AES S-Box 256-Entry Exhaustive (FIPS-197 Table 4)
set WORKDIR=work_t1
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_sbox_exhaustive.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_sbox_exhaustive 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_sbox_exhaustive --stop-time=30ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 2: AES Key Expansion (NIST FIPS-197 Appendix A.3)
REM ====================================================================
echo  TEST 2/14: AES-256 Key Expansion 15 Round Keys (FIPS-197 A.3)
set WORKDIR=work_t2
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_key_expand.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% aes_key_expand_tb.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% aes_key_expand_tb 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% aes_key_expand_tb --stop-time=10ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 3: AES-256 Multi-Vector (FIPS-197 C.3 + SP800-38A)
REM ====================================================================
echo  TEST 3/14: AES-256 Multi-Vector KAT (3 NIST Sources)
set WORKDIR=work_t3
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox_masked.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_round.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_key_expand.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes256_core.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% aes256_multi_vector_tb.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% aes256_multi_vector_tb 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% aes256_multi_vector_tb --stop-time=10ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 4: SHA-256 NIST FIPS 180-4
REM ====================================================================
echo  TEST 4/14: SHA-256 NIST FIPS 180-4 (2 vectors + kill)
set WORKDIR=work_t4
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\sha256_core.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_sha256.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_sha256 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_sha256 --stop-time=30ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 5: HMAC-SHA256 RFC-4231 KAT (YENI)
REM ====================================================================
echo  TEST 5/14: HMAC-SHA256 RFC-4231 KAT (4 vectors, Python verified)
set WORKDIR=work_t5
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\sha256_core.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\hmac_sha256.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_hmac_rfc4231.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_hmac_rfc4231 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_hmac_rfc4231 --stop-time=100ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 6: POST Self-Test (FIPS 140-3 §4.9)
REM ====================================================================
echo  TEST 6/14: POST Self-Test (FIPS 140-3)
set WORKDIR=work_t6
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox_masked.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_round.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_key_expand.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes256_core.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\post_self_test.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\system_supervisor.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_post_supervisor.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_post_supervisor 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_post_supervisor --stop-time=50ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 7: Watchdog Monitor (MAD Heartbeat)
REM ====================================================================
echo  TEST 7/14: Watchdog Monitor V2 (MAD Heartbeat)
set WORKDIR=work_t7
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\watchdog_monitor.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_watchdog_v2.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_watchdog_v2 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_watchdog_v2 --stop-time=30ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 8: Kill Chain Exhaustive (FIPS 140-3 §4.5) (YENI)
REM ====================================================================
echo  TEST 8/14: Kill Chain Exhaustive (14 sources, FIPS 140-3)
set WORKDIR=work_t8
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% tb_kill_chain_full.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_kill_chain_full 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_kill_chain_full --stop-time=10ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 9: TRNG Health + Reseed (SP 800-90B) (YENI)
REM ====================================================================
echo  TEST 9/14: TRNG Health + Reseed (SP 800-90B)
set WORKDIR=work_t9
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\trng_ring_osc.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\trng_wrapper.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_trng_health.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_trng_health 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_trng_health --stop-time=500ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 10: Data Gearbox (8-bit UART <-> 128-bit AES Bridge)
REM ====================================================================
echo  TEST 10/14: Data Gearbox (PKCS#7 + Timeout)
set WORKDIR=work_t10
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\data_gearbox.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_data_gearbox.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_data_gearbox 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_data_gearbox --stop-time=50ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 11: SPI Key Loader (Split-Key + Dead-Man + 3-Strike)
REM ====================================================================
echo  TEST 11/14: SPI Key Loader (Split-Key + Security)
ver > nul
set WORKDIR=work_t11
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox_masked.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_round.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_key_expand.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes256_core.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\spi_key_unwrap.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\key_loader_spi.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_key_loader_spi.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_key_loader_spi 2>&1
cmd /c "%GHDL% -r %STD% --workdir=%WORKDIR% tb_key_loader_spi --stop-time=200ms --assert-level=failure 2>&1"
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 12: Firmware Integrity (SHA-256 Config Hash)
REM ====================================================================
echo  TEST 12/14: Firmware Integrity (SHA-256 Hash Check)
ver > nul
set WORKDIR=work_t12
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\sha256_core.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\firmware_integrity.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_firmware_integrity.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_firmware_integrity 2>&1
cmd /c "%GHDL% -r %STD% --workdir=%WORKDIR% tb_firmware_integrity --stop-time=200ms --assert-level=failure 2>&1"
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 13: Comm Protocol (Full-Duplex Encrypted Communication)
REM ====================================================================
echo  TEST 13/14: Comm Protocol (TX/RX FSM + AES Arbitration)
set WORKDIR=work_t13
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\comm_protocol.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_comm_protocol.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_comm_protocol 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_comm_protocol --stop-time=50ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 14: AEGIS Anomaly Detection (ESN Reservoir Pipeline)
REM ====================================================================
echo  TEST 14/14: AEGIS Anomaly Detection (AXI-S Pipeline)
set WORKDIR=work_t14
set AEGIS=..\rtl\aegis
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\esn_weight_pkg.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\tanh_lut_pkg.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\tanh_lut_rom.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\shift_add_multiplier.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\esn_reservoir_core.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\esn_readout.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\anomaly_detector.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %AEGIS%\aegis_top.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_aegis_top.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_aegis_top 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_aegis_top --stop-time=200ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 15: 2nd-Order Masked S-Box (DOM Verification)
REM ====================================================================
echo  TEST 15/17: 2nd-Order Masked S-Box (DOM, 5 mask pairs, 1280 checks)
set WORKDIR=work_t15
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\aes_sbox_masked_2nd.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_sbox_2nd_order.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_sbox_2nd_order 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_sbox_2nd_order --stop-time=50ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 16: SEU Scrubber FSM (Logic-only, no FRAME_ECC primitive)
REM ====================================================================
echo  TEST 16/17: SEU Scrubber FSM (Simulation Mode)
set WORKDIR=work_t16
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\seu_scrubber.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_seu_scrubber.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_seu_scrubber 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_seu_scrubber --stop-time=10ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  TEST 17: Extended SVN Counter (Hash Chain Verification)
REM ====================================================================
echo  TEST 17/17: Extended SVN Counter (Increment + Rollback Detection)
set WORKDIR=work_t17
if exist %WORKDIR% rmdir /s /q %WORKDIR%
mkdir %WORKDIR%
%GHDL% -a %STD% --workdir=%WORKDIR% %SRC%\svn_extended.vhd 2>&1
%GHDL% -a %STD% --workdir=%WORKDIR% tb_svn_extended.vhd 2>&1
%GHDL% -e %STD% --workdir=%WORKDIR% tb_svn_extended 2>&1
%GHDL% -r %STD% --workdir=%WORKDIR% tb_svn_extended --stop-time=100ms --assert-level=error 2>&1
if errorlevel 1 (set /a FAIL+=1 & echo   [FAIL]) else (set /a PASS+=1 & echo   [PASS])
set /a TOTAL+=1
echo.

REM ====================================================================
REM  CLEANUP
REM ====================================================================
echo  Cleaning up work directories...
for /d %%d in (work_t*) do rmdir /s /q "%%d" 2>nul

REM ====================================================================
REM  SUMMARY
REM ====================================================================
echo.
echo ====================================================================
echo   TITAN V14.3 REGRESSION RESULTS
echo   Date: %DATE% %TIME%
echo   -----------------------------------------------
echo   Total Tests: %TOTAL%
echo   PASSED:      %PASS%
echo   FAILED:      %FAIL%
if %FAIL% EQU 0 (
    echo   VERDICT: *** ALL %TOTAL% TESTS PASSED ***
) else (
    echo   VERDICT: *** %FAIL% of %TOTAL% TESTS FAILED ***
)
echo   -----------------------------------------------
echo   Standards Coverage:
echo     NIST FIPS-197   AES-256 S-Box + Key Expand + Multi-Vector
echo     NIST FIPS 180-4 SHA-256
echo     RFC 4231        HMAC-SHA256 KAT
echo     FIPS 140-3      POST Self-Test + Kill Chain + Firmware Integrity
echo     SP 800-90B      TRNG Health Tests
echo     RFC 5652        PKCS#7 Padding (Data Gearbox)
echo     FIPS 140-3 Key  SPI Key Injection + Split-Key
echo     AXI4-Stream     AEGIS Anomaly Detection Pipeline
echo     DOM Masking     2nd-Order CPA Resistance (5 mask pairs)
echo     SEU Protection  Config Memory Scrubber FSM
echo     Anti-Rollback   Extended SVN Hash Chain Counter
echo ====================================================================

