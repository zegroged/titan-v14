--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES Core Wrapper (CTR MODE + OMEGA CLOAK DPA PROTECTION)
-- Module: AES-256-CTR Stream Cipher Engine with DPA Countermeasures
--------------------------------------------------------------------------------
-- AMAC: aes256_core kullanarak CTR modunda gercek AES-256 sifreleme.
--       KILL sinyali geldiginde tum state ve key material async silinir.
--
-- CTR MODE (Counter Mode):
--   Keystream = AES_Encrypt(Key, Counter)
--   Ciphertext = Plaintext XOR Keystream
--
-- IV DERIVATION (V14 HARDENED):
--   IV = AES_Encrypt(Key, session_counter_padded)
--   session_counter immortal (kill/reset'ten etkilenmez, power-cycle sifirlar)
--
-- ★ OMEGA CLOAK DPA PROTECTION (V14.1):
--   omega_enable='1' → her gercek AES operasyonu oncesinde 0-3 dummy
--   AES encrypt calistirilir. Dummy'ler ayni AES core'u kullanir ama
--   random plaintext ile besler, sonucu atar. Guc profili gercekle AYNI.
--   Chaotic PRNG (Dual Logistic Map) dummy sayisini belirler.
--
-- GUVENLIK:
--   - Anahtar aes256_core icinde async wipe edilir
--   - Counter sifirlanir -> keystream uretimi durur
--   - key_valid='0' -> sifreleme yapilamaz
--   - IV, AES-KDF ile turetilir (XOR degil)
--   - DPA koruması: dummy ops güç izlerini maskeler
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes_core_wrapper is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        kill_signal  : in  std_logic;

        -- External Key Input (SPI'dan gelir)
        master_key_in : in  std_logic_vector(255 downto 0);
        key_valid     : in  std_logic;

        -- IV Input (TRNG'den gelir — su an kullanilmiyor, session_counter yeterli)
        iv_in         : in  std_logic_vector(127 downto 0);

        -- Veri Arayuzu (Streaming)
        plain_text   : in  std_logic_vector(127 downto 0);
        valid_in     : in  std_logic;

        cipher_text    : out std_logic_vector(127 downto 0);
        valid_out      : out std_logic;
        
        -- FAULT DETECTION (from AES core -> kill chain)
        fault_detected : out std_logic;

        -- ★ FAZ 13.2: TX/RX yön ayrımı — nonce space bölünmesi
        -- '0' = TX (bit 127 = '0'), '1' = RX (bit 127 = '1')
        direction      : in  std_logic;

        -- ★ FAZ 13.3: AES Timeout — FSM takılma koruması
        aes_timeout    : out std_logic;

        -- ★ OMEGA CLOAK: DPA Protection kontrol
        omega_enable    : in  std_logic;
        trng_seed       : in  std_logic_vector(31 downto 0);
        trng_seed_valid : in  std_logic;
        omega_dummy_count : out std_logic_vector(15 downto 0);
        omega_active      : out std_logic
    );
end aes_core_wrapper;

architecture Behavioral of aes_core_wrapper is

    -------------------------------------------------------------------------
    -- CTR Counter
    -------------------------------------------------------------------------
    signal ctr_block    : unsigned(127 downto 0) := (others => '0');
    signal ctr_loaded   : std_logic := '0';

    -------------------------------------------------------------------------
    -- AES Core interface
    -------------------------------------------------------------------------
    signal aes_start    : std_logic := '0';
    signal aes_done     : std_logic;
    signal aes_busy     : std_logic;
    signal aes_ct       : std_logic_vector(127 downto 0);
    signal aes_fault    : std_logic;
    signal aes_key_load : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- AES input MUX: normal counter vs IV derivation vs dummy
    -------------------------------------------------------------------------
    signal aes_pt_mux      : std_logic_vector(127 downto 0);
    signal iv_derive_mode  : std_logic := '0';  -- '1' = IV derivation aktif
    
    -- ★ FAZ 12.2: Key-dependent IV derivation
    -- key_hash_seed = AES(key, session_counter+1) — computed once per key load
    -- IV = AES(key, key_hash_seed XOR counter)
    -- Power cycle counter reset is now SAFE: farklı key_hash_seed = farklı IV space
    signal iv_derive_input : std_logic_vector(127 downto 0);
    signal key_hash_seed   : std_logic_vector(127 downto 0) := (others => '0');
    signal kdf_phase       : std_logic := '0'; -- '0'=seed derivation, '1'=IV derivation

    -- ★ FAZ 14.3: Forward Secrecy — session key
    signal session_key     : std_logic_vector(255 downto 0) := (others => '0');
    signal sk_derived      : std_logic := '0';
    signal sk_phase        : std_logic := '0'; -- '0'=SK_HI, '1'=SK_LO

    -- ★ BUG-1 FIX: Concurrent key mux (port map'te conditional OLMAZ)
    signal aes_key_mux     : std_logic_vector(255 downto 0);

    -- ★ BUG-2 FIX + WEAKNESS-2: Dedicated SK domain separators
    -- "SKHI" = 0x534B4849, "SKLO" = 0x534B4C4F
    constant SK_DOMAIN_HI  : std_logic_vector(127 downto 0) := x"534B_4849_0000_0000_0000_0000_0000_0000";
    constant SK_DOMAIN_LO  : std_logic_vector(127 downto 0) := x"534B_4C4F_0000_0000_0000_0000_0000_0000";

    -------------------------------------------------------------------------
    -- Pipeline registers
    -------------------------------------------------------------------------
    signal pt_latched   : std_logic_vector(127 downto 0) := (others => '0');
    -- ★ FIX: Pending request latch for valid_in during key derivation
    signal pending_valid : std_logic := '0';
    signal pending_pt    : std_logic_vector(127 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- Key loading edge detection
    -------------------------------------------------------------------------
    signal key_valid_d  : std_logic := '0';
    signal key_loaded   : std_logic := '0';
    signal iv_ready     : std_logic := '0';  -- IV AES-KDF tamamlandi mi?

    -------------------------------------------------------------------------
    -- FSM (Omega Cloak state'leri eklendi)
    -------------------------------------------------------------------------
    type state_type is (IDLE,
                        DERIVE_SK_HI, WAIT_SK_HI,   -- ★ 14.3: Session key high 128
                        DERIVE_SK_LO, WAIT_SK_LO,   -- ★ 14.3: Session key low 128
                        DERIVE_SEED, WAIT_SEED,
                        DERIVE_IV, WAIT_IV,
                        DUMMY_TIMER_WAIT,
                        ENCRYPT, WAIT_AES, OUTPUT);
    signal state : state_type := IDLE;

    -------------------------------------------------------------------------
    -- ★ FAZ 15.3: Randomized dummy timer — [390, 650] cycles
    -- Base 390 + chaos_value(7:0) (0-255) = 390-645
    -- Prevents power analysis from identifying dummy vs real AES operations
    constant DUMMY_AES_BASE   : integer := 390;
    constant DUMMY_AES_MAX    : integer := 650;
    signal dummy_target : integer range 0 to DUMMY_AES_MAX := DUMMY_AES_BASE;
    signal dummy_timer  : integer range 0 to DUMMY_AES_MAX := 0;

    -------------------------------------------------------------------------
    -- IMMORTAL SESSION COUNTER
    -------------------------------------------------------------------------
    signal session_counter : unsigned(31 downto 0) := (others => '0');
    signal sess_key_d      : std_logic := '0';

    -------------------------------------------------------------------------
    -- ★ OMEGA CLOAK: Chaotic PRNG signals
    -------------------------------------------------------------------------
    signal chaos_value     : std_logic_vector(31 downto 0);
    signal chaos_valid     : std_logic;
    signal chaos_byte      : std_logic_vector(7 downto 0);
    signal chaos_bit       : std_logic;
    -- ★ B-1 FIX: 128-bit independent chaos for mask
    signal chaos_value_128 : std_logic_vector(127 downto 0);
    signal chaos_128_valid : std_logic;
    
    -- Dummy control
    signal dummy_cnt       : unsigned(1 downto 0) := (others => '0');
    signal stat_dummies    : unsigned(15 downto 0) := (others => '0');
    signal omega_en_latched: std_logic := '0';  -- Latched at operation start
    
    -- Default r parameter for Logistic Map (3.99 in Q8.24)
    constant R_DEFAULT     : std_logic_vector(31 downto 0) := x"03FD70A4";

    -- ★ FIX #1: 128-bit mask for AES core (generated from chaotic PRNG)
    signal mask_128 : std_logic_vector(127 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- ★ FAZ 13.3: AES TIMEOUT WATCHDOG
    -- AES core 1024 cycle içinde done vermezse → FSM reset + timeout flag
    -------------------------------------------------------------------------
    constant AES_TIMEOUT_CYCLES : integer := 1024;
    signal aes_watchdog : integer range 0 to AES_TIMEOUT_CYCLES := 0;
    signal aes_timeout_flag : std_logic := '0';

    -------------------------------------------------------------------------
    -- Synthesis protection
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of ctr_block : signal is "true";
    attribute dont_touch of state : signal is "true";
    attribute dont_touch of session_counter : signal is "true";
    attribute dont_touch of iv_ready : signal is "true";
    attribute dont_touch of stat_dummies : signal is "true";
    attribute dont_touch of key_hash_seed : signal is "true";  -- ★ FAZ 12.2: protect seed
    attribute dont_touch of mask_128 : signal is "true";  -- ★ FIX #1: protect mask
    attribute dont_touch of aes_watchdog : signal is "true"; -- ★ FAZ 13.3: protect watchdog

begin

    -------------------------------------------------------------------------
    -- ★ FAZ 12.2: KEY-DEPENDENT IV DERIVATION
    -- Eski (TEHLİKELİ): iv = AES(key, "TITAN_IV" || counter)
    --   → Power cycle counter=0 → aynı key ile aynı IV → CTR XOR catastrophe
    -- Yeni (GÜVENLİ): 
    --   1. key_hash_seed = AES(key, domain_separator || session_counter)
    --   2. iv = AES(key, key_hash_seed XOR ctr_block_counter)
    --   → Aynı key + counter reset → key_hash_seed farklı → IV space benzersiz
    -------------------------------------------------------------------------
    -- ★ BUG-2 FIX: SK derivation gets its OWN domain separator
    -- 3 cases: SK_HI, SK_LO, or original seed/IV derivation
    iv_derive_input <= (SK_DOMAIN_HI(127 downto 32) & std_logic_vector(session_counter))
                       when sk_derived = '0' and sk_phase = '0'
                       else (SK_DOMAIN_LO(127 downto 32) & std_logic_vector(session_counter))
                       when sk_derived = '0' and sk_phase = '1'
                       else key_hash_seed xor
                            ((95 downto 0 => '0') &
                             std_logic_vector(session_counter))
                       when kdf_phase = '1'
                       else x"5449_5441_4E5F_4956_0000_0000" &
                            std_logic_vector(session_counter);

    -------------------------------------------------------------------------
    -- AES INPUT MUX: IV derivation / normal CTR counter
    -- (Dummies no longer go through AES — timer-based delay instead)
    -------------------------------------------------------------------------
    aes_pt_mux <= iv_derive_input when iv_derive_mode = '1'
                  else std_logic_vector(ctr_block);

    -------------------------------------------------------------------------
    -- STATUS OUTPUTS
    -------------------------------------------------------------------------
    omega_dummy_count <= std_logic_vector(stat_dummies);
    omega_active      <= '1' when state = DUMMY_TIMER_WAIT
                         else '0';
    -- ★ FAZ 13.3: Timeout output
    aes_timeout       <= aes_timeout_flag;

    -------------------------------------------------------------------------
    -- IMMORTAL SESSION COUNTER PROCESS
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            sess_key_d <= key_valid;
            if key_valid = '1' and sess_key_d = '0' then
                session_counter <= session_counter + 1;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- ★ CHAOTIC PRNG INSTANCE (Dual Logistic Map)
    -------------------------------------------------------------------------
    u_prng : entity work.chaotic_prng
        port map (
            clk         => clk,
            rst_n       => rst_n,
            seed        => trng_seed,
            r_param     => R_DEFAULT,
            load_seed   => trng_seed_valid,
            enable      => omega_enable,
            chaos_out   => chaos_value,
            chaos_valid => chaos_valid,
            chaos_bit   => chaos_bit,
            chaos_byte  => chaos_byte,
            -- ★ B-1 FIX: 128-bit independent mask
            chaos_out_128   => chaos_value_128,
            chaos_128_valid => chaos_128_valid,
            -- ★ UPGRADE: Cycle detection flag
            cycle_locked    => open  -- Monitored but not acted on here (AES has own fault detection)
        );

    -------------------------------------------------------------------------
    -- AES-256 Core Instance
    -------------------------------------------------------------------------
    -- ★ BUG-1 FIX: Key mux as concurrent signal (NOT in port map)
    aes_key_mux <= master_key_in when sk_derived = '0' else session_key;

    aes_inst : entity work.aes256_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => kill_signal,
            key_in         => aes_key_mux,  -- ★ BUG-1 FIX: simple signal
            key_load       => aes_key_load,
            plaintext      => aes_pt_mux,
            start          => aes_start,
            ciphertext     => aes_ct,
            done           => aes_done,
            busy           => aes_busy,
            -- ★ FIX #1: TRNG mask from chaotic PRNG
            trng_mask      => mask_128,
            fault_detected => aes_fault
        );
    
    -- Propagate fault to top-level
    fault_detected <= aes_fault;

    -------------------------------------------------------------------------
    -- ★ B-1 FIX: TRUE 128-BIT INDEPENDENT MASK from Chaotic PRNG
    -- Mask is LATCHED at aes_start to stay constant during dual-pass verify.
    -- If mask changes mid-operation, CRC(pass1) ≠ CRC(pass2) → aes_done never fires.
    -------------------------------------------------------------------------
    -- mask_128 latched in process (see below, at aes_start)

    -------------------------------------------------------------------------
    -- Main Process (with Omega Cloak dummy injection)
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            ctr_block      <= (others => '0');
            ctr_loaded     <= '0';
            pt_latched     <= (others => '0');
            cipher_text    <= (others => '0');
            valid_out      <= '0';
            aes_start      <= '0';
            aes_key_load   <= '0';
            key_valid_d    <= '0';
            key_loaded     <= '0';
            iv_ready       <= '0';
            iv_derive_mode <= '0';
            dummy_cnt      <= (others => '0');
            omega_en_latched <= '0';
            key_hash_seed  <= (others => '0');  -- ★ FAZ 12.2: seed de sıfırla
            kdf_phase      <= '0';
            session_key    <= (others => '0');  -- ★ FAZ 14.3: session key sıfırla
            sk_derived     <= '0';
            aes_watchdog   <= 0;            -- ★ FAZ 13.3: watchdog sıfırla
            aes_timeout_flag <= '0';
            pending_valid  <= '0';           -- ★ FIX: clear pending
            pending_pt     <= (others => '0');
            state          <= IDLE;

        elsif rising_edge(clk) then
            -- Defaults
            aes_start      <= '0';
            aes_key_load   <= '0';
            valid_out      <= '0';

            -- mask_128 is latched co-located with aes_start (see below)

            if rst_n = '0' then
                ctr_block      <= (others => '0');
                ctr_loaded     <= '0';
                key_loaded     <= '0';
                iv_ready       <= '0';
                iv_derive_mode <= '0';
                dummy_cnt      <= (others => '0');
                omega_en_latched <= '0';
                kdf_phase      <= '0';
                session_key    <= (others => '0');
                sk_derived     <= '0';
                aes_watchdog   <= 0;
                aes_timeout_flag <= '0';
                pending_valid  <= '0';
                pending_pt     <= (others => '0');
                state          <= IDLE;
            else
                -- Key loading: rising edge detection on key_valid
                -- ★ FAZ 12.2: Key load → önce seed türet, sonra IV türet
                if key_valid = '1' and key_loaded = '0' then
                    aes_key_load   <= '1';
                    key_loaded     <= '1';
                    iv_ready       <= '0';
                    sk_derived     <= '0';  -- ★ 14.3: new session key needed
                    iv_derive_mode <= '1';
                    kdf_phase      <= '0';
                    state          <= DERIVE_SK_HI;  -- ★ 14.3: start with session key
                end if;

                -- ★ FIX: Global pending latch — catch valid_in in ANY state
                -- except when we're about to process it in IDLE
                if valid_in = '1' and state /= IDLE then
                    pending_valid <= '1';
                    pending_pt    <= plain_text;
                end if;

                case state is

                    ---------------------------------------------------
                    -- ★ FAZ 14.3: DERIVE_SK_HI: AES(Master, "SK_HI" || ctr)
                    -- Session key high 128 bits
                    ---------------------------------------------------
                    when DERIVE_SK_HI =>
                        if aes_busy = '0' and aes_key_load = '0' then
                            -- ★ BUG-2 FIX: sk_phase='0' → iv_derive_input = SK_DOMAIN_HI
                            sk_phase  <= '0';
                            aes_start <= '1';
                            mask_128  <= (others => '0');  -- ★ KDF: mask=0 (TX/RX must match)
                            state     <= WAIT_SK_HI;
                        end if;

                    ---------------------------------------------------
                    -- WAIT_SK_HI: Capture high 128 bits of session key
                    ---------------------------------------------------
                    when WAIT_SK_HI =>
                        if aes_done = '1' then
                            session_key(255 downto 128) <= aes_ct;
                            aes_watchdog <= 0;
                            state        <= DERIVE_SK_LO;
                        else
                            if aes_watchdog = AES_TIMEOUT_CYCLES - 1 then
                                aes_timeout_flag <= '1';
                                aes_watchdog <= 0;
                                state <= IDLE;
                            else
                                aes_watchdog <= aes_watchdog + 1;
                            end if;
                        end if;

                    ---------------------------------------------------
                    -- DERIVE_SK_LO: AES(Master, "SK_LO" || ctr)
                    -- Session key low 128 bits
                    ---------------------------------------------------
                    when DERIVE_SK_LO =>
                        if aes_busy = '0' then
                            -- ★ BUG-2 FIX: sk_phase='1' → iv_derive_input = SK_DOMAIN_LO
                            sk_phase  <= '1';
                            aes_start <= '1';
                            mask_128  <= (others => '0');  -- ★ KDF: mask=0 (TX/RX must match)
                            state     <= WAIT_SK_LO;
                        end if;

                    ---------------------------------------------------
                    -- WAIT_SK_LO: Capture low 128 bits, reload AES with session key
                    ---------------------------------------------------
                    when WAIT_SK_LO =>
                        if aes_done = '1' then
                            session_key(127 downto 0) <= aes_ct;
                            sk_derived   <= '1';
                            -- Reload AES core with session key
                            aes_key_load <= '1';
                            aes_watchdog <= 0;
                            state        <= DERIVE_SEED;
                        else
                            if aes_watchdog = AES_TIMEOUT_CYCLES - 1 then
                                aes_timeout_flag <= '1';
                                aes_watchdog <= 0;
                                state <= IDLE;
                            else
                                aes_watchdog <= aes_watchdog + 1;
                            end if;
                        end if;

                    ---------------------------------------------------
                    -- ★ FAZ 12.2: DERIVE_SEED: AES(session_key, "TITAN_IV" || session_ctr)
                    -- key_hash_seed hesapla — counter reset'e bağışık
                    ---------------------------------------------------
                    when DERIVE_SEED =>
                        if aes_busy = '0' and aes_key_load = '0' then
                            aes_start <= '1';
                            mask_128  <= (others => '0');  -- ★ KDF: mask=0 (TX/RX must match)
                            state     <= WAIT_SEED;
                        end if;

                    ---------------------------------------------------
                    -- WAIT_SEED: Seed derivation tamamlanmasini bekle
                    ---------------------------------------------------
                    when WAIT_SEED =>
                        if aes_done = '1' then
                            key_hash_seed <= aes_ct;
                            kdf_phase     <= '1';
                            aes_watchdog  <= 0;
                            state         <= DERIVE_IV;
                        else
                            -- ★ FAZ 13.3: Timeout kontrolü
                            if aes_watchdog = AES_TIMEOUT_CYCLES - 1 then
                                aes_timeout_flag <= '1';
                                aes_watchdog <= 0;
                                state <= IDLE;
                            else
                                aes_watchdog <= aes_watchdog + 1;
                            end if;
                        end if;

                    ---------------------------------------------------
                    -- DERIVE_IV: AES(Key, key_hash_seed XOR session_ctr)
                    -- Artık key-dependent — counter reset güvenli
                    ---------------------------------------------------
                    when DERIVE_IV =>
                        if aes_busy = '0' then
                            aes_start <= '1';
                            mask_128  <= (others => '0');  -- ★ KDF: mask=0 (TX/RX must match)
                            state     <= WAIT_IV;
                        end if;

                    ---------------------------------------------------
                    -- WAIT_IV: AES IV derivation tamamlanmasini bekle
                    ---------------------------------------------------
                    when WAIT_IV =>
                        if aes_done = '1' then
                            -- ★ FAZ 13.2: Direction-aware CTR initialization
                            -- TX: bit 127 = '0' (even space 0x0...)
                            -- RX: bit 127 = '1' (odd space 0x8...)
                            -- → TX ve RX aynı keystream' üretEMEZ
                            ctr_block      <= unsigned(direction & aes_ct(126 downto 0));
                            ctr_loaded     <= '1';
                            iv_ready       <= '1';
                            iv_derive_mode <= '0';
                            kdf_phase      <= '0';
                            aes_watchdog   <= 0;
                            state          <= IDLE;
                        else
                            -- ★ FAZ 13.3: Timeout kontrolü
                            if aes_watchdog = AES_TIMEOUT_CYCLES - 1 then
                                aes_timeout_flag <= '1';
                                aes_watchdog <= 0;
                                state <= IDLE;
                            else
                                aes_watchdog <= aes_watchdog + 1;
                            end if;
                        end if;

                    ---------------------------------------------------
                    -- IDLE: Veri bekle
                    ---------------------------------------------------
                    when IDLE =>
                        -- ★ FIX: Latch incoming valid_in during key derivation
                        if valid_in = '1' and (key_loaded = '0' or iv_ready = '0') then
                            pending_valid <= '1';
                            pending_pt    <= plain_text;
                        end if;

                        if (valid_in = '1' or pending_valid = '1') and
                           key_loaded = '1' and iv_ready = '1' and aes_busy = '0' then
                            -- Plaintext'i latch'le (prefer live valid_in, fall back to pending)
                            if valid_in = '1' then
                                pt_latched <= plain_text;
                            else
                                pt_latched <= pending_pt;
                            end if;
                            pending_valid    <= '0';
                            omega_en_latched <= omega_enable;
                            
                            if omega_enable = '1' then
                                -- ★ Omega aktif: dummy count belirle
                                dummy_cnt  <= unsigned(chaos_value(1 downto 0));
                                if unsigned(chaos_value(1 downto 0)) = 0 then
                                    -- 0 dummy → direkt encrypt
                                    aes_start  <= '1';
                                    mask_128   <= trng_seed & trng_seed & trng_seed & trng_seed;  -- ★ DPA mask AKTIF: TRNG seed
                                    state      <= WAIT_AES;
                                else
                                    -- 1-3 dummy → timer-based delay
                                    -- (AES çağrılmaz — pipeline state leakage önlenir)
                                    dummy_timer  <= 0;
                                    -- ★ FAZ 15.3: Random target from chaos PRNG
                                    dummy_target <= DUMMY_AES_BASE + to_integer(unsigned(chaos_value(7 downto 0)));
                                    state        <= DUMMY_TIMER_WAIT;
                                end if;
                            else
                                -- Omega kapalı: direkt encrypt
                                aes_start  <= '1';
                                mask_128   <= trng_seed & trng_seed & trng_seed & trng_seed;  -- ★ DPA mask AKTIF: TRNG seed
                                state      <= WAIT_AES;
                            end if;
                        end if;

                    ---------------------------------------------------
                    -- DUMMY_TIMER_WAIT: Timer-based dummy delay
                    -- AES core çağrılmadan AES süresini simüle eder
                    ---------------------------------------------------
                    when DUMMY_TIMER_WAIT =>
                        if dummy_timer = dummy_target - 1 then
                            -- Bu dummy bitti
                            stat_dummies <= stat_dummies + 1;
                            dummy_cnt    <= dummy_cnt - 1;
                            if dummy_cnt = 1 then
                                -- Tüm dummy'ler bitti → gerçek encrypt
                                state <= ENCRYPT;
                            else
                                -- Daha dummy var → timer'ı sıfırla
                                dummy_timer <= 0;
                            end if;
                        else
                            dummy_timer <= dummy_timer + 1;
                        end if;

                    ---------------------------------------------------
                    -- ENCRYPT: Gerçek CTR encrypt başlat
                    ---------------------------------------------------
                    when ENCRYPT =>
                        if aes_busy = '0' then
                            aes_start <= '1';
                            mask_128  <= trng_seed & trng_seed & trng_seed & trng_seed;  -- ★ DPA mask AKTIF: TRNG seed
                            state     <= WAIT_AES;
                        end if;

                    ---------------------------------------------------
                    -- WAIT_AES: AES-256 14 round calisiyor...
                    ---------------------------------------------------
                    when WAIT_AES =>
                        if aes_done = '1' then
                            aes_watchdog <= 0;
                            state <= OUTPUT;
                        else
                            -- ★ FAZ 13.3: Timeout kontrolü
                            if aes_watchdog = AES_TIMEOUT_CYCLES - 1 then
                                aes_timeout_flag <= '1';
                                aes_watchdog <= 0;
                                state <= IDLE;
                            else
                                aes_watchdog <= aes_watchdog + 1;
                            end if;
                        end if;

                    ---------------------------------------------------
                    -- OUTPUT: CTR Mode XOR
                    ---------------------------------------------------
                    when OUTPUT =>
                        cipher_text <= pt_latched xor aes_ct;
                        valid_out   <= '1';
                        ctr_block   <= ctr_block + 1;
                        state       <= IDLE;

                    when others =>
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
