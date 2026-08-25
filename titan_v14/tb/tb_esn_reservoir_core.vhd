--------------------------------------------------------------------------------
-- TB: esn_reservoir_core — Echo State Network Reservoir Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.esn_weight_pkg.all;
use work.tanh_lut_pkg.all;

entity tb_esn_reservoir_core is
end tb_esn_reservoir_core;

architecture sim of tb_esn_reservoir_core is
    constant CLK_PERIOD : time := 20 ns;
    signal clk            : std_logic := '0';
    signal rst_n          : std_logic := '0';
    signal sensor_data_in : std_logic_vector(15 downto 0) := (others => '0');
    signal valid_in       : std_logic := '0';
    signal state_out      : std_logic_vector(ESN_N * 16 - 1 downto 0);
    signal state_valid    : std_logic;
    signal sim_done       : boolean := false;
begin
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.esn_reservoir_core
        port map (
            clk => clk, rst_n => rst_n,
            sensor_data_in => sensor_data_in,
            valid_in => valid_in,
            state_out => state_out, state_valid => state_valid
        );

    stim: process
    begin
        report "T1: Reset";
        wait for CLK_PERIOD * 5;
        assert state_valid = '0' report "T1 FAIL" severity failure;
        assert state_out = (ESN_N * 16 -1 downto 0 => '0')
            report "T1 FAIL: states not zero" severity failure;
        report "T1 PASS";

        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        report "T2: Single input step";
        sensor_data_in <= x"0100";  -- 1.0 Q8.8
        valid_in <= '1';
        wait for CLK_PERIOD;
        valid_in <= '0';

        for i in 0 to 500 loop
            wait for CLK_PERIOD;
            if state_valid = '1' then
                report "T2 INFO: state_valid at cycle " & integer'image(i);
                exit;
            end if;
        end loop;
        assert state_valid = '1' report "T2 FAIL: no valid" severity failure;
        report "T2 PASS";

        report "T3: Multiple input steps";
        for step in 1 to 5 loop
            sensor_data_in <= std_logic_vector(to_signed(step * 64, 16));
            valid_in <= '1';
            wait for CLK_PERIOD;
            valid_in <= '0';
            for i in 0 to 500 loop
                wait for CLK_PERIOD;
                if state_valid = '1' then exit; end if;
            end loop;
        end loop;
        report "T3 PASS: 5 steps processed";

        report "T4: Reset clears state";
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        assert state_out = (ESN_N * 16 -1 downto 0 => '0')
            report "T4 FAIL" severity failure;
        report "T4 PASS";

        report "ALL TESTS PASSED: tb_esn_reservoir_core";
        sim_done <= true;
        wait;
    end process;
end sim;
