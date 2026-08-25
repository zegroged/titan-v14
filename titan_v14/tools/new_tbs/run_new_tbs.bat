@echo off
REM ============================================================
REM TITAN V14 -- Missing Testbench Runner (5 new TBs)
REM ============================================================

set RTL=..\..\rtl
set COM=%RTL%\common
set TOOLS_DIR=%~dp0

echo ============================================================
echo   TITAN V14 -- 5 New Testbenches
echo ============================================================
echo.

pushd "%TOOLS_DIR%"

set PASS=0
set FAIL=0

REM --- Common source compile ---
echo [COMPILE] Common sources...
ghdl -a --std=08 --work=work "%COM%\aes_sbox.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\aes_sbox_masked.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\aes_key_expand.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\aes_round.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\aes256_core.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\uart_driver.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\data_gearbox.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\key_loader_spi.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\spi_cmd_slave.vhd" 2>nul
ghdl -a --std=08 --work=work "%COM%\comm_protocol.vhd" 2>nul

REM --- TB 1: uart_driver ---
echo.
echo [1/5] tb_uart_driver
ghdl -a --std=08 --work=work "%COM%\tb_uart_driver.vhd" 2>&1
if errorlevel 1 (echo   [FAIL] compile & set /a FAIL+=1 & goto TB2)
ghdl -e --std=08 --work=work tb_uart_driver 2>&1
if errorlevel 1 (echo   [FAIL] elaborate & set /a FAIL+=1 & goto TB2)
ghdl -r --std=08 --work=work tb_uart_driver --stop-time=50ms 2>&1
set /a PASS+=1

:TB2
echo.
echo [2/5] tb_data_gearbox
ghdl -a --std=08 --work=work "%COM%\tb_data_gearbox.vhd" 2>&1
if errorlevel 1 (echo   [FAIL] compile & set /a FAIL+=1 & goto TB3)
ghdl -e --std=08 --work=work tb_data_gearbox 2>&1
if errorlevel 1 (echo   [FAIL] elaborate & set /a FAIL+=1 & goto TB3)
ghdl -r --std=08 --work=work tb_data_gearbox --stop-time=5ms 2>&1
set /a PASS+=1

:TB3
echo.
echo [3/5] tb_key_loader_spi
ghdl -a --std=08 --work=work "%COM%\tb_key_loader_spi.vhd" 2>&1
if errorlevel 1 (echo   [FAIL] compile & set /a FAIL+=1 & goto TB4)
ghdl -e --std=08 --work=work tb_key_loader_spi 2>&1
if errorlevel 1 (echo   [FAIL] elaborate & set /a FAIL+=1 & goto TB4)
ghdl -r --std=08 --work=work tb_key_loader_spi --stop-time=10ms 2>&1
set /a PASS+=1

:TB4
echo.
echo [4/5] tb_spi_cmd_slave
ghdl -a --std=08 --work=work "%COM%\tb_spi_cmd_slave.vhd" 2>&1
if errorlevel 1 (echo   [FAIL] compile & set /a FAIL+=1 & goto TB5)
ghdl -e --std=08 --work=work tb_spi_cmd_slave 2>&1
if errorlevel 1 (echo   [FAIL] elaborate & set /a FAIL+=1 & goto TB5)
ghdl -r --std=08 --work=work tb_spi_cmd_slave --stop-time=5ms 2>&1
set /a PASS+=1

:TB5
echo.
echo [5/5] tb_comm_protocol
ghdl -a --std=08 --work=work "%COM%\tb_comm_protocol.vhd" 2>&1
if errorlevel 1 (echo   [FAIL] compile & set /a FAIL+=1 & goto DONE)
ghdl -e --std=08 --work=work tb_comm_protocol 2>&1
if errorlevel 1 (echo   [FAIL] elaborate & set /a FAIL+=1 & goto DONE)
ghdl -r --std=08 --work=work tb_comm_protocol --stop-time=5ms 2>&1
set /a PASS+=1

:DONE
popd

echo.
echo ============================================================
echo   RESULTS: %PASS% compiled/ran, %FAIL% failed
echo ============================================================
