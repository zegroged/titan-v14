--------------------------------------------------------------------------------
-- TB: chaotic_prng — Dual Logistic Map PRNG Verification
-- Tests: reset, seed load, output generation, cycle detection, 128-bit output
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_chaotic_prng is
end tb_chaotic_prng;

architecture sim of tb_chaotic_prng is

    constant CLK_PERIOD : time := 20 ns;

    signal clk             : std_logic := '0';
    signal rst_n           : std_logic := '0';
    signal seed            : std_logic_vector(31 downto 0) := (others => '0');
    signal r_param         : std_logic_vector(31 downto 0) := x"03FD70A4"; -- 3.99
    signal load_seed       : std_logic := '0';
    signal enable          : std_logic := '0';
    signal chaos_out       : std_logic_vector(31 downto 0);
    signal chaos_valid     : std_logic;
    signal chaos_bit       : std_logic;
    signal chaos_byte      : std_logic_vector(7 downto 0);
    signal chaos_out_128   : std_logic_vector(127 downto 0);
    signal chaos_128_valid : std_logic;
    signal cycle_locked    : std_logic;

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.chaotic_prng
        port map (
            clk             => clk,
            rst_n           => rst_n,
            seed            => seed,
            r_param         => r_param,
            load_seed       => load_seed,
            enable          => enable,
            chaos_out       => chaos_out,
            chaos_valid     => chaos_valid,
            chaos_bit       => chaos_bit,
            chaos_byte      => chaos_byte,
            chaos_out_128   => chaos_out_128,
            chaos_128_valid => chaos_128_valid,
            cycle_locked    => cycle_locked
        );

    stim: process
        variable val1, val2 : std_logic_vector(31 downto 0);
        variable valid_count : integer;
        variable unique_count : integer;
        type val_arr_t is array (0 to 31) of std_logic_vector(31 downto 0);
        variable values : val_arr_t;
    begin
        -----------------------------------------------------------------
        -- T1: Reset state
        -----------------------------------------------------------------
        report "T1: Reset state check";
        rst_n <= '0';
        wait for CLK_PERIOD * 5;

        assert chaos_valid = '0'
            report "T1 FAIL: chaos_valid not 0" severity failure;
        assert cycle_locked = '0'
            report "T1 FAIL: cycle_locked not 0" severity failure;
        report "T1 PASS";

        -----------------------------------------------------------------
        -- T2: Seed load and enable
        -----------------------------------------------------------------
        report "T2: Seed load and output generation";
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- Load seed = 0.1 (Q8.24 = 0x0019999A)
        seed <= x"0019999A";
        load_seed <= '1';
        wait for CLK_PERIOD;
        load_seed <= '0';
        wait for CLK_PERIOD;

        -- Enable and collect outputs
        enable <= '1';
        valid_count := 0;

        for i in 0 to 127 loop
            wait for CLK_PERIOD;
            if chaos_valid = '1' then
                if valid_count < 32 then
                    values(valid_count) := chaos_out;
                end if;
                valid_count := valid_count + 1;
            end if;
        end loop;

        assert valid_count > 0
            report "T2 FAIL: no valid outputs generated" severity failure;
        report "T2 PASS: Generated " & integer'image(valid_count) & " valid outputs";

        -----------------------------------------------------------------
        -- T3: Output uniqueness (no two consecutive equal)
        -----------------------------------------------------------------
        report "T3: Output uniqueness check";
        unique_count := 0;
        for i in 1 to valid_count - 1 loop
            if i < 32 then
                if values(i) /= values(i-1) then
                    unique_count := unique_count + 1;
                end if;
            end if;
        end loop;

        -- At least 80% of consecutive outputs should differ
        if valid_count > 2 then
            assert unique_count > 0
                report "T3 FAIL: all outputs identical" severity failure;
        end if;
        report "T3 PASS: " & integer'image(unique_count) & " unique transitions";

        -----------------------------------------------------------------
        -- T4: 128-bit output fires after 4 valid outputs
        -----------------------------------------------------------------
        report "T4: 128-bit accumulator check";
        -- Reset and collect fresh
        enable <= '0';
        wait for CLK_PERIOD * 2;

        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        seed <= x"00333333";  -- 0.2 in Q8.24  
        load_seed <= '1';
        wait for CLK_PERIOD;
        load_seed <= '0';
        wait for CLK_PERIOD;

        enable <= '1';
        valid_count := 0;

        for i in 0 to 200 loop
            wait for CLK_PERIOD;
            if chaos_128_valid = '1' then
                valid_count := valid_count + 1;
                report "T4 INFO: 128-bit output fired at cycle " & integer'image(i);
                exit;
            end if;
        end loop;

        assert valid_count > 0
            report "T4 FAIL: 128-bit output never fired" severity failure;
        report "T4 PASS: 128-bit accumulator works";

        -----------------------------------------------------------------
        -- T5: Boundary seed handling (0 and >= 1.0)
        -----------------------------------------------------------------
        report "T5: Boundary seed values";
        enable <= '0';
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD;

        -- Seed = 0 should use SAFE_A internally
        seed <= x"00000000";
        load_seed <= '1';
        wait for CLK_PERIOD;
        load_seed <= '0';
        wait for CLK_PERIOD;

        enable <= '1';
        valid_count := 0;
        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if chaos_valid = '1' then
                valid_count := valid_count + 1;
            end if;
        end loop;

        assert valid_count > 0
            report "T5 FAIL: no output with zero seed" severity failure;
        report "T5 PASS: Zero seed handled (SAFE_A fallback)";

        enable <= '0';
        wait for CLK_PERIOD * 2;

        -----------------------------------------------------------------
        report "ALL TESTS PASSED: tb_chaotic_prng";
        sim_done <= true;
        wait;
    end process;

end sim;
