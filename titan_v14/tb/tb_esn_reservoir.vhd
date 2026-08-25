--------------------------------------------------------------------------------
-- AEGIS Phase 2.3: Testbench for ESN Reservoir Core
--------------------------------------------------------------------------------
-- Feeds 5 known inputs and verifies state outputs against golden reference.
-- Test vectors from generate_esn_weights.py (CSV file).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

use work.esn_weight_pkg.all;

entity tb_esn_reservoir is
end entity tb_esn_reservoir;

architecture sim of tb_esn_reservoir is

    constant CLK_PERIOD : time := 20 ns;  -- 50 MHz

    signal clk         : std_logic := '0';
    signal rst_n       : std_logic := '0';
    signal sensor_in   : std_logic_vector(15 downto 0) := (others => '0');
    signal valid_in    : std_logic := '0';
    signal state_out   : std_logic_vector(ESN_N * 16 - 1 downto 0);
    signal state_valid : std_logic;

    signal running : boolean := true;

    function hex_char_to_slv(c : character) return std_logic_vector is
        variable r : std_logic_vector(3 downto 0);
    begin
        case c is
            when '0' => r := "0000"; when '1' => r := "0001";
            when '2' => r := "0010"; when '3' => r := "0011";
            when '4' => r := "0100"; when '5' => r := "0101";
            when '6' => r := "0110"; when '7' => r := "0111";
            when '8' => r := "1000"; when '9' => r := "1001";
            when 'A'|'a' => r := "1010"; when 'B'|'b' => r := "1011";
            when 'C'|'c' => r := "1100"; when 'D'|'d' => r := "1101";
            when 'E'|'e' => r := "1110"; when 'F'|'f' => r := "1111";
            when others => r := "0000";
        end case;
        return r;
    end function;

    function hex4_to_slv16(s : string) return std_logic_vector is
    begin
        return hex_char_to_slv(s(1)) & hex_char_to_slv(s(2)) &
               hex_char_to_slv(s(3)) & hex_char_to_slv(s(4));
    end function;

    function slv_to_hex(v : std_logic_vector(15 downto 0)) return string is
        variable r : string(1 to 4);
        variable n : integer;
        constant H : string := "0123456789ABCDEF";
    begin
        for i in 0 to 3 loop
            n := to_integer(unsigned(v(15-4*i downto 12-4*i)));
            r(i+1) := H(n+1);
        end loop;
        return r;
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

    dut : entity work.esn_reservoir_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            sensor_data_in => sensor_in,
            valid_in       => valid_in,
            state_out      => state_out,
            state_valid    => state_valid
        );

    stim : process
        file     vec_file    : text;
        variable line_buf    : line;
        variable v_char      : character;
        variable v_inp_hex   : string(1 to 4);
        variable v_s_hex     : string(1 to 4);
        variable v_comma     : character;
        variable v_inp_slv   : std_logic_vector(15 downto 0);
        variable exp_states  : std_logic_vector(ESN_N*16-1 downto 0);
        variable got_state_i : std_logic_vector(15 downto 0);
        variable exp_state_i : std_logic_vector(15 downto 0);
        variable step_num    : integer := 0;
        variable pass_count  : integer := 0;
        variable fail_count  : integer := 0;
        variable neuron_ok   : boolean;
        variable all_ok      : boolean;
        variable wait_count  : integer;
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- Open golden reference
        file_open(vec_file, "test_vectors_esn.csv", read_mode);
        readline(vec_file, line_buf);  -- skip header

        while not endfile(vec_file) loop
            readline(vec_file, line_buf);

            -- Parse: step,input_hex,s0,s1,...,sN-1
            -- Skip step number (variable-length: "0", "10", "19", etc.)
            v_char := ' ';
            while v_char /= ',' loop
                read(line_buf, v_char);
            end loop;
            read(line_buf, v_inp_hex);
            v_inp_slv := hex4_to_slv16(v_inp_hex);

            -- Read expected states
            for i in 0 to ESN_N - 1 loop
                read(line_buf, v_comma);
                read(line_buf, v_s_hex);
                exp_states((i+1)*16-1 downto i*16) := hex4_to_slv16(v_s_hex);
            end loop;

            step_num := step_num + 1;

            -- Apply input
            sensor_in <= v_inp_slv;
            valid_in  <= '1';
            wait for CLK_PERIOD;
            valid_in  <= '0';

            -- Wait for state_valid (timeout 200 cycles)
            wait_count := 0;
            while state_valid /= '1' and wait_count < 200 loop
                wait for CLK_PERIOD;
                wait_count := wait_count + 1;
            end loop;

            if wait_count >= 200 then
                report "TIMEOUT step " & integer'image(step_num) severity error;
                fail_count := fail_count + 1;
            else
                -- Compare all neuron states
                all_ok := true;
                for i in 0 to ESN_N - 1 loop
                    got_state_i := state_out((i+1)*16-1 downto i*16);
                    exp_state_i := exp_states((i+1)*16-1 downto i*16);
                    if got_state_i /= exp_state_i then
                        report "FAIL step=" & integer'image(step_num) &
                               " neuron=" & integer'image(i) &
                               " exp=0x" & slv_to_hex(exp_state_i) &
                               " got=0x" & slv_to_hex(got_state_i)
                            severity error;
                        all_ok := false;
                    end if;
                end loop;

                if all_ok then
                    pass_count := pass_count + 1;
                    report "PASS step " & integer'image(step_num) &
                           " (" & integer'image(wait_count) & " cycles)"
                        severity note;
                else
                    fail_count := fail_count + 1;
                end if;
            end if;

            wait for CLK_PERIOD * 2;
        end loop;

        file_close(vec_file);

        report "========================================" severity note;
        report " ESN RESERVOIR TEST: " & integer'image(step_num) & " steps"
            severity note;
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
