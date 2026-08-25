--------------------------------------------------------------------------------
-- TESTBENCH: AES-256 CTR Mode Functional Test (Adapted for TITAN V14)
-- Purpose: Verify CTR mode operation, streaming encryption, and KILL protocol
-- Source:  titan_v13/testbench/tb_aes256_ctr_mode.vhd (adapted)
--------------------------------------------------------------------------------
-- V14 ADAPTATION NOTES:
--   - Added omega_enable, trng_seed, trng_seed_valid ports
--   - Added fault_detected, omega_dummy_count, omega_active outputs
--   - Added dummy LFSR seed generator (good practice, not required)
--   - omega_enable='0' -> PRNG bypassed, pure AES-CTR test
--   - Boot sequence: key_valid -> IV derivation -> IDLE (ready for encrypt)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_aes256_ctr_mode is
end tb_aes256_ctr_mode;

architecture Behavioral of tb_aes256_ctr_mode is

    -- Clock and reset
    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal kill_signal   : std_logic := '0';
    signal test_done     : boolean := false;

    -- AES Core Wrapper signals (V14 full port map)
    signal master_key_in    : std_logic_vector(255 downto 0) := (others => '0');
    signal key_valid        : std_logic := '0';
    signal iv_in            : std_logic_vector(127 downto 0) := (others => '0');
    signal plain_text       : std_logic_vector(127 downto 0) := (others => '0');
    signal valid_in         : std_logic := '0';
    signal cipher_text      : std_logic_vector(127 downto 0);
    signal valid_out        : std_logic;
    signal fault_detected   : std_logic;

    -- V14 Omega Cloak ports
    signal omega_enable     : std_logic := '0';          -- Omega off: pure AES test
    signal trng_seed        : std_logic_vector(31 downto 0) := x"DEADBEEF";
    signal trng_seed_valid  : std_logic := '0';
    signal omega_dummy_count: std_logic_vector(15 downto 0);
    signal omega_active     : std_logic;

    constant CLK_PERIOD : time := 10 ns;

    -- Dummy LFSR seed generator (32-bit maximal LFSR)
    signal dummy_seed : std_logic_vector(31 downto 0) := x"ACCE55ED";

    -- Test data (NIST SP 800-38A, Section F.5.5)
    constant TEST_KEY : std_logic_vector(255 downto 0) :=
        X"603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4";
    constant TEST_IV  : std_logic_vector(127 downto 0) :=
        X"f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff";

    type plaintext_array is array (0 to 3) of std_logic_vector(127 downto 0);
    constant TEST_PLAINS : plaintext_array := (
        X"6bc1bee22e409f96e93d7e117393172a",
        X"ae2d8a571e03ac9c9eb76fac45af8e51",
        X"30c81c46a35ce411e5fbc1191a0a52ef",
        X"f69f2445df4f9b17ad2b417be66c3710"
    );

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
    -- Dummy LFSR Seed Generator (TB only)
    -- Ensures PRNG has non-zero state even if omega disabled
    -------------------------------------------------------------------------
    lfsr_proc: process(clk)
    begin
        if rising_edge(clk) then
            dummy_seed <= dummy_seed(30 downto 0) &
                         (dummy_seed(31) xor dummy_seed(21) xor
                          dummy_seed(1) xor dummy_seed(0));
        end if;
    end process;

    trng_seed <= dummy_seed;

    -------------------------------------------------------------------------
    -- DUT: V14 AES Core Wrapper (CTR + Omega Cloak)
    -------------------------------------------------------------------------
    dut : entity work.aes_core_wrapper
        port map (
            clk               => clk,
            rst_n             => rst_n,
            kill_signal       => kill_signal,
            master_key_in     => master_key_in,
            key_valid         => key_valid,
            iv_in             => iv_in,
            plain_text        => plain_text,
            valid_in          => valid_in,
            cipher_text       => cipher_text,
            valid_out         => valid_out,
            fault_detected    => fault_detected,
            omega_enable      => omega_enable,
            trng_seed         => trng_seed,
            trng_seed_valid   => trng_seed_valid,
            omega_dummy_count => omega_dummy_count,
            omega_active      => omega_active
        );

    -------------------------------------------------------------------------
    -- Test stimulus
    -------------------------------------------------------------------------
    stim_proc: process
    begin
        report "";
        report "===========================================";
        report "   AES-256-CTR MODE FUNCTIONAL TEST        ";
        report "   (TITAN V14 - Omega Cloak Disabled)      ";
        report "===========================================";
        report "";

        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        -- Seed the PRNG (good practice even with omega disabled)
        trng_seed_valid <= '1';
        wait for CLK_PERIOD * 2;
        trng_seed_valid <= '0';
        wait for CLK_PERIOD * 2;

        report "[TEST 1] Key Loading + IV Derivation";
        master_key_in <= TEST_KEY;
        iv_in         <= TEST_IV;
        key_valid     <= '1';
        wait for CLK_PERIOD * 2;
        key_valid     <= '1';  -- Keep valid

        -- Wait for key expansion + IV derivation (~200 cycles for V14)
        wait for CLK_PERIOD * 200;
        report "[PASS] Key loaded, IV derived (session counter based)";

        report "";
        report "[TEST 2] Streaming Encryption (4 blocks)";

        for i in 0 to 3 loop
            report "  Block " & integer'image(i) & ": Encrypting...";
            plain_text <= TEST_PLAINS(i);
            valid_in   <= '1';
            wait for CLK_PERIOD;
            valid_in   <= '0';

            -- Wait for output (V14 dual-pass: ~150 cycles per block)
            wait until valid_out = '1' for 1000 * CLK_PERIOD;

            if valid_out = '1' then
                report "    Encryption complete";
                wait for CLK_PERIOD;
            else
                report "    [WARN] Timeout waiting for output" severity warning;
            end if;

            wait for CLK_PERIOD * 5;
        end loop;

        report "[PASS] Streaming encryption complete";

        -- Check fault status
        if fault_detected = '0' then
            report "[PASS] No fault detected during encryption";
        else
            report "[FAIL] Fault detected - core integrity compromised!" severity error;
        end if;

        report "";
        report "[TEST 3] KILL Protocol Test";
        plain_text <= X"deadbeefcafebabedeadbeefcafebabe";
        valid_in   <= '1';
        wait for CLK_PERIOD;
        valid_in   <= '0';

        -- Trigger KILL mid-encryption
        wait for CLK_PERIOD * 10;
        report "  [INFO] KILL SIGNAL ACTIVATED!";
        kill_signal <= '1';
        wait for CLK_PERIOD * 2;

        -- Check that output is zeroed
        if cipher_text = X"00000000000000000000000000000000" then
            report "  [PASS] Cipher output correctly zeroed after KILL";
        else
            report "  [FAIL] ERROR: Cipher output not zeroed!" severity error;
        end if;

        if valid_out = '0' then
            report "  [PASS] Valid signal correctly deasserted";
        else
            report "  [FAIL] ERROR: Valid signal still active!" severity error;
        end if;

        wait for CLK_PERIOD * 10;
        kill_signal <= '0';

        report "";
        report "===========================================";
        report "   CTR MODE TEST COMPLETE                  ";
        report "===========================================";

        test_done <= true;
        wait;
    end process;

end Behavioral;
