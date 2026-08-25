--------------------------------------------------------------------------------
-- PROJECT TITAN V14: CPA Attack Simulation -- Power Trace Capture
-- Hamming Weight power model for AES-256 first round S-Box output
--------------------------------------------------------------------------------
-- Encrypts 256 plaintexts varying byte 0 (0x00..0xFF).
-- Records plaintext byte, ciphertext, and ciphertext HW to CSV.
-- Python script performs the CPA correlation attack offline.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_aes_power_trace is
end tb_aes_power_trace;

architecture Behavioral of tb_aes_power_trace is

    constant CLK_PERIOD   : time := 20 ns;
    constant NUM_TRACES   : integer := 256;
    constant MAX_CYCLES   : integer := 500;

    signal clk            : std_logic := '0';
    signal rst_n          : std_logic := '0';
    signal kill_signal    : std_logic := '0';
    signal key_in         : std_logic_vector(255 downto 0) := (others => '0');
    signal key_load       : std_logic := '0';
    signal plaintext      : std_logic_vector(127 downto 0) := (others => '0');
    signal start          : std_logic := '0';
    signal ciphertext     : std_logic_vector(127 downto 0);
    signal done_sig       : std_logic;
    signal busy           : std_logic;
    signal trng_mask      : std_logic_vector(127 downto 0) := (others => '0');
    signal fault_detected : std_logic;

    signal done_flag      : boolean := false;

    -- Fixed key (known to attacker in simulation)
    constant ATTACK_KEY : std_logic_vector(255 downto 0) :=
        x"2b7e151628aed2a6abf7158809cf4f3c" &
        x"762e7160f38b4da56a784d9045190cfe";

    -- Hamming Weight
    function hamming_weight(v : std_logic_vector) return integer is
        variable hw : integer := 0;
    begin
        for i in v'range loop
            if v(i) = '1' then
                hw := hw + 1;
            end if;
        end loop;
        return hw;
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2 when not done_flag else '0';

    dut : entity work.aes256_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => kill_signal,
            key_in         => key_in,
            key_load       => key_load,
            plaintext      => plaintext,
            start          => start,
            ciphertext     => ciphertext,
            done           => done_sig,
            busy           => busy,
            trng_mask      => trng_mask,
            fault_detected => fault_detected
        );

    process
        file     outfile : text open write_mode is "power_traces.csv";
        variable outline : line;
        variable ct_hw   : integer;
        variable ct_hex  : string(1 to 32);
        variable nibble  : integer;
        constant HEX_CHARS : string := "0123456789abcdef";
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- Load key
        key_in   <= ATTACK_KEY;
        key_load <= '1';
        wait for CLK_PERIOD;
        key_load <= '0';
        wait for CLK_PERIOD * 2;

        -- Header
        write(outline, string'("pt_byte,ct_hex,ct_byte0_hw,full_ct_hw"));
        writeline(outfile, outline);

        report "[INFO] CPA trace capture: " &
               integer'image(NUM_TRACES) & " encryptions" severity note;

        for trace_idx in 0 to NUM_TRACES - 1 loop
            -- PT: byte 0 = trace_idx, rest fixed
            plaintext <= (others => '0');
            plaintext(127 downto 120) <= std_logic_vector(to_unsigned(trace_idx, 8));

            -- Vary mask per trace (simple, avoids GHDL integer overflow)
            trng_mask(127 downto 120) <= std_logic_vector(to_unsigned(trace_idx, 8));
            trng_mask(119 downto 112) <= std_logic_vector(to_unsigned((trace_idx * 7 + 13) mod 256, 8));
            trng_mask(111 downto 104) <= std_logic_vector(to_unsigned((trace_idx * 31 + 97) mod 256, 8));
            trng_mask(103 downto 0)   <= std_logic_vector(to_unsigned(trace_idx * 257 + 1, 104));

            start <= '1';
            wait for CLK_PERIOD;
            start <= '0';

            for i in 0 to MAX_CYCLES loop
                wait for CLK_PERIOD;
                exit when done_sig = '1';
            end loop;

            -- Compute HW
            ct_hw := hamming_weight(ciphertext(127 downto 120));

            -- Convert ciphertext to hex string
            for j in 0 to 31 loop
                nibble := to_integer(unsigned(
                    ciphertext(127 - j*4 downto 124 - j*4)));
                ct_hex(j+1) := HEX_CHARS(nibble + 1);
            end loop;

            -- Write CSV
            write(outline, integer'image(trace_idx));
            write(outline, string'(","));
            write(outline, ct_hex);
            write(outline, string'(","));
            write(outline, integer'image(ct_hw));
            write(outline, string'(","));
            write(outline, integer'image(hamming_weight(ciphertext)));
            writeline(outfile, outline);

            if (trace_idx + 1) mod 64 = 0 then
                report "[PROGRESS] " & integer'image(trace_idx + 1) & "/" &
                       integer'image(NUM_TRACES) severity note;
            end if;

            wait for CLK_PERIOD * 2;
        end loop;

        report "======================================" severity note;
        report "  CPA TRACE CAPTURE COMPLETE" severity note;
        report "  Traces: " & integer'image(NUM_TRACES) severity note;
        report "  Output: power_traces.csv" severity note;
        report "======================================" severity note;

        done_flag <= true;
        wait;
    end process;

end Behavioral;
