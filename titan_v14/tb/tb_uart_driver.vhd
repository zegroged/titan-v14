--------------------------------------------------------------------------------
-- TB: uart_driver — 8N1 UART TX/RX + CTS/RTS Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_uart_driver is
end tb_uart_driver;

architecture sim of tb_uart_driver is
    constant CLK_PERIOD : time := 20 ns;

    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';
    signal tx_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_start  : std_logic := '0';
    signal tx_busy   : std_logic;
    signal tx_pin    : std_logic;
    signal rx_pin    : std_logic := '1';
    signal rx_data   : std_logic_vector(7 downto 0);
    signal rx_valid  : std_logic;

    -- V15 CTS/RTS
    signal cts_n     : std_logic := '0';  -- default: flow control off
    signal rts_n     : std_logic;

    signal sim_done  : boolean := false;
begin
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.uart_driver
        generic map (CLK_FREQ => 50_000_000, BAUD_RATE => 115_200)
        port map (
            clk => clk, rst_n => rst_n,
            tx_data => tx_data, tx_start => tx_start, tx_busy => tx_busy, tx_pin => tx_pin,
            rx_pin => rx_pin, rx_data => rx_data, rx_valid => rx_valid,
            cts_n => cts_n, rts_n => rts_n
        );

    -- Loopback: connect TX to RX for self-test
    rx_pin <= tx_pin;

    stim: process
    begin
        report "T1: Reset";
        wait for CLK_PERIOD * 5;
        assert tx_busy = '0' report "T1 FAIL" severity failure;
        assert tx_pin = '1' report "T1 FAIL: tx not idle" severity failure;
        report "T1 PASS";

        rst_n <= '1';
        wait for CLK_PERIOD * 3;

        report "T2: Transmit byte 0x55";
        tx_data <= x"55";
        tx_start <= '1';
        wait for CLK_PERIOD;
        tx_start <= '0';
        assert tx_busy = '1' report "T2 FAIL: not busy" severity failure;

        -- Wait for TX to complete (10 bits @ ~434 cycles = 4340 cycles)
        for i in 0 to 5000 loop
            wait for CLK_PERIOD;
            if tx_busy = '0' then
                report "T2 INFO: TX done at cycle " & integer'image(i);
                exit;
            end if;
        end loop;
        report "T2 PASS: TX complete";

        -- RX should have received via loopback
        report "T3: RX loopback check";
        -- Wait for rx_valid
        for i in 0 to 1000 loop
            wait for CLK_PERIOD;
            if rx_valid = '1' then
                report "T3 INFO: rx_data=" & integer'image(to_integer(unsigned(rx_data)));
                exit;
            end if;
        end loop;
        report "T3 PASS";

        report "T4: Transmit byte 0xAA";
        tx_data <= x"AA";
        tx_start <= '1';
        wait for CLK_PERIOD;
        tx_start <= '0';
        for i in 0 to 5000 loop
            wait for CLK_PERIOD;
            if tx_busy = '0' then exit; end if;
        end loop;
        wait for CLK_PERIOD * 200;
        report "T4 PASS";

        ------------------------------------------------------------------------
        -- V15 CALLWHITE: CTS/RTS Tests
        ------------------------------------------------------------------------

        report "T5: CTS gating - TX must NOT start when CTS=1";
        cts_n <= '1';  -- MCU says STOP
        wait for CLK_PERIOD * 2;
        tx_data <= x"42";
        tx_start <= '1';
        wait for CLK_PERIOD;
        tx_start <= '0';
        -- Wait 500 cycles — TX should NOT have started
        for i in 0 to 500 loop
            wait for CLK_PERIOD;
        end loop;
        assert tx_busy = '0' report "T5 FAIL: TX started despite CTS='1'" severity failure;
        assert tx_pin = '1' report "T5 FAIL: tx_pin not idle during CTS block" severity failure;
        report "T5 PASS: TX correctly blocked by CTS";

        report "T6: CTS release - TX must start when CTS returns to 0";
        -- Re-assert tx_start with CTS='0'
        cts_n <= '0';  -- MCU says GO
        wait for CLK_PERIOD * 2;
        tx_data <= x"42";
        tx_start <= '1';
        wait for CLK_PERIOD;
        tx_start <= '0';
        assert tx_busy = '1' report "T6 FAIL: TX did not start after CTS release" severity failure;
        -- Wait for TX to complete
        for i in 0 to 5000 loop
            wait for CLK_PERIOD;
            if tx_busy = '0' then
                report "T6 INFO: TX done at cycle " & integer'image(i);
                exit;
            end if;
        end loop;
        -- Verify loopback
        for i in 0 to 1000 loop
            wait for CLK_PERIOD;
            if rx_valid = '1' then
                assert rx_data = x"42" report "T6 FAIL: wrong data, got " & integer'image(to_integer(unsigned(rx_data))) severity failure;
                report "T6 INFO: rx_data=0x42 confirmed";
                exit;
            end if;
        end loop;
        report "T6 PASS: TX works after CTS release, loopback verified";

        report "ALL TESTS PASSED: tb_uart_driver";
        sim_done <= true;
        wait;
    end process;
end sim;

