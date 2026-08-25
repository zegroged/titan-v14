--------------------------------------------------------------------------------
-- MINIMAL AES-256 DEBUG TESTBENCH (V2 — Table Recomputation)
-- Tests aes_round DIRECTLY with zero mask to isolate the bug
-- If this passes: bug is in aes256_core FSM/masking
-- If this fails: bug is in aes_round itself
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_aes_debug is
end tb_aes_debug;

architecture test of tb_aes_debug is

    constant CLK_P : time := 20 ns;
    signal clk : std_logic := '0';

    -- Round function signals (V2 interface)
    signal rf_state_in    : std_logic_vector(127 downto 0);
    signal rf_rk          : std_logic_vector(127 downto 0);
    signal rf_last        : std_logic := '0';
    signal rf_start       : std_logic := '0';
    signal rf_mask_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal rf_recomp_start: std_logic := '0';
    signal rf_recomp_done : std_logic;
    signal rf_mask_out    : std_logic_vector(127 downto 0);
    signal rf_state_out   : std_logic_vector(127 downto 0);
    signal rf_done        : std_logic;

    -- FIPS-197 C.3 AES-256 test vector
    -- Key = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
    -- PT  = 00112233445566778899aabbccddeeff
    -- After AddRoundKey(0): state = 00102030405060708090a0b0c0d0e0f0

    -- Expected round 1 output (FIPS-197 C.3 Appendix):
    -- After SubBytes : 63cab7040953d051cd60e0e7ba70e18c
    -- After ShiftRows: 6353e08c0960e104cd70b751bacad0e7
    -- After MixCol   : 5f72641557f5bc92f7be3b291db9f91a
    -- After AddRK(1) : 4f63760643e0aa85aff8c9d041fa0de4

    -- Round key 1 (NIST): A573C29FA176C498A97FCE93A572C09C  (128-bit)

    signal done_sim : boolean := false;

begin

    clk <= not clk after CLK_P/2 when not done_sim else '0';

    dut : entity work.aes_round
        port map (
            clk           => clk,
            state_in      => rf_state_in,
            round_key     => rf_rk,
            is_last_round => rf_last,
            start         => rf_start,
            -- V2 interface
            mask_byte     => rf_mask_byte,
            recomp_start  => rf_recomp_start,
            recomp_done   => rf_recomp_done,
            mask_out      => rf_mask_out,
            state_out     => rf_state_out,
            done          => rf_done
        );

    process
    begin
        report "=== MINIMAL AES ROUND DEBUG (V2 — Table Recomp) ===" severity note;

        wait for CLK_P * 5;

        -- ★ V2: First, trigger table recomputation with mask=0
        rf_mask_byte <= x"00";
        rf_recomp_start <= '1';
        wait for CLK_P;
        rf_recomp_start <= '0';

        -- Wait for recomp to complete (~258 cycles)
        for i in 1 to 300 loop
            wait for CLK_P;
            if rf_recomp_done = '1' then
                report "Table recomputation done in " & integer'image(i) & " cycles" severity note;
                exit;
            end if;
        end loop;

        assert rf_recomp_done = '1' report "Table recomputation TIMEOUT!" severity failure;

        wait for CLK_P * 2;

        -- Test 1: Single round with zero mask
        rf_state_in <= x"00102030405060708090a0b0c0d0e0f0";
        rf_rk       <= x"A573C29FA176C498A97FCE93A572C09C";
        rf_last     <= '0';

        rf_start <= '1';
        wait for CLK_P;
        rf_start <= '0';

        -- Wait for done
        for i in 1 to 10 loop
            wait for CLK_P;
            if rf_done = '1' then
                exit;
            end if;
        end loop;

        report "Round output: " & to_hstring(rf_state_out) severity note;
        report "Mask output:  " & to_hstring(rf_mask_out) severity note;

        -- Remove mask from output to get actual round result
        report "Unmasked:     " & to_hstring(rf_state_out xor rf_mask_out) severity note;

        -- Expected (FIPS-197 C.3 round 1 output):
        report "Expected:     4F63760643E0AA85AFF8C9D041FA0DE4" severity note;

        if (rf_state_out xor rf_mask_out) = x"4F63760643E0AA85AFF8C9D041FA0DE4" then
            report "ROUND 1: PASS" severity note;
        else
            report "ROUND 1: FAIL" severity error;
            report "XOR diff: " & to_hstring((rf_state_out xor rf_mask_out) xor x"4F63760643E0AA85AFF8C9D041FA0DE4") severity error;
        end if;

        wait for CLK_P * 5;
        done_sim <= true;
        wait;
    end process;

end test;
