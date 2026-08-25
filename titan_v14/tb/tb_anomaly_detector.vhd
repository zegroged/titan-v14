--------------------------------------------------------------------------------
-- TB: anomaly_detector — Threshold Comparator Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_anomaly_detector is
end tb_anomaly_detector;

architecture sim of tb_anomaly_detector is
    constant CLK_PERIOD : time := 20 ns;
    signal clk              : std_logic := '0';
    signal rst_n            : std_logic := '0';
    signal prediction       : std_logic_vector(15 downto 0) := (others => '0');
    signal actual_value     : std_logic_vector(15 downto 0) := (others => '0');
    signal data_valid       : std_logic := '0';
    signal threshold        : std_logic_vector(15 downto 0) := x"0080";
    signal threshold_wr_en  : std_logic := '0';
    signal clear_flag       : std_logic := '0';
    signal anomaly_flag     : std_logic;
    signal error_magnitude  : std_logic_vector(15 downto 0);
    signal consecutive_count: std_logic_vector(7 downto 0);
    signal sim_done         : boolean := false;
begin
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.anomaly_detector
        generic map (WINDOW_SIZE => 4)
        port map (
            clk => clk, rst_n => rst_n,
            prediction => prediction, actual_value => actual_value,
            data_valid => data_valid,
            threshold => threshold, threshold_wr_en => threshold_wr_en,
            clear_flag => clear_flag,
            anomaly_flag => anomaly_flag,
            error_magnitude => error_magnitude,
            consecutive_count => consecutive_count
        );

    stim: process
    begin
        report "T1: Reset";
        wait for CLK_PERIOD * 5;
        assert anomaly_flag = '0' report "T1 FAIL" severity failure;
        report "T1 PASS";

        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- T2: Normal data (error < threshold)
        report "T2: Under threshold";
        prediction <= x"0100";    -- 1.0
        actual_value <= x"00F0";  -- ~0.94
        data_valid <= '1';
        wait for CLK_PERIOD;
        data_valid <= '0';
        wait for CLK_PERIOD;
        assert anomaly_flag = '0' report "T2 FAIL" severity failure;
        report "T2 INFO: error=" & integer'image(to_integer(unsigned(error_magnitude)));
        report "T2 PASS";

        -- T3: Over threshold but less than WINDOW_SIZE
        report "T3: Over threshold (1/4)";
        prediction <= x"0200";    -- 2.0
        actual_value <= x"0000";  -- 0.0
        data_valid <= '1';
        wait for CLK_PERIOD;
        data_valid <= '0';
        wait for CLK_PERIOD;
        assert anomaly_flag = '0' report "T3 FAIL: premature flag" severity failure;
        report "T3 PASS";

        -- T4: Trigger anomaly (4 consecutive over threshold)
        report "T4: Full window trigger";
        for i in 1 to 4 loop
            data_valid <= '1';
            wait for CLK_PERIOD;
            data_valid <= '0';
            wait for CLK_PERIOD;
        end loop;
        assert anomaly_flag = '1'
            report "T4 FAIL: flag not set" severity failure;
        report "T4 INFO: consec=" & integer'image(to_integer(unsigned(consecutive_count)));
        report "T4 PASS";

        -- T5: Latch persists after normal data
        report "T5: Latch persistence";
        prediction <= x"0100";
        actual_value <= x"00F0";
        data_valid <= '1';
        wait for CLK_PERIOD;
        data_valid <= '0';
        wait for CLK_PERIOD;
        assert anomaly_flag = '1' report "T5 FAIL: flag cleared" severity failure;
        report "T5 PASS";

        -- T6: Clear flag
        report "T6: Clear flag";
        clear_flag <= '1';
        wait for CLK_PERIOD;
        clear_flag <= '0';
        wait for CLK_PERIOD;
        assert anomaly_flag = '0' report "T6 FAIL" severity failure;
        report "T6 PASS";

        -- T7: Threshold update
        report "T7: Threshold update";
        threshold <= x"1000";  -- Very high threshold
        threshold_wr_en <= '1';
        wait for CLK_PERIOD;
        threshold_wr_en <= '0';
        prediction <= x"0200";
        actual_value <= x"0000";
        for i in 1 to 5 loop
            data_valid <= '1';
            wait for CLK_PERIOD;
            data_valid <= '0';
            wait for CLK_PERIOD;
        end loop;
        assert anomaly_flag = '0'
            report "T7 FAIL: flag raised with high threshold" severity failure;
        report "T7 PASS";

        report "ALL TESTS PASSED: tb_anomaly_detector";
        sim_done <= true;
        wait;
    end process;
end sim;
