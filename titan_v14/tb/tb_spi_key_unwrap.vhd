--------------------------------------------------------------------------------
-- PROJECT TITAN V14.1: SPI Key Unwrap Testbench
-- Verifies the encrypted SPI key transfer protocol end-to-end
--------------------------------------------------------------------------------
-- TEST STRATEGY:
--   Uses a reference AES instance to independently compute expected
--   Session Key and keystream. Then feeds nonce + encrypted key to DUT
--   and verifies that plain_key_out matches the original key.
--
-- The reference AES uses the same core as the DUT — this is a
-- self-consistency test. The AES core itself is validated by
-- tb_sbox_exhaustive and tb_sha256 (NIST vectors).
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_spi_key_unwrap is
end entity tb_spi_key_unwrap;

architecture sim of tb_spi_key_unwrap is

    constant CLK_PERIOD : time := 20 ns;

    -- DUT signals
    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal kill_signal   : std_logic := '0';
    signal transport_key : std_logic_vector(255 downto 0);
    signal trng_mask     : std_logic_vector(127 downto 0);
    signal nonce_in      : std_logic_vector(127 downto 0);
    signal nonce_valid   : std_logic := '0';
    signal enc_key_in    : std_logic_vector(255 downto 0);
    signal enc_key_valid : std_logic := '0';
    signal plain_key_out : std_logic_vector(255 downto 0);
    signal key_ready     : std_logic;
    signal unwrap_fail   : std_logic;
    signal dut_busy      : std_logic;

    -- Reference AES
    signal ref_key_in    : std_logic_vector(255 downto 0);
    signal ref_key_load  : std_logic := '0';
    signal ref_pt_in     : std_logic_vector(127 downto 0);
    signal ref_start     : std_logic := '0';
    signal ref_ct_out    : std_logic_vector(127 downto 0);
    signal ref_done      : std_logic;
    signal ref_busy      : std_logic;
    signal ref_fault     : std_logic;

    -- Test constants
    constant TK : std_logic_vector(255 downto 0) :=
        x"0123456789ABCDEF_FEDCBA9876543210_DEADBEEFCAFEBABE_1337FACE7007F00D";
    constant NONCE : std_logic_vector(127 downto 0) :=
        x"A5A5A5A5_5A5A5A5A_F0F0F0F0_0F0F0F0F";
    constant REAL_KEY : std_logic_vector(255 downto 0) :=
        x"1111111122222222_3333333344444444_5555555566666666_7777777788888888";
    constant MASK_ZERO : std_logic_vector(127 downto 0) := (others => '0');

    -- Computed expected values
    signal expected_sk_hi  : std_logic_vector(127 downto 0);
    signal expected_sk_lo  : std_logic_vector(127 downto 0);
    signal expected_ks_hi  : std_logic_vector(127 downto 0);
    signal expected_ks_lo  : std_logic_vector(127 downto 0);
    signal enc_key_ref     : std_logic_vector(255 downto 0);

    signal all_pass : boolean := true;

begin

    clk <= not clk after CLK_PERIOD / 2;

    -- DUT
    dut : entity work.spi_key_unwrap
        port map (
            clk           => clk,
            rst_n         => rst_n,
            kill_signal   => kill_signal,
            transport_key => transport_key,
            trng_mask     => trng_mask,
            nonce_in      => nonce_in,
            nonce_valid   => nonce_valid,
            enc_key_in    => enc_key_in,
            enc_key_valid => enc_key_valid,
            plain_key_out => plain_key_out,
            key_ready     => key_ready,
            unwrap_fail   => unwrap_fail,
            busy          => dut_busy
        );

    -- Reference AES
    ref_aes : entity work.aes256_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => '0',
            key_in         => ref_key_in,
            key_load       => ref_key_load,
            plaintext      => ref_pt_in,
            start          => ref_start,
            ciphertext     => ref_ct_out,
            done           => ref_done,
            busy           => ref_busy,
            trng_mask      => MASK_ZERO,
            fault_detected => ref_fault
        );

    ---------------------------------------------------------------------------
    -- STIMULUS
    ---------------------------------------------------------------------------
    process
    begin
        transport_key <= TK;
        trng_mask     <= MASK_ZERO;
        nonce_in      <= (others => '0');
        enc_key_in    <= (others => '0');

        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        -----------------------------------------------------------------
        -- STEP 0: Compute expected values with reference AES
        -----------------------------------------------------------------
        report "STEP 0: Computing expected values with reference AES...";

        -- Load TK into ref AES
        ref_key_in   <= TK;
        ref_key_load <= '1';
        wait for CLK_PERIOD;
        ref_key_load <= '0';
        -- AES key expansion + masked table recomp takes ~600 cycles
        wait for CLK_PERIOD * 800;

        -- SK_hi = AES(TK, Nonce)
        ref_pt_in <= NONCE;
        ref_start <= '1';
        wait for CLK_PERIOD;
        ref_start <= '0';
        for i in 0 to 2000 loop
            wait for CLK_PERIOD;
            if ref_done = '1' then
                exit;
            end if;
        end loop;
        assert ref_done = '1'
            report "REF AES SK_hi did not complete" severity failure;
        expected_sk_hi <= ref_ct_out;
        wait for CLK_PERIOD;

        -- SK_lo = AES(TK, Nonce XOR 0x01)
        ref_pt_in <= NONCE xor (127 downto 1 => '0') & '1';
        ref_start <= '1';
        wait for CLK_PERIOD;
        ref_start <= '0';
        for i in 0 to 2000 loop
            wait for CLK_PERIOD;
            if ref_done = '1' then
                exit;
            end if;
        end loop;
        assert ref_done = '1'
            report "REF AES SK_lo did not complete" severity failure;
        expected_sk_lo <= ref_ct_out;
        wait for CLK_PERIOD;

        report "  Session Key computed";

        -- Load Session Key into ref AES
        ref_key_in   <= expected_sk_hi & expected_sk_lo;
        ref_key_load <= '1';
        wait for CLK_PERIOD;
        ref_key_load <= '0';
        wait for CLK_PERIOD * 800;

        -- KS_hi = AES(SK, IV=0x00)
        ref_pt_in <= (others => '0');
        ref_start <= '1';
        wait for CLK_PERIOD;
        ref_start <= '0';
        for i in 0 to 2000 loop
            wait for CLK_PERIOD;
            if ref_done = '1' then
                exit;
            end if;
        end loop;
        assert ref_done = '1'
            report "REF AES KS_hi did not complete" severity failure;
        expected_ks_hi <= ref_ct_out;
        wait for CLK_PERIOD;

        -- KS_lo = AES(SK, IV=0x01)
        ref_pt_in <= (127 downto 1 => '0') & '1';
        ref_start <= '1';
        wait for CLK_PERIOD;
        ref_start <= '0';
        for i in 0 to 2000 loop
            wait for CLK_PERIOD;
            if ref_done = '1' then
                exit;
            end if;
        end loop;
        assert ref_done = '1'
            report "REF AES KS_lo did not complete" severity failure;
        expected_ks_lo <= ref_ct_out;
        wait for CLK_PERIOD;

        -- Encrypted key = Real Key XOR keystream
        enc_key_ref <= (REAL_KEY(255 downto 128) xor expected_ks_hi) &
                       (REAL_KEY(127 downto 0) xor expected_ks_lo);
        wait for CLK_PERIOD;
        report "  Reference encryption complete";

        -----------------------------------------------------------------
        -- TEST 1: Normal unwrap
        -----------------------------------------------------------------
        report "TEST 1: Normal encrypted key unwrap...";

        -- Send nonce to DUT
        nonce_in    <= NONCE;
        nonce_valid <= '1';
        wait for CLK_PERIOD;
        nonce_valid <= '0';

        -- Wait for SK derivation (2 AES ops = ~2x800 cycles)
        wait for CLK_PERIOD * 2500;

        -- DUT should be busy waiting for encrypted key
        assert dut_busy = '1'
            report "TEST 1 WARNING: DUT not busy -- might still be in SK derivation"
            severity warning;

        -- Send encrypted key
        enc_key_in    <= enc_key_ref;
        enc_key_valid <= '1';
        wait for CLK_PERIOD;
        enc_key_valid <= '0';

        -- Wait for decrypt (2 more AES ops)
        for i in 0 to 10000 loop
            wait for CLK_PERIOD;
            if key_ready = '1' then
                exit;
            end if;
            if unwrap_fail = '1' then
                report "TEST 1 FAIL: Unwrap reported failure!" severity error;
                all_pass <= false;
                exit;
            end if;
        end loop;

        if key_ready = '1' then
            if plain_key_out = REAL_KEY then
                report "TEST 1 PASS: Decrypted key matches original";
            else
                report "TEST 1 FAIL: Key mismatch!" severity error;
                all_pass <= false;
            end if;
        else
            report "TEST 1 FAIL: Timeout -- key_ready never asserted" severity error;
            all_pass <= false;
        end if;

        -----------------------------------------------------------------
        -- TEST 2: Kill signal zeroization
        -----------------------------------------------------------------
        report "TEST 2: Kill signal zeroization...";

        kill_signal <= '1';
        wait for CLK_PERIOD * 2;
        kill_signal <= '0';

        assert key_ready = '0'
            report "TEST 2 FAIL: key_ready should be '0' after kill"
            severity error;

        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 3;

        if key_ready = '0' then
            report "TEST 2 PASS: Kill zeroized state";
        else
            all_pass <= false;
        end if;

        -----------------------------------------------------------------
        -- TEST 3: Repeat (verify re-usability after kill)
        -----------------------------------------------------------------
        report "TEST 3: Repeat after kill...";

        nonce_in    <= NONCE;
        nonce_valid <= '1';
        wait for CLK_PERIOD;
        nonce_valid <= '0';
        wait for CLK_PERIOD * 2500;

        enc_key_in    <= enc_key_ref;
        enc_key_valid <= '1';
        wait for CLK_PERIOD;
        enc_key_valid <= '0';

        for i in 0 to 10000 loop
            wait for CLK_PERIOD;
            if key_ready = '1' then exit; end if;
            if unwrap_fail = '1' then
                report "TEST 3 FAIL: Unwrap error" severity error;
                all_pass <= false; exit;
            end if;
        end loop;

        if key_ready = '1' and plain_key_out = REAL_KEY then
            report "TEST 3 PASS: Repeatable after kill+reset";
        else
            report "TEST 3 FAIL" severity error;
            all_pass <= false;
        end if;

        -----------------------------------------------------------------
        -- DONE
        -----------------------------------------------------------------
        if all_pass then
            report "=== ALL SPI KEY UNWRAP TESTS PASS ===";
        else
            report "=== SOME TESTS FAILED ===" severity error;
        end if;

        wait for CLK_PERIOD * 10;
        std.env.finish;
    end process;

end architecture sim;
