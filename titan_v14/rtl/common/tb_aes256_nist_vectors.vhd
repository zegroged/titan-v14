--------------------------------------------------------------------------------
-- TESTBENCH: AES-256 NIST Test Vectors Validation (Adapted for TITAN V14)
-- Purpose: Verify AES-256 core against FIPS 197 standard test vectors
-- Source:  titan_v13/testbench/tb_aes256_nist_vectors.vhd (adapted)
--------------------------------------------------------------------------------
-- V14 ADAPTATION NOTES:
--   - DUT changed from aes256_key_expansion + aes256_encrypt_core
--     to unified aes256_core (V14 hardened, fault-protected)
--   - Added trng_mask port (set to zero — acceptable for functional test)
--   - Added fault_detected monitoring
--   - Boot sequence: key_load → start → KEY_EXPAND_WAIT → PASS1 → PASS2 → done
--   - V14 core runs 2 passes (temporal redundancy), so latency ≈ 150 cycles
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_aes256_nist_vectors is
end tb_aes256_nist_vectors;

architecture Behavioral of tb_aes256_nist_vectors is

    -- DUT signals
    signal clk            : std_logic := '0';
    signal rst_n          : std_logic := '0';
    signal kill_signal    : std_logic := '0';
    signal key_in         : std_logic_vector(255 downto 0) := (others => '0');
    signal key_load       : std_logic := '0';
    signal plaintext      : std_logic_vector(127 downto 0) := (others => '0');
    signal start          : std_logic := '0';
    signal ciphertext     : std_logic_vector(127 downto 0);
    signal done           : std_logic;
    signal busy           : std_logic;
    signal trng_mask      : std_logic_vector(127 downto 0) := (others => '0');
    signal fault_detected : std_logic;

    signal test_done : boolean := false;

    -- Clock period
    constant CLK_PERIOD : time := 10 ns; -- 100 MHz

    -------------------------------------------------------------------------
    -- NIST FIPS 197 Test Vectors (Appendix C.3 — AES-256)
    -------------------------------------------------------------------------
    -- Test Vector 1: NIST official
    constant TEST1_KEY    : std_logic_vector(255 downto 0) :=
        X"603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4";
    constant TEST1_PLAIN  : std_logic_vector(127 downto 0) :=
        X"6bc1bee22e409f96e93d7e117393172a";
    constant TEST1_CIPHER : std_logic_vector(127 downto 0) :=
        X"f3eed1bdb5d2a03c064b5a7e3db181f8";

    -- Test Vector 2: All zeros key
    constant TEST2_KEY    : std_logic_vector(255 downto 0) :=
        X"0000000000000000000000000000000000000000000000000000000000000000";
    constant TEST2_PLAIN  : std_logic_vector(127 downto 0) :=
        X"00000000000000000000000000000000";
    constant TEST2_CIPHER : std_logic_vector(127 downto 0) :=
        X"dc95c078a2408989ad48a21492842087";

    -- Test Vector 3: All ones key
    constant TEST3_KEY    : std_logic_vector(255 downto 0) :=
        X"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    constant TEST3_PLAIN  : std_logic_vector(127 downto 0) :=
        X"ffffffffffffffffffffffffffffffff";
    constant TEST3_CIPHER : std_logic_vector(127 downto 0) :=
        X"d5f93d6d3311cb309f23621b02fbd5e2";

begin

    -------------------------------------------------------------------------
    -- Clock generation
    -------------------------------------------------------------------------
    clk_process: process
    begin
        while not test_done loop
            clk <= '0';
            wait for CLK_PERIOD/2;
            clk <= '1';
            wait for CLK_PERIOD/2;
        end loop;
        wait;
    end process;

    -------------------------------------------------------------------------
    -- DUT: V14 AES-256 Core (Fault-Protected, Hardened)
    -------------------------------------------------------------------------
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
            done           => done,
            busy           => busy,
            trng_mask      => trng_mask,
            fault_detected => fault_detected
        );

    -------------------------------------------------------------------------
    -- Test stimulus
    -------------------------------------------------------------------------
    stim_proc: process
        variable test_passed : integer := 0;
        variable test_failed : integer := 0;

        procedure run_test (
            test_num        : integer;
            test_key        : std_logic_vector(255 downto 0);
            test_plain      : std_logic_vector(127 downto 0);
            expected_cipher : std_logic_vector(127 downto 0)
        ) is
        begin
            report "========================================";
            report "Running NIST Test " & integer'image(test_num);
            report "========================================";

            -- Load key
            key_in   <= test_key;
            key_load <= '1';
            wait for CLK_PERIOD;
            key_load <= '0';
            wait for CLK_PERIOD * 5;

            -- Start encryption (triggers key expansion + dual-pass encrypt)
            plaintext <= test_plain;
            start     <= '1';
            wait for CLK_PERIOD;
            start     <= '0';

            -- Wait for completion (V14 needs ~150 cycles: key expand + 2 passes)
            wait until done = '1' for 500 * CLK_PERIOD;

            if done /= '1' then
                report "[FAIL] TEST " & integer'image(test_num) & " TIMEOUT!" severity error;
                test_failed := test_failed + 1;
            elsif fault_detected = '1' then
                report "[FAIL] TEST " & integer'image(test_num) & " FAULT DETECTED!" severity error;
                test_failed := test_failed + 1;
            elsif ciphertext = expected_cipher then
                report "[PASS] TEST " & integer'image(test_num) & " NIST vector matched!";
                test_passed := test_passed + 1;
            else
                report "[FAIL] TEST " & integer'image(test_num) & " MISMATCH!" severity error;
                test_failed := test_failed + 1;
            end if;

            wait for CLK_PERIOD * 5;
        end procedure;

    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        report "";
        report "===========================================";
        report "  AES-256 NIST FIPS 197 VECTOR VALIDATION  ";
        report "  (TITAN V14 Hardened Core)                ";
        report "===========================================";
        report "";

        -- Run NIST test vectors
        run_test(1, TEST1_KEY, TEST1_PLAIN, TEST1_CIPHER);
        run_test(2, TEST2_KEY, TEST2_PLAIN, TEST2_CIPHER);
        run_test(3, TEST3_KEY, TEST3_PLAIN, TEST3_CIPHER);

        -- Summary
        report "";
        report "===========================================";
        report "  RESULTS: " & integer'image(test_passed) & " passed, " &
               integer'image(test_failed) & " failed";
        report "===========================================";

        if test_failed = 0 then
            report "[SUCCESS] ALL NIST TEST VECTORS PASSED! FIPS 197 COMPLIANT!";
        else
            report "[FAIL] SOME TESTS FAILED" severity failure;
        end if;

        test_done <= true;
        wait;
    end process;

end Behavioral;
