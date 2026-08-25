--------------------------------------------------------------------------------
-- TB: dummy_op_injector — Shadow AES Round DPA Countermeasure Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_dummy_op_injector is
end tb_dummy_op_injector;

architecture sim of tb_dummy_op_injector is
    constant CLK_PERIOD : time := 20 ns;
    signal clk             : std_logic := '0';
    signal rst_n           : std_logic := '0';
    signal aes_round_start : std_logic := '0';
    signal aes_stall       : std_logic;
    signal chaos_value     : std_logic_vector(31 downto 0) := (others => '0');
    signal chaos_valid     : std_logic := '0';
    signal dummy_enable    : std_logic := '0';
    signal dummy_active    : std_logic;
    signal dummy_count_out : std_logic_vector(1 downto 0);
    signal total_dummies   : std_logic_vector(15 downto 0);
    signal total_rounds    : std_logic_vector(15 downto 0);
    signal sim_done        : boolean := false;
begin
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.dummy_op_injector
        generic map (MAX_DUMMIES => 3)
        port map (
            clk => clk, rst_n => rst_n,
            aes_round_start => aes_round_start, aes_stall => aes_stall,
            chaos_value => chaos_value, chaos_valid => chaos_valid,
            dummy_enable => dummy_enable, dummy_active => dummy_active,
            dummy_count_out => dummy_count_out,
            total_dummies => total_dummies, total_rounds => total_rounds
        );

    stim: process
    begin
        report "T1: Reset state";
        wait for CLK_PERIOD * 5;
        assert aes_stall = '0' report "T1 FAIL" severity failure;
        assert total_dummies = x"0000" report "T1 FAIL" severity failure;
        report "T1 PASS";

        rst_n <= '1';
        dummy_enable <= '1';
        wait for CLK_PERIOD * 2;

        report "T2: Round with 0 dummies (chaos[1:0]=00)";
        chaos_value <= x"00000000";
        chaos_valid <= '1';
        wait for CLK_PERIOD;
        chaos_valid <= '0';
        wait for CLK_PERIOD;
        aes_round_start <= '1';
        wait for CLK_PERIOD;
        aes_round_start <= '0';
        wait for CLK_PERIOD * 5;
        assert total_rounds = x"0001" report "T2 FAIL rounds" severity failure;
        assert total_dummies = x"0000" report "T2 FAIL dummies" severity failure;
        report "T2 PASS";

        report "T3: Round with 3 dummies (chaos[1:0]=11)";
        chaos_value <= x"00000003";
        chaos_valid <= '1';
        wait for CLK_PERIOD;
        chaos_valid <= '0';
        wait for CLK_PERIOD;
        aes_round_start <= '1';
        wait for CLK_PERIOD;
        aes_round_start <= '0';
        wait for CLK_PERIOD * 10;
        assert total_rounds = x"0002" report "T3 FAIL rounds" severity failure;
        assert total_dummies = x"0003" report "T3 FAIL dummies" severity failure;
        report "T3 PASS";

        report "T4: Stall during dummy rounds";
        chaos_value <= x"00000002";
        chaos_valid <= '1';
        wait for CLK_PERIOD;
        chaos_valid <= '0';
        wait for CLK_PERIOD;
        aes_round_start <= '1';
        wait for CLK_PERIOD;
        aes_round_start <= '0';
        wait for CLK_PERIOD;
        assert aes_stall = '1' report "T4 FAIL: stall not asserted" severity failure;
        wait for CLK_PERIOD * 10;
        report "T4 PASS";

        report "T5: Disabled -> no stall";
        dummy_enable <= '0';
        aes_round_start <= '1';
        wait for CLK_PERIOD;
        aes_round_start <= '0';
        wait for CLK_PERIOD * 3;
        assert aes_stall = '0' report "T5 FAIL" severity failure;
        report "T5 PASS";

        report "ALL TESTS PASSED: tb_dummy_op_injector";
        sim_done <= true;
        wait;
    end process;
end sim;
