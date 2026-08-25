--------------------------------------------------------------------------------
-- TB: shift_add_multiplier — Q8.8 Fixed-Point Multiplier Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_shift_add_multiplier is
end tb_shift_add_multiplier;

architecture sim of tb_shift_add_multiplier is
    constant CLK_PERIOD : time := 20 ns;
    signal clk       : std_logic := '0';
    signal rst_n     : std_logic := '0';
    signal a_in      : std_logic_vector(15 downto 0) := (others => '0');
    signal b_in      : std_logic_vector(15 downto 0) := (others => '0');
    signal start     : std_logic := '0';
    signal result    : std_logic_vector(15 downto 0);
    signal done      : std_logic;
    signal overflow  : std_logic;
    signal sim_done  : boolean := false;
begin
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.shift_add_multiplier
        generic map (INT_BITS => 8, FRAC_BITS => 8)
        port map (
            clk => clk, rst_n => rst_n,
            a_in => a_in, b_in => b_in,
            start => start,
            result => result, done => done, overflow => overflow
        );

    stim: process
    begin
        report "T1: Reset";
        wait for CLK_PERIOD * 5;
        assert done = '0' report "T1 FAIL" severity failure;
        report "T1 PASS";

        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- T2: 0.5 * 0.5 = 0.25  (Q8.8: 0.5=0x0080, 0.25=0x0040)
        report "T2: 0.5 * 0.5 = 0.25";
        a_in <= x"0080";
        b_in <= x"0080";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if done = '1' then exit; end if;
        end loop;
        assert done = '1' report "T2 FAIL: not done" severity failure;
        assert result = x"0040"
            report "T2 FAIL: expected 0x0040 got 0x" &
                   integer'image(to_integer(unsigned(result))) severity failure;
        report "T2 PASS";

        -- T3: 1.0 * 1.0 = 1.0  (Q8.8: 1.0=0x0100)
        report "T3: 1.0 * 1.0";
        a_in <= x"0100";
        b_in <= x"0100";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if done = '1' then exit; end if;
        end loop;
        assert done = '1' report "T3 FAIL" severity failure;
        assert result = x"0100"
            report "T3 FAIL: expected 0x0100" severity failure;
        report "T3 PASS";

        -- T4: 0 * 1.0 = 0
        report "T4: 0 * 1.0";
        a_in <= x"0000";
        b_in <= x"0100";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if done = '1' then exit; end if;
        end loop;
        assert result = x"0000" report "T4 FAIL" severity failure;
        report "T4 PASS";

        -- T5: -1.0 * 1.0 = -1.0  (Q8.8: -1.0=0xFF00)
        report "T5: -1.0 * 1.0";
        a_in <= x"FF00";
        b_in <= x"0100";
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if done = '1' then exit; end if;
        end loop;
        assert result = x"FF00"
            report "T5 FAIL: expected 0xFF00" severity failure;
        report "T5 PASS";

        report "ALL TESTS PASSED: tb_shift_add_multiplier";
        sim_done <= true;
        wait;
    end process;
end sim;
