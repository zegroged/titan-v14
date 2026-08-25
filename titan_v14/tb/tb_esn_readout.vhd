--------------------------------------------------------------------------------
-- TB: esn_readout — ESN Readout (Dot Product) Layer Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.esn_weight_pkg.all;

entity tb_esn_readout is
end tb_esn_readout;

architecture sim of tb_esn_readout is
    constant CLK_PERIOD : time := 20 ns;
    signal clk              : std_logic := '0';
    signal rst_n            : std_logic := '0';
    signal state_vector     : std_logic_vector(ESN_N * 16 - 1 downto 0) := (others => '0');
    signal state_valid      : std_logic := '0';
    signal weights_wr_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal weights_wr_addr  : std_logic_vector(2 downto 0) := (others => '0');
    signal weights_wr_en    : std_logic := '0';
    signal weights_swap     : std_logic := '0';
    signal prediction       : std_logic_vector(15 downto 0);
    signal prediction_valid : std_logic;
    signal sim_done         : boolean := false;
begin
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.esn_readout
        generic map (ADDR_BITS => 3)
        port map (
            clk => clk, rst_n => rst_n,
            state_vector => state_vector, state_valid => state_valid,
            weights_wr_data => weights_wr_data, weights_wr_addr => weights_wr_addr,
            weights_wr_en => weights_wr_en, weights_swap => weights_swap,
            prediction => prediction, prediction_valid => prediction_valid
        );

    stim: process
    begin
        report "T1: Reset";
        wait for CLK_PERIOD * 5;
        assert prediction_valid = '0' report "T1 FAIL" severity failure;
        report "T1 PASS";

        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- T2: Write weights to shadow bank, swap
        report "T2: Weight programming";
        for i in 0 to ESN_N-1 loop
            weights_wr_data <= x"0100";  -- weight = 1.0 Q8.8
            weights_wr_addr <= std_logic_vector(to_unsigned(i, 3));
            weights_wr_en <= '1';
            wait for CLK_PERIOD;
        end loop;
        weights_wr_en <= '0';
        weights_swap <= '1';
        wait for CLK_PERIOD;
        weights_swap <= '0';
        wait for CLK_PERIOD;
        report "T2 PASS: Weights programmed and swapped";

        -- T3: Feed state vector (all = 0.5)
        report "T3: Prediction with uniform state";
        for i in 0 to ESN_N-1 loop
            state_vector((i+1)*16-1 downto i*16) <= x"0080"; -- 0.5 Q8.8
        end loop;
        state_valid <= '1';
        wait for CLK_PERIOD;
        state_valid <= '0';

        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if prediction_valid = '1' then
                report "T3 INFO: prediction=" & integer'image(to_integer(signed(prediction)));
                exit;
            end if;
        end loop;
        assert prediction_valid = '1' report "T3 FAIL" severity failure;
        report "T3 PASS";

        -- T4: Zero state vector
        report "T4: Zero state prediction";
        state_vector <= (others => '0');
        state_valid <= '1';
        wait for CLK_PERIOD;
        state_valid <= '0';

        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if prediction_valid = '1' then exit; end if;
        end loop;
        assert prediction = x"0000"
            report "T4 FAIL: expected 0" severity failure;
        report "T4 PASS";

        report "ALL TESTS PASSED: tb_esn_readout";
        sim_done <= true;
        wait;
    end process;
end sim;
