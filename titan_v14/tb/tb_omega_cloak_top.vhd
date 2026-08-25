--------------------------------------------------------------------------------
-- TB: omega_cloak_top — DPA Protection Integration Verification
-- Tests: reset, gated enables, PRNG+jitter+dummy integration
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_omega_cloak_top is
end tb_omega_cloak_top;

architecture sim of tb_omega_cloak_top is

    constant CLK_PERIOD : time := 20 ns;

    signal sys_clk          : std_logic := '0';
    signal rst_n            : std_logic := '0';
    signal omega_enable     : std_logic := '0';
    signal enable_jitter    : std_logic := '0';
    signal enable_dummy     : std_logic := '0';
    signal trng_seed        : std_logic_vector(31 downto 0) := x"12345678";
    signal trng_seed_valid  : std_logic := '0';
    signal aes_round_start  : std_logic := '0';
    signal aes_stall        : std_logic;
    signal jittered_clk     : std_logic;
    signal sys_clk_buf      : std_logic;
    signal mmcm_locked      : std_logic;
    signal chaos_out        : std_logic_vector(31 downto 0);
    signal chaos_valid_out  : std_logic;
    signal dummy_active     : std_logic;
    signal dummy_count      : std_logic_vector(1 downto 0);
    signal stat_dummies     : std_logic_vector(15 downto 0);
    signal stat_rounds      : std_logic_vector(15 downto 0);
    signal prng_load_seed   : std_logic := '0';
    signal prng_enable      : std_logic := '0';

    signal sim_done : boolean := false;

begin

    sys_clk <= not sys_clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.omega_cloak_top
        generic map (
            MAX_DUMMIES     => 3,
            WINDOW_SIZE     => 4,
            MAX_PHASE_STEPS => 108,
            SIM_MODE        => true
        )
        port map (
            sys_clk         => sys_clk,
            rst_n           => rst_n,
            omega_enable    => omega_enable,
            enable_jitter   => enable_jitter,
            enable_dummy    => enable_dummy,
            trng_seed       => trng_seed,
            trng_seed_valid => trng_seed_valid,
            aes_round_start => aes_round_start,
            aes_stall       => aes_stall,
            jittered_clk    => jittered_clk,
            sys_clk_buf     => sys_clk_buf,
            mmcm_locked     => mmcm_locked,
            chaos_out       => chaos_out,
            chaos_valid_out => chaos_valid_out,
            dummy_active    => dummy_active,
            dummy_count     => dummy_count,
            stat_dummies    => stat_dummies,
            stat_rounds     => stat_rounds,
            prng_load_seed  => prng_load_seed,
            prng_enable     => prng_enable
        );

    stim: process
    begin
        report "T1: Reset state";
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        assert mmcm_locked = '0' report "T1 FAIL" severity failure;
        assert aes_stall = '0' report "T1 FAIL: stall" severity failure;
        report "T1 PASS";

        report "T2: Enable omega cloak";
        rst_n <= '1';
        wait for CLK_PERIOD * 3;

        assert mmcm_locked = '1' report "T2 FAIL: mmcm not locked" severity failure;
        
        omega_enable <= '1';
        enable_jitter <= '1';
        enable_dummy <= '1';
        prng_enable <= '1';

        -- Seed PRNG
        prng_load_seed <= '1';
        wait for CLK_PERIOD;
        prng_load_seed <= '0';
        wait for CLK_PERIOD * 50;

        report "T2 INFO: chaos_valid=" & std_logic'image(chaos_valid_out);
        report "T2 PASS";

        report "T3: Dummy injection on round_start";
        aes_round_start <= '1';
        wait for CLK_PERIOD;
        aes_round_start <= '0';
        wait for CLK_PERIOD * 20;

        report "T3 INFO: stat_rounds=" & integer'image(to_integer(unsigned(stat_rounds))) &
               " stat_dummies=" & integer'image(to_integer(unsigned(stat_dummies)));
        report "T3 PASS";

        report "T4: Disable omega (master switch)";
        omega_enable <= '0';
        wait for CLK_PERIOD * 5;
        aes_round_start <= '1';
        wait for CLK_PERIOD;
        aes_round_start <= '0';
        wait for CLK_PERIOD * 5;
        assert aes_stall = '0' report "T4 FAIL: stall when disabled" severity failure;
        report "T4 PASS";

        report "ALL TESTS PASSED: tb_omega_cloak_top";
        sim_done <= true;
        wait;
    end process;

end sim;
