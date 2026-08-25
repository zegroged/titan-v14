--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES Masking Test (V2 — Table Recomputation)
-- ★ FIX: Now ASSERTS ciphertext correctness when mask ≠ 0
-- NIST FIPS-197 AES-256 KAT:
--   Key = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
--   PT  = 00112233445566778899aabbccddeeff
--   CT  = 8ea2b7ca516745bfeafc49904b496089
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_aes_mask_test is
end tb_aes_mask_test;

architecture Behavioral of tb_aes_mask_test is
    signal clk, rst_n      : std_logic := '0';
    signal kill_signal      : std_logic := '0';
    signal key_in           : std_logic_vector(255 downto 0) := (others => '0');
    signal key_load         : std_logic := '0';
    signal plaintext        : std_logic_vector(127 downto 0) := (others => '0');
    signal start            : std_logic := '0';
    signal ciphertext       : std_logic_vector(127 downto 0);
    signal done, busy       : std_logic;
    signal trng_mask        : std_logic_vector(127 downto 0) := (others => '0');
    signal fault_detected   : std_logic;
    signal sim_done         : boolean := false;
    constant CLK_PERIOD     : time := 10 ns;

    -- ★ NIST FIPS-197 expected ciphertext
    constant NIST_CT : std_logic_vector(127 downto 0) := x"8ea2b7ca516745bfeafc49904b496089";

    -- Test result tracking
    signal test1_pass : boolean := false;
    signal test2_pass : boolean := false;
    signal test3_pass : boolean := false;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    u_aes : entity work.aes256_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => kill_signal,
            key_in         => key_in,
            key_load       => key_load,
            plaintext      => plaintext,
            start          => start,
            ciphertext     => ciphertext,
            done           => done,
            busy           => busy,
            trng_mask      => trng_mask,
            fault_detected => fault_detected
        );

    process
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        -- =====================================================================
        -- Test 1: mask=0 (baseline KAT)
        -- =====================================================================
        report "=== TEST 1: mask=0 (BASELINE KAT) ===" severity note;
        trng_mask <= (others => '0');
        key_in <= x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        key_load <= '1';
        wait until rising_edge(clk);
        key_load <= '0';
        wait for CLK_PERIOD * 5;

        plaintext <= x"00112233445566778899aabbccddeeff";
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        for i in 1 to 2000 loop
            wait until rising_edge(clk);
            if done = '1' then
                report "TEST1 done at cycle " & integer'image(i) severity note;
                report "CT = " & to_hstring(ciphertext) severity note;
                if ciphertext = NIST_CT then
                    report "[PASS] TEST1 CIPHERTEXT CORRECT" severity note;
                    test1_pass <= true;
                else
                    report "[FAIL] TEST1 CIPHERTEXT WRONG" severity error;
                    report "  Expected: " & to_hstring(NIST_CT) severity error;
                    report "  Got:      " & to_hstring(ciphertext) severity error;
                end if;
                exit;
            end if;
            if i = 2000 then
                report "[FAIL] TEST1: timeout" severity error;
            end if;
        end loop;

        wait for CLK_PERIOD * 20;

        -- =====================================================================
        -- Test 2: mask=0xEF (byte-uniform, non-zero)
        -- CRITICAL: Must produce EXACT SAME ciphertext as Test 1!
        -- This is the PROOF that masking is mathematically correct.
        -- V1 FAILED this test. V2 MUST PASS it.
        -- =====================================================================
        report "=== TEST 2: mask=0xEF (MASKED - MUST MATCH KAT) ===" severity note;
        -- V2: Only lower 8 bits matter (byte-uniform masking)
        -- Set full 128-bit trng_mask but core extracts trng_mask(7:0) = 0xEF
        trng_mask <= x"000000000000000000000000000000EF";
        -- Reload key (same key)
        key_load <= '1';
        wait until rising_edge(clk);
        key_load <= '0';
        wait for CLK_PERIOD * 5;

        plaintext <= x"00112233445566778899aabbccddeeff";
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        for i in 1 to 2000 loop
            wait until rising_edge(clk);
            if done = '1' then
                report "TEST2 done at cycle " & integer'image(i) severity note;
                report "CT = " & to_hstring(ciphertext) severity note;
                if ciphertext = NIST_CT then
                    report "[PASS] TEST2 CIPHERTEXT CORRECT - masking is CORRECT!" severity note;
                    test2_pass <= true;
                else
                    report "[FAIL] TEST2 CIPHERTEXT WRONG - masking is BROKEN!" severity error;
                    report "  Expected: " & to_hstring(NIST_CT) severity error;
                    report "  Got:      " & to_hstring(ciphertext) severity error;
                    report "  XOR diff: " & to_hstring(ciphertext xor NIST_CT) severity error;
                end if;
                if fault_detected = '1' then
                    report "  WARNING: fault_detected asserted" severity warning;
                end if;
                exit;
            end if;
            if fault_detected = '1' then
                report "TEST2 FAULT at cycle " & integer'image(i) severity warning;
            end if;
            if i = 2000 then
                report "[FAIL] TEST2: timeout" severity error;
            end if;
        end loop;

        wait for CLK_PERIOD * 20;

        -- =====================================================================
        -- Test 3: mask=0xA5 (different mask - second verification)
        -- Must also produce EXACT SAME ciphertext
        -- =====================================================================
        report "=== TEST 3: mask=0xA5 (SECOND MASK - MUST MATCH KAT) ===" severity note;
        trng_mask <= x"000000000000000000000000000000A5";
        key_load <= '1';
        wait until rising_edge(clk);
        key_load <= '0';
        wait for CLK_PERIOD * 5;

        plaintext <= x"00112233445566778899aabbccddeeff";
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        for i in 1 to 2000 loop
            wait until rising_edge(clk);
            if done = '1' then
                report "TEST3 done at cycle " & integer'image(i) severity note;
                report "CT = " & to_hstring(ciphertext) severity note;
                if ciphertext = NIST_CT then
                    report "[PASS] TEST3 CIPHERTEXT CORRECT - masking confirmed!" severity note;
                    test3_pass <= true;
                else
                    report "[FAIL] TEST3 CIPHERTEXT WRONG!" severity error;
                    report "  Expected: " & to_hstring(NIST_CT) severity error;
                    report "  Got:      " & to_hstring(ciphertext) severity error;
                end if;
                exit;
            end if;
            if i = 2000 then
                report "[FAIL] TEST3: timeout" severity error;
            end if;
        end loop;

        wait for CLK_PERIOD * 10;

        -- =====================================================================
        -- FINAL SCOREBOARD
        -- =====================================================================
        report "=======================================" severity note;
        if test1_pass and test2_pass and test3_pass then
            report "[PASS] ALL 3 TESTS PASSED - MASKED S-BOX IS CORRECT" severity note;
        else
            report "[FAIL] NOT ALL TESTS PASSED" severity error;
            if not test1_pass then report "  FAIL: Test 1 (baseline)" severity error; end if;
            if not test2_pass then report "  FAIL: Test 2 (mask=0xEF)" severity error; end if;
            if not test3_pass then report "  FAIL: Test 3 (mask=0xA5)" severity error; end if;
        end if;
        report "=======================================" severity note;

        sim_done <= true;
        wait;
    end process;

end Behavioral;
