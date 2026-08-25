--------------------------------------------------------------------------------
-- AEGIS PHASE 2.1: Testbench for shift_add_multiplier
--------------------------------------------------------------------------------
-- Self-checking testbench that reads test vectors from a CSV file
-- and verifies the multiplier output against golden reference values.
--
-- Test methodology:
--   1. Read (a, b, expected, overflow) from test_vectors_mul.csv
--   2. Drive a_in, b_in, assert start
--   3. Wait for done=1
--   4. Compare result and overflow against expected
--   5. Report pass/fail count
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_shift_add_multiplier is
end entity tb_shift_add_multiplier;

architecture sim of tb_shift_add_multiplier is

    constant CLK_PERIOD : time := 10 ns;  -- 100 MHz
    constant WIDTH      : integer := 16;

    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';
    signal start    : std_logic := '0';
    signal a_in     : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
    signal b_in     : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
    signal result   : std_logic_vector(WIDTH - 1 downto 0);
    signal done     : std_logic;
    signal overflow : std_logic;

    signal running  : boolean := true;

    -- Helper: convert hex character to 4-bit value
    function hex_char_to_slv(c : character) return std_logic_vector is
        variable result : std_logic_vector(3 downto 0);
    begin
        case c is
            when '0'       => result := "0000";
            when '1'       => result := "0001";
            when '2'       => result := "0010";
            when '3'       => result := "0011";
            when '4'       => result := "0100";
            when '5'       => result := "0101";
            when '6'       => result := "0110";
            when '7'       => result := "0111";
            when '8'       => result := "1000";
            when '9'       => result := "1001";
            when 'A' | 'a' => result := "1010";
            when 'B' | 'b' => result := "1011";
            when 'C' | 'c' => result := "1100";
            when 'D' | 'd' => result := "1101";
            when 'E' | 'e' => result := "1110";
            when 'F' | 'f' => result := "1111";
            when others    => result := "0000";
        end case;
        return result;
    end function;

    -- Helper: convert 4-char hex string to 16-bit SLV
    function hex4_to_slv16(s : string) return std_logic_vector is
        variable result : std_logic_vector(15 downto 0);
    begin
        result(15 downto 12) := hex_char_to_slv(s(1));
        result(11 downto  8) := hex_char_to_slv(s(2));
        result( 7 downto  4) := hex_char_to_slv(s(3));
        result( 3 downto  0) := hex_char_to_slv(s(4));
        return result;
    end function;

    -- Helper: SLV to hex string for reporting
    function slv_to_hex(v : std_logic_vector(15 downto 0)) return string is
        variable result : string(1 to 4);
        variable nibble : integer;
        constant HEX_CHARS : string := "0123456789ABCDEF";
    begin
        for i in 0 to 3 loop
            nibble := to_integer(unsigned(v(15 - 4*i downto 12 - 4*i)));
            result(i + 1) := HEX_CHARS(nibble + 1);
        end loop;
        return result;
    end function;

begin

    -- Clock generation
    clk_gen : process
    begin
        while running loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- DUT instantiation
    dut : entity work.shift_add_multiplier
        generic map (
            INT_BITS  => 8,
            FRAC_BITS => 8
        )
        port map (
            clk      => clk,
            rst_n    => rst_n,
            start    => start,
            a_in     => a_in,
            b_in     => b_in,
            result   => result,
            done     => done,
            overflow => overflow
        );

    -- Main stimulus process
    stim : process
        file     vec_file    : text;
        variable line_buf    : line;
        variable v_a_hex     : string(1 to 4);
        variable v_b_hex     : string(1 to 4);
        variable v_exp_hex   : string(1 to 4);
        variable v_ovf_char  : character;
        variable v_comma     : character;
        variable v_a_slv     : std_logic_vector(15 downto 0);
        variable v_b_slv     : std_logic_vector(15 downto 0);
        variable v_exp_slv   : std_logic_vector(15 downto 0);
        variable v_exp_ovf   : std_logic;
        variable test_num    : integer := 0;
        variable pass_count  : integer := 0;
        variable fail_count  : integer := 0;
        variable cycle_count : integer := 0;
    begin
        -- Reset
        rst_n <= '0';
        start <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD;

        -- Open test vectors file
        file_open(vec_file, "test_vectors_mul.csv", read_mode);

        -- Skip header line
        readline(vec_file, line_buf);

        -- Process each test vector
        while not endfile(vec_file) loop
            readline(vec_file, line_buf);

            -- Parse CSV: a_hex,b_hex,expected_hex,overflow
            read(line_buf, v_a_hex);
            read(line_buf, v_comma);  -- skip comma
            read(line_buf, v_b_hex);
            read(line_buf, v_comma);  -- skip comma
            read(line_buf, v_exp_hex);
            read(line_buf, v_comma);  -- skip comma
            read(line_buf, v_ovf_char);

            v_a_slv   := hex4_to_slv16(v_a_hex);
            v_b_slv   := hex4_to_slv16(v_b_hex);
            v_exp_slv := hex4_to_slv16(v_exp_hex);
            if v_ovf_char = '1' then
                v_exp_ovf := '1';
            else
                v_exp_ovf := '0';
            end if;

            test_num := test_num + 1;

            -- Drive inputs
            a_in  <= v_a_slv;
            b_in  <= v_b_slv;
            start <= '1';
            wait for CLK_PERIOD;
            start <= '0';

            -- Wait for done (max 20 cycles timeout)
            cycle_count := 0;
            while done /= '1' and cycle_count < 20 loop
                wait for CLK_PERIOD;
                cycle_count := cycle_count + 1;
            end loop;

            -- Check timeout
            if cycle_count >= 20 then
                report "TIMEOUT on test " & integer'image(test_num) &
                       " a=0x" & slv_to_hex(v_a_slv) &
                       " b=0x" & slv_to_hex(v_b_slv)
                    severity error;
                fail_count := fail_count + 1;
            else
                -- Verify result
                if result = v_exp_slv and overflow = v_exp_ovf then
                    pass_count := pass_count + 1;
                else
                    fail_count := fail_count + 1;
                    report "FAIL test " & integer'image(test_num) &
                           ": a=0x" & slv_to_hex(v_a_slv) &
                           " b=0x" & slv_to_hex(v_b_slv) &
                           " expected=0x" & slv_to_hex(v_exp_slv) &
                           " got=0x" & slv_to_hex(result) &
                           " exp_ovf=" & std_logic'image(v_exp_ovf) &
                           " got_ovf=" & std_logic'image(overflow)
                        severity error;
                end if;
            end if;

            -- Small gap between tests
            wait for CLK_PERIOD;
        end loop;

        file_close(vec_file);

        -- Report summary
        report "========================================"
            severity note;
        report " TEST SUMMARY: " & integer'image(test_num) & " tests"
            severity note;
        report "   PASS: " & integer'image(pass_count)
            severity note;
        report "   FAIL: " & integer'image(fail_count)
            severity note;
        report "========================================"
            severity note;

        if fail_count = 0 then
            report "ALL TESTS PASSED!" severity note;
        else
            report "SOME TESTS FAILED!" severity error;
        end if;

        running <= false;
        wait;
    end process;

end architecture sim;
