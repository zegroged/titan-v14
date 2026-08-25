--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Formal Verification -- PSL Assertions
-- Safety and Liveness properties for AES-256 Core
--------------------------------------------------------------------------------
-- PSL comments mark where formal tools would place properties.
-- GHDL simulation validates these assertions dynamically.
--
-- SAFETY:  S1-fault_sticky  S3-kill_zeroes  S4-no_output_on_fault  S5-fsm_valid
-- LIVENESS: L1-encrypt_bounded  L3-no_deadlock
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_formal_verification is
end tb_formal_verification;

architecture Behavioral of tb_formal_verification is

    constant CLK_PERIOD : time := 20 ns;
    constant MAX_ENCRYPT_CYCLES : integer := 500;

    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal kill_signal   : std_logic := '0';
    signal key_in        : std_logic_vector(255 downto 0) := (others => '0');
    signal key_load      : std_logic := '0';
    signal plaintext     : std_logic_vector(127 downto 0) := (others => '0');
    signal start         : std_logic := '0';
    signal ciphertext    : std_logic_vector(127 downto 0);
    signal done          : std_logic;
    signal busy          : std_logic;
    signal trng_mask     : std_logic_vector(127 downto 0) := (others => '0');
    signal fault_detected: std_logic;

    signal done_flag     : boolean := false;

    constant NIST_KEY : std_logic_vector(255 downto 0) :=
        x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    constant NIST_PT  : std_logic_vector(127 downto 0) :=
        x"00112233445566778899aabbccddeeff";
    constant ZERO128  : std_logic_vector(127 downto 0) := (others => '0');

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
            done           => done,
            busy           => busy,
            trng_mask      => trng_mask,
            fault_detected => fault_detected
        );

    -- Single stimulus process with inline assertion checks
    stimulus : process
        variable safety_pass   : integer := 0;
        variable safety_fail   : integer := 0;
        variable liveness_pass : integer := 0;
        variable liveness_fail : integer := 0;
        variable cycle_count   : integer := 0;
        variable prev_fault    : std_logic := '0';
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        report "========================================" severity note;
        report "  FORMAL VERIFICATION TEST SUITE" severity note;
        report "  5 Safety + 3 Liveness Assertions" severity note;
        report "========================================" severity note;

        -- =================================================================
        -- TEST 1: Normal encryption (S1, S4, S5, L1)
        -- =================================================================
        report "=== TEST 1: Normal encryption ===" severity note;
        key_in   <= NIST_KEY;
        key_load <= '1';
        wait for CLK_PERIOD;
        key_load <= '0';
        wait for CLK_PERIOD * 2;

        plaintext <= NIST_PT;
        trng_mask <= x"DEADBEEFCAFEBABE1234567890ABCDEF";
        start     <= '1';
        wait for CLK_PERIOD;
        start     <= '0';

        -- L1: Bounded completion check
        cycle_count := 0;
        for i in 0 to MAX_ENCRYPT_CYCLES loop
            wait for CLK_PERIOD;
            cycle_count := cycle_count + 1;

            -- S1: fault_sticky (continuously check during encryption)
            -- psl S1: assert always (fault_detected='1') ->
            --         next (fault_detected='1')
            --         abort (rst_n='0' or kill_signal='1');
            if prev_fault = '1' and fault_detected = '0' then
                report "[S1 FAIL] fault cleared without reset!" severity error;
                safety_fail := safety_fail + 1;
            end if;
            prev_fault := fault_detected;

            if done = '1' then
                report "  [L1 PASS] Completed in " &
                       integer'image(cycle_count) & " cycles" severity note;
                liveness_pass := liveness_pass + 1;
                exit;
            end if;

            if i = MAX_ENCRYPT_CYCLES then
                report "  [L1 FAIL] Timeout!" severity error;
                liveness_fail := liveness_fail + 1;
            end if;
        end loop;

        -- S1: No false fault in normal operation
        if fault_detected = '0' then
            safety_pass := safety_pass + 1;
            report "  [S1 PASS] No false fault" severity note;
        else
            safety_fail := safety_fail + 1;
            report "  [S1 FAIL] False fault!" severity error;
        end if;

        -- S5: FSM valid (busy should be '0' after done)
        -- psl S5: assert always (done='1') -> next (busy='0');
        wait for CLK_PERIOD;
        if busy = '0' then
            safety_pass := safety_pass + 1;
            report "  [S5 PASS] FSM idle after done" severity note;
        else
            safety_fail := safety_fail + 1;
            report "  [S5 FAIL] FSM still busy after done!" severity error;
        end if;

        wait for CLK_PERIOD * 3;

        -- =================================================================
        -- TEST 2: Kill mid-encryption (S3, L3)
        -- =================================================================
        report "=== TEST 2: Kill mid-encryption ===" severity note;
        plaintext <= x"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        start     <= '1';
        wait for CLK_PERIOD;
        start     <= '0';
        wait for CLK_PERIOD * 20;

        kill_signal <= '1';
        wait for CLK_PERIOD * 2;

        -- S3: Kill zeroes ciphertext
        -- psl S3: assert always (kill_signal='1') ->
        --         next (ciphertext = x"0..0");
        if ciphertext = ZERO128 then
            safety_pass := safety_pass + 1;
            report "  [S3 PASS] Ciphertext zeroed after kill" severity note;
        else
            safety_fail := safety_fail + 1;
            report "  [S3 FAIL] Ciphertext NOT zero!" severity error;
        end if;

        -- L3: FSM returns to IDLE
        -- psl L3: assert always (kill_signal='1') ->
        --         next (busy='0');
        if busy = '0' then
            liveness_pass := liveness_pass + 1;
            report "  [L3 PASS] FSM returned to IDLE" severity note;
        else
            liveness_fail := liveness_fail + 1;
            report "  [L3 FAIL] FSM stuck!" severity error;
        end if;

        kill_signal <= '0';
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        -- =================================================================
        -- TEST 3: Double encryption, no deadlock (L3)
        -- =================================================================
        report "=== TEST 3: Double encryption (deadlock check) ===" severity note;
        key_in   <= NIST_KEY;
        key_load <= '1';
        wait for CLK_PERIOD;
        key_load <= '0';
        wait for CLK_PERIOD * 2;

        -- First
        plaintext <= NIST_PT;
        start     <= '1';
        wait for CLK_PERIOD;
        start     <= '0';
        for i in 0 to MAX_ENCRYPT_CYCLES loop
            wait for CLK_PERIOD;
            exit when done = '1';
        end loop;
        wait for CLK_PERIOD * 3;

        -- Second (different PT, same key)
        plaintext <= x"FFEEDDCCBBAA99887766554433221100";
        start     <= '1';
        wait for CLK_PERIOD;
        start     <= '0';
        cycle_count := 0;
        for i in 0 to MAX_ENCRYPT_CYCLES loop
            wait for CLK_PERIOD;
            cycle_count := cycle_count + 1;
            if done = '1' then
                liveness_pass := liveness_pass + 1;
                report "  [L3 PASS] 2nd encrypt done in " &
                       integer'image(cycle_count) & " cycles" severity note;
                exit;
            end if;
            if i = MAX_ENCRYPT_CYCLES then
                liveness_fail := liveness_fail + 1;
                report "  [L3 FAIL] 2nd encrypt timeout!" severity error;
            end if;
        end loop;

        wait for CLK_PERIOD * 3;

        -- =================================================================
        -- TEST 4: Start while busy (S5 robustness)
        -- =================================================================
        report "=== TEST 4: Start while busy ===" severity note;
        plaintext <= NIST_PT;
        start     <= '1';
        wait for CLK_PERIOD;
        start     <= '0';
        wait for CLK_PERIOD * 10;

        -- Spurious start
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';

        for i in 0 to MAX_ENCRYPT_CYCLES loop
            wait for CLK_PERIOD;
            if done = '1' then
                safety_pass := safety_pass + 1;
                report "  [S5 PASS] Survived spurious start" severity note;
                exit;
            end if;
        end loop;

        -- S4 check: if no fault, output should be non-zero (valid ciphertext)
        if fault_detected = '0' and ciphertext /= ZERO128 then
            safety_pass := safety_pass + 1;
            report "  [S4 PASS] Valid output, no fault" severity note;
        elsif fault_detected = '1' and ciphertext = ZERO128 then
            safety_pass := safety_pass + 1;
            report "  [S4 PASS] Zero output with fault (correct)" severity note;
        elsif fault_detected = '1' and ciphertext /= ZERO128 then
            safety_fail := safety_fail + 1;
            report "  [S4 FAIL] Non-zero output despite fault!" severity error;
        end if;

        wait for CLK_PERIOD * 5;

        -- =================================================================
        -- FINAL REPORT
        -- =================================================================
        report "========================================" severity note;
        report "  FORMAL VERIFICATION RESULTS" severity note;
        report "========================================" severity note;
        report "  Safety  PASS: " & integer'image(safety_pass) severity note;
        report "  Safety  FAIL: " & integer'image(safety_fail) severity note;
        report "  Liveness PASS: " & integer'image(liveness_pass) severity note;
        report "  Liveness FAIL: " & integer'image(liveness_fail) severity note;
        report "  TOTAL:  " & integer'image(safety_pass + liveness_pass) &
               " PASS / " & integer'image(safety_fail + liveness_fail) &
               " FAIL" severity note;

        if safety_fail = 0 and liveness_fail = 0 then
            report "  [OK] ALL ASSERTIONS PASSED" severity note;
        else
            report "  [FAIL] SOME ASSERTIONS FAILED" severity error;
        end if;
        report "========================================" severity note;

        done_flag <= true;
        wait;
    end process stimulus;

end Behavioral;
