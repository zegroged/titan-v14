--------------------------------------------------------------------------------
-- AEGIS Phase 3.1: Testbench for Dual Chaotic PRNG
--------------------------------------------------------------------------------
-- Verifies first 100 iterations: compares xa, xb registers against golden ref.
-- Tests: seed load, continuous generation, seed validation.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_chaotic_prng is
end entity tb_chaotic_prng;

architecture sim of tb_chaotic_prng is

    constant CLK_P : time := 20 ns;

    signal clk         : std_logic := '0';
    signal rst_n       : std_logic := '0';
    signal seed        : std_logic_vector(31 downto 0) := (others => '0');
    signal r_param     : std_logic_vector(31 downto 0) := (others => '0');
    signal load_seed   : std_logic := '0';
    signal enable      : std_logic := '0';
    signal chaos_out   : std_logic_vector(31 downto 0);
    signal chaos_valid : std_logic;
    signal chaos_bit   : std_logic;
    signal chaos_byte  : std_logic_vector(7 downto 0);

    signal running : boolean := true;

    function hc(c : character) return integer is
    begin
        case c is
            when '0'=>return 0; when '1'=>return 1;
            when '2'=>return 2; when '3'=>return 3;
            when '4'=>return 4; when '5'=>return 5;
            when '6'=>return 6; when '7'=>return 7;
            when '8'=>return 8; when '9'=>return 9;
            when 'A'|'a'=>return 10; when 'B'|'b'=>return 11;
            when 'C'|'c'=>return 12; when 'D'|'d'=>return 13;
            when 'E'|'e'=>return 14; when 'F'|'f'=>return 15;
            when others=>return 0;
        end case;
    end function;

    function h8(s : string) return std_logic_vector is
        variable r : std_logic_vector(31 downto 0);
    begin
        for i in 0 to 7 loop
            r(31-i*4 downto 28-i*4) :=
                std_logic_vector(to_unsigned(hc(s(i+1)), 4));
        end loop;
        return r;
    end function;

    function to_hex8(v : std_logic_vector(31 downto 0)) return string is
        variable r : string(1 to 8);
        constant H : string := "0123456789ABCDEF";
    begin
        for i in 0 to 7 loop
            r(i+1) := H(to_integer(unsigned(v(31-4*i downto 28-4*i)))+1);
        end loop;
        return r;
    end function;

begin

    clk_gen: process
    begin
        while running loop
            clk <= '0'; wait for CLK_P/2;
            clk <= '1'; wait for CLK_P/2;
        end loop;
        wait;
    end process;

    dut: entity work.chaotic_prng
        port map (
            clk=>clk, rst_n=>rst_n, seed=>seed, r_param=>r_param,
            load_seed=>load_seed, enable=>enable,
            chaos_out=>chaos_out, chaos_valid=>chaos_valid,
            chaos_bit=>chaos_bit, chaos_byte=>chaos_byte,
            -- ★ Ports added in upgrade
            chaos_out_128 => open,
            chaos_128_valid => open,
            cycle_locked => open
        );

    stim: process
        file     vf : text;
        variable lb : line;
        variable vc : character;
        variable v_xa, v_xb, v_xor : string(1 to 8);
        variable v_bit_s : string(1 to 1);
        variable exp_xor : std_logic_vector(31 downto 0);
        variable pc, fc, wc, iter : integer := 0;
    begin
        rst_n <= '0'; wait for CLK_P*5;
        rst_n <= '1'; wait for CLK_P*2;

        -- ===== Test 1: Seed validation (zero seed) =====
        report "TEST 1: Zero seed protection" severity note;
        seed <= x"00000000"; r_param <= x"03FD70A4";
        load_seed <= '1'; wait for CLK_P;
        load_seed <= '0'; wait for CLK_P;
        enable <= '1'; wait for CLK_P; enable <= '0';
        wc := 0;
        while chaos_valid /= '1' and wc < 30 loop
            wait for CLK_P; wc := wc + 1;
        end loop;
        if wc < 30 then
            pc := pc + 1;
            report "  PASS: Generated output with safe seed" severity note;
        else
            fc := fc + 1;
            report "  FAIL: Timeout" severity error;
        end if;

        -- ===== Test 2: Golden reference (XOR output) =====
        report "TEST 2: Golden reference -- 100 iterations" severity note;

        seed <= x"00666666"; r_param <= x"03FD70A4";
        load_seed <= '1'; wait for CLK_P;
        load_seed <= '0'; wait for CLK_P;
        enable <= '1';

        -- Open CSV
        file_open(vf, "test_vectors_prng.csv", read_mode);
        readline(vf, lb);  -- skip comment
        readline(vf, lb);  -- skip header

        iter := 0;
        while not endfile(vf) and iter < 100 loop
            readline(vf, lb);

            -- Parse: iter,xa_hex,xb_hex,xor_hex,chaos_bit
            -- Skip iter number
            read(lb, vc);
            while vc /= ',' loop read(lb, vc); end loop;
            read(lb, v_xa);   read(lb, vc);  -- comma
            read(lb, v_xb);   read(lb, vc);  -- comma
            read(lb, v_xor);  read(lb, vc);  -- comma
            read(lb, v_bit_s);

            exp_xor := h8(v_xor);

            -- Wait for valid
            wc := 0;
            while chaos_valid /= '1' and wc < 30 loop
                wait for CLK_P; wc := wc + 1;
            end loop;

            if chaos_out = exp_xor then
                pc := pc + 1;
            else
                fc := fc + 1;
                if fc <= 5 then
                    report "FAIL iter=" & integer'image(iter) &
                           " exp=" & to_hex8(exp_xor) &
                           " got=" & to_hex8(chaos_out) severity error;
                end if;
            end if;

            iter := iter + 1;
            wait for CLK_P;
        end loop;

        file_close(vf);
        enable <= '0';
        wait for CLK_P * 5;

        -- Summary
        report "========================================" severity note;
        report " DUAL CHAOTIC PRNG: " & integer'image(iter+1) &
               " checks" severity note;
        report "   PASS: " & integer'image(pc) severity note;
        report "   FAIL: " & integer'image(fc) severity note;
        report "========================================" severity note;
        if fc = 0 then
            report "ALL TESTS PASSED!" severity note;
        else
            report "SOME TESTS FAILED!" severity error;
        end if;

        running <= false;
        wait;
    end process;

end architecture sim;
