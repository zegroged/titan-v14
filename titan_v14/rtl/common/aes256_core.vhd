--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES-256 Core (FAULT-PROTECTED, HARDENED)
-- NIST FIPS-197 Compliant — 14 Rounds, BRAM S-Box
--------------------------------------------------------------------------------
-- ★ FIX #1 V2: Byte-Uniform Masked Table Recomputation
--   V1: mask_affine() approach was mathematically broken
--   V2: Pre-compute mt[a] = S[a⊕m]⊕m for all 256 entries (258 cycles)
--       Runtime: mt[x⊕m] = S[x]⊕m → mathematically CORRECT
--       Mask is constant (byte-uniform m) through all 14 rounds:
--         SubBytes: table lookup preserves m
--         ShiftRows: permutation preserves m (byte reorder)
--         MixColumns: MixCol([m,m,m,m]) = [(2⊕3⊕1⊕1)·m] = [m] ✓
--         AddRoundKey: XOR with key doesn't touch mask
--
-- FAULT PROTECTION MECHANISMS (5 KATMAN):
--   A. Dual Round Counter: round_cnt + shadow_cnt, sum must == 14
--   B. Temporal Redundancy: encrypt twice (Pass1 vs Pass2), compare results
--   C. Redundant Round Computation: every round runs TWICE through the same
--      round function, outputs compared — catches transient faults (DFA)
--   D. Key Parity: XOR-reduce each round key at expansion, verify before
--      EVERY round in BOTH passes (not just Pass2)
--   E. Final Counter Sanity: VERIFY checks round_cnt==14 AND shadow_cnt==0
--
-- ROUND KEY STRATEGY:
--   Tüm 15 round key (RK0-RK14) önceden üretilip bir array'e
--   kaydedilir. Bu sayede key expansion ve round function arasında
--   senkronizasyon sorunu ortadan kalkar. Pass2 aynı key array'ini
--   kullanarak temporal redundancy sağlar.
--
-- TOPLAM MALİYET: ~120 LUT + 32 LUT×16 S-Box = ~632 LUT
-- LATENCY:        key_expand (~30 cycle) + recomp (258 cycle) + 2×14×2 round ≈ 400 cycle
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes256_core is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        kill_signal  : in  std_logic;
        key_in       : in  std_logic_vector(255 downto 0);
        key_load     : in  std_logic;
        plaintext    : in  std_logic_vector(127 downto 0);
        start        : in  std_logic;
        ciphertext   : out std_logic_vector(127 downto 0);
        done         : out std_logic;
        busy         : out std_logic;
        
        -- ★ FIX #1 V2: TRNG mask input (only lower 8 bits used for uniform mask)
        trng_mask    : in  std_logic_vector(127 downto 0);
        
        -- ★ FAULT DETECTION OUTPUT → kill chain'e bağlanır
        fault_detected : out std_logic
    );
end aes256_core;

architecture Behavioral of aes256_core is

    -------------------------------------------------------------------------
    -- FSM
    -------------------------------------------------------------------------
    type state_type is (
        IDLE, 
        -- Phase 1: Key expansion (tum round key'leri topla)
        KEY_EXPAND_WAIT,
        -- FIX #1 V2: Table recomputation (maskelenmis S-Box tablosu)
        RECOMP_WAIT_START,  -- Wait for table_valid to deassert (recomp started)
        RECOMP_TABLE,       -- Wait for table_valid to reassert (recomp finished)
        -- Phase 2: Encryption Pass 1
        PASS1_ADDRK0,
        PASS1_START_ROUND,    -- Round function ilk çalıştırma
        PASS1_WAIT_ROUND,     -- İlk rf_done bekle
        PASS1_LATCH_ROUND,    -- İlk sonucu verify register'a kaydet
        PASS1_VERIFY_ROUND,   -- ★ C: Round function İKİNCİ çalıştırma
        PASS1_WAIT_VERIFY,    -- İkinci rf_done bekle
        PASS1_CHECK_ROUND,    -- ★ C: İki sonucu karşılaştır
        -- Phase 3: Encryption Pass 2 (Temporal Redundancy)
        PASS2_ADDRK0,
        PASS2_START_ROUND,
        PASS2_WAIT_ROUND,
        PASS2_LATCH_ROUND,
        PASS2_VERIFY_ROUND,   -- ★ C: Redundant round (Pass2)
        PASS2_WAIT_VERIFY,
        PASS2_CHECK_ROUND,
        -- Phase 4: Final verification
        VERIFY
    );
    signal state : state_type := IDLE;

    -------------------------------------------------------------------------
    -- Round key storage (15 adet: RK0-RK14)
    -------------------------------------------------------------------------
    type rk_array_type is array (0 to 14) of std_logic_vector(127 downto 0);
    signal rk_array    : rk_array_type := (others => (others => '0'));
    signal rk_idx      : integer range 0 to 15 := 0;

    -------------------------------------------------------------------------
    -- Round state register
    -------------------------------------------------------------------------
    signal round_state : std_logic_vector(127 downto 0) := (others => '0');
    signal round_cnt   : integer range 0 to 14 := 0;

    -------------------------------------------------------------------------
    -- ★ FAULT PROTECTION A: Shadow round counter (down-counter)
    -------------------------------------------------------------------------
    signal shadow_cnt  : integer range 0 to 14 := 14;
    signal fault_flag  : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- ★ FAULT PROTECTION B: Temporal Redundancy
    -------------------------------------------------------------------------
    signal pass1_result  : std_logic_vector(127 downto 0) := (others => '0');
    signal saved_pt      : std_logic_vector(127 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- ★ FAULT PROTECTION F: CRC-32 Accumulator (Temporal Redundancy Hash)
    -------------------------------------------------------------------------
    signal pass1_crc     : std_logic_vector(31 downto 0) := x"FFFFFFFF";
    signal pass2_crc     : std_logic_vector(31 downto 0) := x"FFFFFFFF";

    -- XOR-reduce 128-bit state to 32-bit for CRC accumulation
    function xor_fold_128(s : std_logic_vector(127 downto 0)) return std_logic_vector is
        variable r : std_logic_vector(31 downto 0);
    begin
        r := s(127 downto 96) xor s(95 downto 64) xor s(63 downto 32) xor s(31 downto 0);
        return r;
    end function;

    -- Simple CRC-32 step: accumulate one 32-bit word into running CRC
    function crc32_step(crc_in : std_logic_vector(31 downto 0);
                        data   : std_logic_vector(31 downto 0))
        return std_logic_vector is
        variable c : std_logic_vector(31 downto 0);
    begin
        c := crc_in xor data;
        for i in 0 to 31 loop
            if c(0) = '1' then
                c := '0' & c(31 downto 1);
                c := c xor x"EDB88320";
            else
                c := '0' & c(31 downto 1);
            end if;
        end loop;
        return c;
    end function;

    -------------------------------------------------------------------------
    -- ★ FAULT PROTECTION C: Redundant Round Verification
    -------------------------------------------------------------------------
    signal round_verify_a : std_logic_vector(127 downto 0) := (others => '0');
    
    -------------------------------------------------------------------------
    -- ★ FAULT PROTECTION D: Key parity (15-bit: 1 per round key)
    -------------------------------------------------------------------------
    signal key_parity_vec  : std_logic_vector(14 downto 0) := (others => '0');
    
    -------------------------------------------------------------------------
    -- Key expansion interface
    -------------------------------------------------------------------------
    signal ke_key_load  : std_logic := '0';
    signal ke_start     : std_logic := '0';
    signal ke_round_key : std_logic_vector(127 downto 0);
    signal ke_valid     : std_logic;
    signal ke_done      : std_logic;

    -------------------------------------------------------------------------
    -- Round function interface
    -------------------------------------------------------------------------
    signal rf_start     : std_logic := '0';
    signal rf_state_in  : std_logic_vector(127 downto 0);
    signal rf_round_key : std_logic_vector(127 downto 0);
    signal rf_is_last   : std_logic;
    signal rf_state_out : std_logic_vector(127 downto 0);
    signal rf_done      : std_logic;

    -- ★ FIX #1 V2: Byte-uniform mask signals
    signal mask_byte       : std_logic_vector(7 downto 0) := (others => '0');
    signal mask_uniform    : std_logic_vector(127 downto 0) := (others => '0');
    signal rf_mask_out     : std_logic_vector(127 downto 0);
    signal mask_state      : std_logic_vector(127 downto 0) := (others => '0');
    signal saved_mask_byte : std_logic_vector(7 downto 0) := (others => '0');

    -- Table recomputation control
    signal recomp_start_sig : std_logic := '0';
    signal recomp_done_sig  : std_logic;

    -------------------------------------------------------------------------
    -- Parity helper function
    -------------------------------------------------------------------------
    function xor_reduce(v : std_logic_vector) return std_logic is
        variable result : std_logic := '0';
    begin
        for i in v'range loop
            result := result xor v(i);
        end loop;
        return result;
    end function;
    
    -------------------------------------------------------------------------
    -- Synthesis protection
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of round_state    : signal is "true";
    attribute dont_touch of shadow_cnt     : signal is "true";
    attribute dont_touch of fault_flag     : signal is "true";
    attribute dont_touch of pass1_result   : signal is "true";
    attribute dont_touch of round_verify_a : signal is "true";
    attribute dont_touch of mask_state     : signal is "true";
    attribute dont_touch of mask_byte      : signal is "true";
    attribute dont_touch of mask_uniform   : signal is "true";

begin

    -- ★ FIX #1 V2: Build uniform 128-bit mask from single byte
    -- {mask_byte, mask_byte, ..., mask_byte} × 16 = 128-bit uniform mask
    mask_uniform <= mask_byte & mask_byte & mask_byte & mask_byte &
                    mask_byte & mask_byte & mask_byte & mask_byte &
                    mask_byte & mask_byte & mask_byte & mask_byte &
                    mask_byte & mask_byte & mask_byte & mask_byte;

    -------------------------------------------------------------------------
    -- Key Expansion
    -------------------------------------------------------------------------
    key_exp_inst : entity work.aes_key_expand
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => kill_signal,
            key_in      => key_in,
            key_load    => ke_key_load,
            key_start   => ke_start,
            round_key   => ke_round_key,
            round_valid => ke_valid,
            expand_done => ke_done
        );

    -------------------------------------------------------------------------
    -- Round Function (V2: byte-uniform mask interface)
    -------------------------------------------------------------------------
    round_inst : entity work.aes_round
        port map (
            clk           => clk,
            state_in      => rf_state_in,
            round_key     => rf_round_key,
            is_last_round => rf_is_last,
            start         => rf_start,
            -- ★ FIX #1 V2: Byte-uniform mask interface
            mask_byte     => mask_byte,
            recomp_start  => recomp_start_sig,
            recomp_done   => recomp_done_sig,
            mask_out      => rf_mask_out,
            state_out     => rf_state_out,
            done          => rf_done
        );

    rf_state_in  <= round_state;
    rf_round_key <= rk_array(round_cnt) when round_cnt <= 14 else (others => '0');
    rf_is_last   <= '1' when round_cnt = 14 else '0';
    
    -- Fault output → kill chain
    fault_detected <= fault_flag;

    -------------------------------------------------------------------------
    -- Main FSM
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            state          <= IDLE;
            round_state    <= (others => '0');
            round_cnt      <= 0;
            shadow_cnt     <= 14;
            ciphertext     <= (others => '0');
            done           <= '0';
            busy           <= '0';
            ke_key_load    <= '0';
            ke_start       <= '0';
            rf_start       <= '0';
            pass1_result   <= (others => '0');
            saved_pt       <= (others => '0');
            round_verify_a <= (others => '0');
            fault_flag     <= '0';
            key_parity_vec <= (others => '0');
            rk_idx         <= 0;
            rk_array       <= (others => (others => '0'));
            mask_byte      <= (others => '0');
            mask_state     <= (others => '0');
            saved_mask_byte <= (others => '0');
            recomp_start_sig <= '0';

        elsif rising_edge(clk) then
            -- Defaults (pulse sinyalleri)
            ke_key_load      <= '0';
            ke_start         <= '0';
            rf_start         <= '0';
            done             <= '0';
            recomp_start_sig <= '0';

            if rst_n = '0' then
                state      <= IDLE;
                round_cnt  <= 0;
                shadow_cnt <= 14;
                busy       <= '0';
                fault_flag <= '0';
                rk_idx     <= 0;
                mask_byte  <= (others => '0');
                recomp_start_sig <= '0';
            else
                case state is

                    -- =============================================================
                    -- IDLE: Key load kabul et veya encryption başlat
                    -- =============================================================
                    when IDLE =>
                        busy       <= '0';
                        fault_flag <= '0';
                        if key_load = '1' then
                            ke_key_load <= '1';
                        elsif start = '1' then
                            busy      <= '1';
                            ke_start  <= '1';
                            saved_pt  <= plaintext;
                            rk_idx    <= 0;
                            -- ★ FIX V2: Extract mask byte from TRNG
                            mask_byte       <= trng_mask(7 downto 0);
                            saved_mask_byte <= trng_mask(7 downto 0);
                            -- ★ FIX: Reset CRC accumulators for each new encryption
                            pass1_crc <= x"FFFFFFFF";
                            pass2_crc <= x"FFFFFFFF";
                            state     <= KEY_EXPAND_WAIT;
                        end if;

                    -- =============================================================
                    -- KEY_EXPAND_WAIT: Tüm 15 round key'i topla + parity kaydet
                    -- =============================================================
                    when KEY_EXPAND_WAIT =>
                        if ke_valid = '1' then
                            rk_array(rk_idx)  <= ke_round_key;
                            key_parity_vec(rk_idx) <= xor_reduce(ke_round_key);
                            if rk_idx = 14 then
                                -- FIX V2: Start table recomputation
                                recomp_start_sig <= '1';
                                state <= RECOMP_WAIT_START;
                            else
                                rk_idx <= rk_idx + 1;
                            end if;
                        end if;

                    -- =============================================================
                    -- FIX V2: RECOMP synchronization (two-phase handshake)
                    -- Phase 1: Wait for S-Box to ACK start (table_valid goes LOW)
                    -- Phase 2: Wait for S-Box to finish (table_valid goes HIGH)
                    -- This prevents a race where old table_valid='1' is read
                    -- =============================================================
                    when RECOMP_WAIT_START =>
                        -- Wait for S-Box to acknowledge start (deassert table_valid)
                        if recomp_done_sig = '0' then
                            state <= RECOMP_TABLE;
                        end if;

                    when RECOMP_TABLE =>
                        -- Wait for S-Box to finish recomputation (reassert table_valid)
                        if recomp_done_sig = '1' then
                            state <= PASS1_ADDRK0;
                        end if;

                    -- =============================================================
                    -- PASS 1: İlk şifreleme (redundant round ile)
                    -- =============================================================
                    when PASS1_ADDRK0 =>
                        -- ★ FIX V2: Byte-uniform mask — mask_state = {m×16}
                        mask_state  <= mask_uniform;
                        -- Apply initial AddRoundKey + mask
                        round_state <= saved_pt xor rk_array(0) xor mask_uniform;
                        round_cnt   <= 1;
                        shadow_cnt  <= 13;
                        -- ★ D: RK0 parity check (Pass1)
                        if xor_reduce(rk_array(0)) /= key_parity_vec(0) then
                            fault_flag <= '1';
                        end if;
                        state <= PASS1_START_ROUND;

                    when PASS1_START_ROUND =>
                        -- ★ A: Dual counter check
                        if (round_cnt + shadow_cnt) /= 14 then
                            fault_flag <= '1';
                        end if;
                        -- ★ D: Key parity check
                        if xor_reduce(rk_array(round_cnt)) /= key_parity_vec(round_cnt) then
                            fault_flag <= '1';
                        end if;
                        rf_start <= '1';
                        state    <= PASS1_WAIT_ROUND;

                    when PASS1_WAIT_ROUND =>
                        if rf_done = '1' then
                            state <= PASS1_LATCH_ROUND;
                        end if;

                    when PASS1_LATCH_ROUND =>
                        -- İlk çalıştırma sonucunu verify register'a kaydet
                        round_verify_a <= rf_state_out;
                        -- Round function'ı AYNI girişlerle tekrar başlat
                        state <= PASS1_VERIFY_ROUND;

                    when PASS1_VERIFY_ROUND =>
                        -- ★ C: Redundant round — aynı girişlerle 2. çalıştırma
                        rf_start <= '1';
                        state    <= PASS1_WAIT_VERIFY;

                    when PASS1_WAIT_VERIFY =>
                        if rf_done = '1' then
                            state <= PASS1_CHECK_ROUND;
                        end if;

                    when PASS1_CHECK_ROUND =>
                        -- ★ C: İki çalıştırma sonucunu karşılaştır
                        if rf_state_out /= round_verify_a then
                            fault_flag <= '1';
                        end if;
                        -- Doğrulanmış sonucu round state'e yaz
                        round_state <= round_verify_a;
                        -- ★ F: Accumulate pass1 CRC
                        pass1_crc <= crc32_step(pass1_crc, xor_fold_128(round_verify_a));
                        -- ★ FIX V2: mask_state stays constant (byte-uniform)
                        -- No need to update from rf_mask_out — mask is always {m×16}
                        -- This is what makes the math work!
                        if round_cnt = 14 then
                            pass1_result <= round_verify_a;
                            -- ★ F: Finalize pass1_crc
                            pass1_crc <= not crc32_step(pass1_crc, xor_fold_128(round_verify_a));
                            round_cnt  <= 1;
                            shadow_cnt <= 13;
                            state      <= PASS2_ADDRK0;
                        else
                            round_cnt  <= round_cnt + 1;
                            shadow_cnt <= shadow_cnt - 1;
                            state      <= PASS1_START_ROUND;
                        end if;

                    -- =============================================================
                    -- PASS 2: Temporal Redundancy (redundant round ile)
                    -- =============================================================
                    when PASS2_ADDRK0 =>
                        -- ★ FIX V2: Reuse same mask_byte for Pass2
                        mask_byte   <= saved_mask_byte;
                        mask_state  <= mask_uniform;
                        round_state <= saved_pt xor rk_array(0) xor mask_uniform;
                        -- ★ D: RK0 parity check (Pass2)
                        if xor_reduce(rk_array(0)) /= key_parity_vec(0) then
                            fault_flag <= '1';
                        end if;
                        state <= PASS2_START_ROUND;

                    when PASS2_START_ROUND =>
                        -- ★ A: Dual counter check
                        if (round_cnt + shadow_cnt) /= 14 then
                            fault_flag <= '1';
                        end if;
                        -- ★ D: Key parity check
                        if xor_reduce(rk_array(round_cnt)) /= key_parity_vec(round_cnt) then
                            fault_flag <= '1';
                        end if;
                        rf_start <= '1';
                        state    <= PASS2_WAIT_ROUND;

                    when PASS2_WAIT_ROUND =>
                        if rf_done = '1' then
                            state <= PASS2_LATCH_ROUND;
                        end if;

                    when PASS2_LATCH_ROUND =>
                        round_verify_a <= rf_state_out;
                        state <= PASS2_VERIFY_ROUND;

                    when PASS2_VERIFY_ROUND =>
                        -- ★ C: Redundant round (Pass2)
                        rf_start <= '1';
                        state    <= PASS2_WAIT_VERIFY;

                    when PASS2_WAIT_VERIFY =>
                        if rf_done = '1' then
                            state <= PASS2_CHECK_ROUND;
                        end if;

                    when PASS2_CHECK_ROUND =>
                        -- ★ C: Karşılaştır
                        if rf_state_out /= round_verify_a then
                            fault_flag <= '1';
                        end if;
                        round_state <= round_verify_a;
                        -- ★ F: Accumulate pass2 CRC
                        pass2_crc <= crc32_step(pass2_crc, xor_fold_128(round_verify_a));
                        -- ★ FIX V2: mask_state stays constant (byte-uniform)
                        if round_cnt = 14 then
                            state <= VERIFY;
                        else
                            round_cnt  <= round_cnt + 1;
                            shadow_cnt <= shadow_cnt - 1;
                            state      <= PASS2_START_ROUND;
                        end if;

                    -- =============================================================
                    -- VERIFY: 5 katmanlı final doğrulama
                    -- =============================================================
                    when VERIFY =>
                        -- ★ E: Final counter sanity
                        if round_cnt /= 14 or shadow_cnt /= 0 then
                            fault_flag <= '1';
                        end if;
                        
                        if pass1_result = round_verify_a and fault_flag = '0'
                           and pass1_crc = (not pass2_crc) then
                            -- ✅ ALL CLEAR: 5 katman geçti → çıktı ver
                            -- ★ FIX V2: Remove uniform mask from output
                            -- mask_state = {m, m, ..., m} = mask_uniform
                            ciphertext <= pass1_result xor mask_state;
                            done       <= '1';
                        else
                            -- ❌ FAULT DETECTED → çıktı VERİLMEZ, sıfır gönder
                            ciphertext <= (others => '0');
                            fault_flag <= '1';
                            done       <= '0';
                        end if;
                        busy  <= '0';
                        state <= IDLE;

                    when others =>
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
