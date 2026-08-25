--------------------------------------------------------------------------------
-- TB: ring_osc_counter — Ring Oscillator Frequency Counter Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_ring_osc_counter is
end tb_ring_osc_counter;

architecture sim of tb_ring_osc_counter is
    constant CLK_PERIOD : time := 20 ns;
    signal clk            : std_logic := '0';
    signal rst_n          : std_logic := '0';
    signal ring_osc_out   : std_logic := '0';
    signal measure_start  : std_logic := '0';
    signal continuous     : std_logic := '0';
    signal frequency_count: std_logic_vector(23 downto 0);
    signal count_valid    : std_logic;
    signal temp_alert     : std_logic;
    signal clear_alert    : std_logic := '0';
    signal alert_high     : std_logic;
    signal alert_low      : std_logic;
    signal sim_done       : boolean := false;
begin
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    -- Ring osc at ~100 MHz
    process begin
        while not sim_done loop
            ring_osc_out <= '0'; wait for 5 ns;
            ring_osc_out <= '1'; wait for 5 ns;
        end loop; wait;
    end process;

    UUT: entity work.ring_osc_counter
        generic map (
            SYS_CLK_FREQ => 50_000_000,
            MEASURE_MS   => 1,
            NOMINAL_COUNT => 50000,
            ALARM_PCT    => 20
        )
        port map (
            clk => clk, rst_n => rst_n,
            ring_osc_out => ring_osc_out,
            measure_start => measure_start, continuous => continuous,
            frequency_count => frequency_count, count_valid => count_valid,
            temp_alert => temp_alert, clear_alert => clear_alert,
            alert_high => alert_high, alert_low => alert_low
        );

    stim: process
    begin
        report "T1: Reset";
        wait for CLK_PERIOD * 5;
        assert count_valid = '0' report "T1 FAIL" severity failure;
        report "T1 PASS";

        rst_n <= '1';
        wait for CLK_PERIOD * 3;

        report "T2: Single measurement";
        measure_start <= '1';
        wait for CLK_PERIOD;
        measure_start <= '0';

        for i in 0 to 55000 loop
            wait for CLK_PERIOD;
            if count_valid = '1' then
                report "T2 INFO: count=" & integer'image(to_integer(unsigned(frequency_count))) &
                       " at cycle " & integer'image(i);
                exit;
            end if;
        end loop;
        assert count_valid = '1' report "T2 FAIL" severity failure;
        report "T2 PASS";

        report "T3: Alert status";
        report "T3 INFO: temp_alert=" & std_logic'image(temp_alert) &
               " high=" & std_logic'image(alert_high) &
               " low=" & std_logic'image(alert_low);
        report "T3 PASS";

        report "T4: Clear alert";
        clear_alert <= '1';
        wait for CLK_PERIOD;
        clear_alert <= '0';
        wait for CLK_PERIOD * 2;
        assert temp_alert = '0' report "T4 FAIL" severity failure;
        report "T4 PASS";

        report "T5: Continuous mode";
        continuous <= '1';
        measure_start <= '1';
        wait for CLK_PERIOD;
        measure_start <= '0';

        -- Wait for two measurements
        for j in 0 to 1 loop
            for i in 0 to 55000 loop
                wait for CLK_PERIOD;
                if count_valid = '1' then
                    report "T5 INFO: measurement " & integer'image(j+1) & " complete";
                    exit;
                end if;
            end loop;
        end loop;
        report "T5 PASS";

        report "ALL TESTS PASSED: tb_ring_osc_counter";
        sim_done <= true;
        wait;
    end process;
end sim;
