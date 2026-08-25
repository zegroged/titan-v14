--------------------------------------------------------------------------------
-- PROJECT TITAN V14: 2nd-Order Masking Verification Testbench
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_aes256_second_order is
end tb_aes256_second_order;

architecture Behavioral of tb_aes256_second_order is

    constant CLK_PERIOD : time := 20 ns;
    constant MAX_CYCLES : integer := 500;

    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal trng_bit     : std_logic := '0';
    signal trng_valid   : std_logic := '0';
    signal mask_a       : std_logic_vector(127 downto 0);
    signal mask_b       : std_logic_vector(127 downto 0);
    signal bridge_ready : std_logic;
    signal reseed_count : std_logic_vector(7 downto 0);

    signal kill_signal   : std_logic := '0';
    signal key_in        : std_logic_vector(255 downto 0) := (others => '0');
    signal key_load      : std_logic := '0';
    signal plaintext     : std_logic_vector(127 downto 0) := (others => '0');
    signal start         : std_logic := '0';
    signal ciphertext    : std_logic_vector(127 downto 0);
    signal done_sig      : std_logic;
    signal busy          : std_logic;
    signal trng_mask     : std_logic_vector(127 downto 0) := (others => '0');
    signal fault_detected: std_logic;

    signal done_flag : boolean := false;

    constant NIST_KEY : std_logic_vector(255 downto 0) :=
        x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    constant NIST_PT  : std_logic_vector(127 downto 0) :=
        x"00112233445566778899aabbccddeeff";
    constant NIST_CT  : std_logic_vector(127 downto 0) :=
        x"8ea2b7ca516745bfeafc49904b496089";

    function hamming_weight(v : std_logic_vector) return integer is
        variable hw : integer := 0;
    begin
        for i in v'range loop
            if v(i) = '1' then hw := hw + 1; end if;
        end loop;
        return hw;
    end function;

    signal lfsr_sim : std_logic_vector(31 downto 0) := x"DEADBEEF";

begin

    clk <= not clk after CLK_PERIOD / 2 when not done_flag else '0';

    bridge_inst : entity work.trng_drbg_bridge
        port map (
            clk => clk, rst_n => rst_n,
            trng_bit => trng_bit, trng_valid => trng_valid,
            mask_a => mask_a, mask_b => mask_b,
            bridge_ready => bridge_ready, reseed_count => reseed_count
        );

    aes_inst : entity work.aes256_core
        port map (
            clk => clk, rst_n => rst_n, kill_signal => kill_signal,
            key_in => key_in, key_load => key_load,
            plaintext => plaintext, start => start,
            ciphertext => ciphertext, done => done_sig, busy => busy,
            trng_mask => trng_mask, fault_detected => fault_detected
        );

    trng_gen : process(clk)
    begin
        if rising_edge(clk) and rst_n = '1' then
            lfsr_sim <= lfsr_sim(30 downto 0) &
                       (lfsr_sim(31) xor lfsr_sim(21) xor
                        lfsr_sim(1) xor lfsr_sim(0));
            trng_bit   <= lfsr_sim(31);
            trng_valid <= '1';
        end if;
    end process trng_gen;

    stimulus : process
        variable pass_count  : integer := 0;
        variable fail_count  : integer := 0;
        variable hw_a        : integer;
        variable hw_b        : integer;
        variable xor_hw      : integer;
        variable mask_samples: integer := 0;
        variable hw_a_sum    : integer := 0;
        variable hw_b_sum    : integer := 0;
        variable xor_sum     : integer := 0;
        variable prev_a      : std_logic_vector(127 downto 0);
        variable prev_b      : std_logic_vector(127 downto 0);
        variable changes_a   : integer := 0;
        variable changes_b   : integer := 0;
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD;

        report "========================================" severity note;
        report "  2ND-ORDER MASKING VERIFICATION" severity note;
        report "========================================" severity note;

        -- TEST 1: DRBG seeding
        report "=== TEST 1: DRBG Bridge seeding ===" severity note;
        for i in 0 to 500 loop
            wait for CLK_PERIOD;
            if bridge_ready = '1' then
                pass_count := pass_count + 1;
                report "  [PASS] Bridge ready after " &
                       integer'image(i) & " cycles" severity note;
                exit;
            end if;
            if i = 500 then
                fail_count := fail_count + 1;
                report "  [FAIL] Bridge not ready" severity error;
            end if;
        end loop;
        wait for CLK_PERIOD * 5;

        -- TEST 2: Mask independence
        report "=== TEST 2: Mask independence ===" severity note;
        for samp in 0 to 127 loop
            wait for CLK_PERIOD;
            hw_a := hamming_weight(mask_a);
            hw_b := hamming_weight(mask_b);
            xor_hw := hamming_weight(mask_a xor mask_b);
            hw_a_sum := hw_a_sum + hw_a;
            hw_b_sum := hw_b_sum + hw_b;
            xor_sum  := xor_sum + xor_hw;
            mask_samples := mask_samples + 1;
        end loop;
        report "  Avg HW(mask_a): " & integer'image(hw_a_sum / mask_samples) severity note;
        report "  Avg HW(mask_b): " & integer'image(hw_b_sum / mask_samples) severity note;
        report "  Avg HW(a XOR b): " & integer'image(xor_sum / mask_samples) severity note;

        if hw_a_sum / mask_samples > 40 and hw_a_sum / mask_samples < 88 then
            pass_count := pass_count + 1;
            report "  [PASS] mask_a HW in range" severity note;
        else
            fail_count := fail_count + 1;
            report "  [FAIL] mask_a HW out of range!" severity error;
        end if;
        if xor_sum / mask_samples > 40 and xor_sum / mask_samples < 88 then
            pass_count := pass_count + 1;
            report "  [PASS] mask independence OK" severity note;
        else
            fail_count := fail_count + 1;
            report "  [FAIL] masks correlated!" severity error;
        end if;

        -- TEST 3: AES NIST with DRBG mask
        report "=== TEST 3: AES NIST with DRBG mask ===" severity note;
        key_in <= NIST_KEY; key_load <= '1';
        wait for CLK_PERIOD;
        key_load <= '0';
        wait for CLK_PERIOD * 2;

        trng_mask <= mask_a;
        plaintext <= NIST_PT;
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        for i in 0 to MAX_CYCLES loop
            wait for CLK_PERIOD;
            exit when done_sig = '1';
        end loop;
        if ciphertext = NIST_CT then
            pass_count := pass_count + 1;
            report "  [PASS] NIST vector correct" severity note;
        else
            fail_count := fail_count + 1;
            report "  [FAIL] NIST vector mismatch!" severity error;
        end if;

        -- TEST 4: Different mask, same output
        report "=== TEST 4: Mask-invariant output ===" severity note;
        wait for CLK_PERIOD * 20;
        trng_mask <= mask_b;
        plaintext <= NIST_PT;
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';
        for i in 0 to MAX_CYCLES loop
            wait for CLK_PERIOD;
            exit when done_sig = '1';
        end loop;
        if ciphertext = NIST_CT then
            pass_count := pass_count + 1;
            report "  [PASS] Same output, different mask" severity note;
        else
            fail_count := fail_count + 1;
            report "  [FAIL] Output changed!" severity error;
        end if;

        -- TEST 5: Mask dynamism
        report "=== TEST 5: Mask dynamism ===" severity note;
        prev_a := mask_a;
        prev_b := mask_b;
        changes_a := 0;
        changes_b := 0;
        for i in 0 to 31 loop
            wait for CLK_PERIOD;
            if mask_a /= prev_a then changes_a := changes_a + 1; end if;
            if mask_b /= prev_b then changes_b := changes_b + 1; end if;
            prev_a := mask_a;
            prev_b := mask_b;
        end loop;
        report "  mask_a changed " & integer'image(changes_a) & "/32" severity note;
        report "  mask_b changed " & integer'image(changes_b) & "/32" severity note;
        if changes_a >= 28 and changes_b >= 28 then
            pass_count := pass_count + 1;
            report "  [PASS] Masks are dynamic" severity note;
        else
            fail_count := fail_count + 1;
            report "  [FAIL] Masks too static!" severity error;
        end if;

        -- RESULTS
        report "========================================" severity note;
        report "  2ND-ORDER MASKING RESULTS" severity note;
        report "========================================" severity note;
        report "  PASS: " & integer'image(pass_count) severity note;
        report "  FAIL: " & integer'image(fail_count) severity note;
        if fail_count = 0 then
            report "  [OK] ALL TESTS PASSED" severity note;
        else
            report "  [FAIL] SOME TESTS FAILED" severity error;
        end if;
        report "========================================" severity note;

        done_flag <= true;
        wait;
    end process stimulus;

end Behavioral;
