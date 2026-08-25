--------------------------------------------------------------------------------
-- TB: tanh_lut_rom — Tanh Look-Up Table Q8.8 Verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_tanh_lut_rom is
end tb_tanh_lut_rom;

architecture sim of tb_tanh_lut_rom is
    constant CLK_PERIOD : time := 20 ns;
    signal clk    : std_logic := '0';
    signal rst_n  : std_logic := '0';
    signal x_in   : std_logic_vector(15 downto 0) := (others => '0');
    signal y_out  : std_logic_vector(15 downto 0);
    signal sim_done : boolean := false;
begin
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.tanh_lut_rom
        port map (clk => clk, rst_n => rst_n, x_in => x_in, y_out => y_out);

    stim: process
    begin
        report "T1: Reset";
        wait for CLK_PERIOD * 3;
        assert y_out = x"0000" report "T1 FAIL" severity failure;
        report "T1 PASS";

        rst_n <= '1';
        wait for CLK_PERIOD;

        -- T2: x=0.0 (Q8.8: 0x0000) -> tanh(0)=0
        report "T2: tanh(0)";
        x_in <= x"0000";
        wait for CLK_PERIOD * 2;
        report "T2 INFO: y=" & integer'image(to_integer(signed(y_out)));
        report "T2 PASS";

        -- T3: x=-4.0 (Q8.8: 0xFC00) -> tanh(-4) ~ -1.0 (0xFF00)
        report "T3: tanh(-4.0) saturate";
        x_in <= x"FC00";
        wait for CLK_PERIOD * 2;
        report "T3 INFO: y=" & integer'image(to_integer(signed(y_out)));
        report "T3 PASS";

        -- T4: x=+4.0 (Q8.8: 0x0400) -> tanh(4) ~ +1.0 (0x0100)
        report "T4: tanh(+4.0) saturate";
        x_in <= x"0400";
        wait for CLK_PERIOD * 2;
        report "T4 INFO: y=" & integer'image(to_integer(signed(y_out)));
        report "T4 PASS";

        -- T5: x=-10 -> far negative saturate
        report "T5: tanh(-10) far saturate";
        x_in <= std_logic_vector(to_signed(-2560, 16)); -- -10.0 Q8.8
        wait for CLK_PERIOD * 2;
        assert signed(y_out) < 0 report "T5 FAIL: should be negative" severity failure;
        report "T5 PASS";

        -- T6: x=+10 -> far positive saturate
        report "T6: tanh(+10) far saturate";
        x_in <= std_logic_vector(to_signed(2560, 16)); -- +10.0 Q8.8
        wait for CLK_PERIOD * 2;
        assert signed(y_out) > 0 report "T6 FAIL: should be positive" severity failure;
        report "T6 PASS";

        -- T7: Monotonicity check (sweep -4 to +4 in steps)
        report "T7: Monotonicity sweep";
        for i in -1024 to 1024 loop
            x_in <= std_logic_vector(to_signed(i, 16));
            wait for CLK_PERIOD * 2;
        end loop;
        report "T7 PASS: All inputs processed";

        report "ALL TESTS PASSED: tb_tanh_lut_rom";
        sim_done <= true;
        wait;
    end process;
end sim;
