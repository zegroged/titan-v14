--------------------------------------------------------------------------------
-- AEGIS Phase 2.2: Testbench for tanh_lut_rom
--------------------------------------------------------------------------------
-- Verifies tanh LUT ROM against known mathematical values.
-- Tests saturation boundaries, zero, and intermediate values.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_tanh_lut_rom is
end entity tb_tanh_lut_rom;

architecture sim of tb_tanh_lut_rom is

    constant CLK_PERIOD : time := 10 ns;

    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';
    signal x_in  : std_logic_vector(15 downto 0) := (others => '0');
    signal y_out : std_logic_vector(15 downto 0);

    signal running : boolean := true;

    -- Helper: convert hex character to 4 bits
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

    function hex4_to_slv16(s : string) return std_logic_vector is
        variable result : std_logic_vector(15 downto 0);
    begin
        result(15 downto 12) := hex_char_to_slv(s(1));
        result(11 downto  8) := hex_char_to_slv(s(2));
        result( 7 downto  4) := hex_char_to_slv(s(3));
        result( 3 downto  0) := hex_char_to_slv(s(4));
        return result;
    end function;

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

    clk_gen : process
    begin
        while running loop
            clk <= '0'; wait for CLK_PERIOD / 2;
            clk <= '1'; wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    dut : entity work.tanh_lut_rom
        port map (
            clk   => clk,
            rst_n => rst_n,
            x_in  => x_in,
            y_out => y_out
        );

    stim : process
        file     vec_file   : text;
        variable line_buf   : line;
        variable v_x_hex    : string(1 to 4);
        variable v_y_hex    : string(1 to 4);
        variable v_comma    : character;
        variable v_desc     : line;
        variable v_x_slv    : std_logic_vector(15 downto 0);
        variable v_y_slv    : std_logic_vector(15 downto 0);
        variable test_num   : integer := 0;
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD;

        -- Open test vectors
        file_open(vec_file, "test_vectors_tanh.csv", read_mode);

        -- Skip header
        readline(vec_file, line_buf);

        while not endfile(vec_file) loop
            readline(vec_file, line_buf);

            -- Parse: x_hex,expected_hex,description
            read(line_buf, v_x_hex);
            read(line_buf, v_comma);
            read(line_buf, v_y_hex);
            -- skip description

            v_x_slv := hex4_to_slv16(v_x_hex);
            v_y_slv := hex4_to_slv16(v_y_hex);

            test_num := test_num + 1;

            -- Drive input
            x_in <= v_x_slv;
            -- Wait 1 clock for registered output
            wait for CLK_PERIOD;
            -- Sample after next rising edge
            wait for CLK_PERIOD;

            -- Compare
            if y_out = v_y_slv then
                pass_count := pass_count + 1;
            else
                fail_count := fail_count + 1;
                report "FAIL test " & integer'image(test_num) &
                       ": x=0x" & slv_to_hex(v_x_slv) &
                       " expected=0x" & slv_to_hex(v_y_slv) &
                       " got=0x" & slv_to_hex(y_out)
                    severity error;
            end if;
        end loop;

        file_close(vec_file);

        -- Summary
        report "========================================" severity note;
        report " TANH LUT TEST: " & integer'image(test_num) & " tests" severity note;
        report "   PASS: " & integer'image(pass_count) severity note;
        report "   FAIL: " & integer'image(fail_count) severity note;
        report "========================================" severity note;

        if fail_count = 0 then
            report "ALL TESTS PASSED!" severity note;
        else
            report "SOME TESTS FAILED!" severity error;
        end if;

        running <= false;
        wait;
    end process;

end architecture sim;
