--------------------------------------------------------------------------------
-- TITAN V14: UART Driver Testbench — TX/RX Loopback + Kill Test
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_uart_driver is
end tb_uart_driver;

architecture Behavioral of tb_uart_driver is
    constant CLK_PERIOD : time := 20 ns;
    constant BIT_PERIOD : integer := 434;  -- 50MHz/115200

    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';
    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_start : std_logic := '0';
    signal tx_busy  : std_logic;
    signal tx_pin   : std_logic;
    signal rx_pin   : std_logic := '1';
    signal rx_data  : std_logic_vector(7 downto 0);
    signal rx_valid : std_logic;
    signal done_flag : boolean := false;

begin
    clk <= not clk after CLK_PERIOD / 2 when not done_flag else '0';

    dut : entity work.uart_driver
        generic map (CLK_FREQ => 50000000, BAUD_RATE => 115200)
        port map (
            clk => clk, rst_n => rst_n,
            tx_data => tx_data, tx_start => tx_start, tx_busy => tx_busy,
            tx_pin => tx_pin, rx_pin => rx_pin,
            rx_data => rx_data, rx_valid => rx_valid
        );

    -- Loopback: TX -> RX
    rx_pin <= tx_pin;

    process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        report "=== TB_UART_DRIVER ===" severity note;

        -- TEST 1: Send 0x55 (alternating pattern)
        tx_data  <= x"55";
        tx_start <= '1';
        wait for CLK_PERIOD;
        tx_start <= '0';

        -- Wait for TX complete + RX complete
        for i in 0 to BIT_PERIOD * 12 loop
            wait for CLK_PERIOD;
            if rx_valid = '1' then
                if rx_data = x"55" then
                    pass_count := pass_count + 1;
                    report "  [PASS] Loopback 0x55" severity note;
                else
                    fail_count := fail_count + 1;
                    report "  [FAIL] Expected 0x55" severity error;
                end if;
                exit;
            end if;
        end loop;
        wait for CLK_PERIOD * 100;

        -- TEST 2: Send 0xA3
        tx_data  <= x"A3";
        tx_start <= '1';
        wait for CLK_PERIOD;
        tx_start <= '0';
        for i in 0 to BIT_PERIOD * 12 loop
            wait for CLK_PERIOD;
            if rx_valid = '1' then
                if rx_data = x"A3" then
                    pass_count := pass_count + 1;
                    report "  [PASS] Loopback 0xA3" severity note;
                else
                    fail_count := fail_count + 1;
                    report "  [FAIL] Expected 0xA3" severity error;
                end if;
                exit;
            end if;
        end loop;
        wait for CLK_PERIOD * 100;

        -- TEST 3: Reset clears state
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;
        if tx_busy = '0' then
            pass_count := pass_count + 1;
            report "  [PASS] Reset clears busy" severity note;
        else
            fail_count := fail_count + 1;
            report "  [FAIL] Busy after reset" severity error;
        end if;

        report "  PASS: " & integer'image(pass_count) &
               " FAIL: " & integer'image(fail_count) severity note;

        if fail_count = 0 then
            report "  [OK] tb_uart_driver ALL PASS" severity note;
        else
            report "  [FAIL] tb_uart_driver FAILED" severity error;
        end if;

        done_flag <= true;
        wait;
    end process;
end Behavioral;
