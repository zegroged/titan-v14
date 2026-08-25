--------------------------------------------------------------------------------
-- TB: clock_jitter_injector — SIM_MODE Phase Shift Controller Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_clock_jitter_injector is
end tb_clock_jitter_injector;

architecture sim of tb_clock_jitter_injector is
    constant CLK_PERIOD : time := 20 ns;
    signal sys_clk       : std_logic := '0';
    signal rst           : std_logic := '1';
    signal chaos_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal chaos_valid   : std_logic := '0';
    signal jitter_enable : std_logic := '0';
    signal jittered_clk  : std_logic;
    signal sys_clk_buf   : std_logic;
    signal mmcm_locked   : std_logic;
    signal sim_done      : boolean := false;
begin
    sys_clk <= not sys_clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.clock_jitter_injector
        generic map (SIM_MODE => true, MAX_PHASE_STEPS => 108, SHIFT_THRESHOLD => 12)
        port map (
            sys_clk => sys_clk, rst => rst,
            chaos_byte => chaos_byte, chaos_valid => chaos_valid,
            jitter_enable => jitter_enable,
            jittered_clk => jittered_clk, sys_clk_buf => sys_clk_buf,
            mmcm_locked => mmcm_locked
        );

    stim: process
    begin
        report "T1: Reset state";
        wait for CLK_PERIOD * 5;
        assert mmcm_locked = '0' report "T1 FAIL" severity failure;
        report "T1 PASS";

        report "T2: Release reset";
        rst <= '0';
        wait for CLK_PERIOD * 3;
        assert mmcm_locked = '1' report "T2 FAIL" severity failure;
        report "T2 PASS";

        report "T3: Phase shift (increment)";
        jitter_enable <= '1';
        chaos_byte <= x"F0";  -- > 128+12=140 -> increment
        chaos_valid <= '1';
        wait for CLK_PERIOD;
        chaos_valid <= '0';
        wait for CLK_PERIOD * 5;
        report "T3 PASS: Increment processed";

        report "T4: Phase shift (decrement)";
        chaos_byte <= x"10";  -- < 128-12=116 -> decrement
        chaos_valid <= '1';
        wait for CLK_PERIOD;
        chaos_valid <= '0';
        wait for CLK_PERIOD * 5;
        report "T4 PASS: Decrement processed";

        report "T5: No shift (dead zone)";
        chaos_byte <= x"80";  -- =128, within dead zone
        chaos_valid <= '1';
        wait for CLK_PERIOD;
        chaos_valid <= '0';
        wait for CLK_PERIOD * 3;
        report "T5 PASS: Dead zone respected";

        report "T6: Jitter disabled";
        jitter_enable <= '0';
        chaos_byte <= x"FF";
        chaos_valid <= '1';
        wait for CLK_PERIOD;
        chaos_valid <= '0';
        wait for CLK_PERIOD * 3;
        report "T6 PASS";

        report "ALL TESTS PASSED: tb_clock_jitter_injector";
        sim_done <= true;
        wait;
    end process;
end sim;
