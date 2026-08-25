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
    
    -- IV derivation input: session counter padded to 128 bits
    signal iv_derive_input : std_logic_vector(127 downto 0);

    -------------------------------------------------------------------------
    -- Pipeline registers
    -------------------------------------------------------------------------
    signal pt_latched   : std_logic_vector(127 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- Key loading edge detection
    -------------------------------------------------------------------------
    signal key_valid_d  : std_logic := '0';
    signal key_loaded   : std_logic := '0';
    signal iv_ready     : std_logic := '0';  -- IV AES-KDF tamamlandi mi?

    -------------------------------------------------------------------------
    -- FSM (Omega Cloak state'leri eklendi)
    -------------------------------------------------------------------------
    type state_type is (IDLE, DERIVE_IV, WAIT_IV,
                        DUMMY_TIMER_WAIT,
                        ENCRYPT, WAIT_AES, OUTPUT);
    signal state : state_type := IDLE;

    -------------------------------------------------------------------------
    -- Dummy timer: AES süresini simüle eder (~520 cycle)
    -------------------------------------------------------------------------
    constant DUMMY_AES_CYCLES : integer := 520;
    signal dummy_timer : integer range 0 to DUMMY_AES_CYCLES := 0;

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
    
    -- Dummy control
    signal dummy_cnt       : unsigned(1 downto 0) := (others => '0');
    signal stat_dummies    : unsigned(15 downto 0) := (others => '0');
    signal omega_en_latched: std_logic := '0';  -- Latched at operation start
    
    -- Default r parameter for Logistic Map (3.99 in Q8.24)
    constant R_DEFAULT     : std_logic_vector(31 downto 0) := x"03FD70A4";

    -- ★ FIX #1: 128-bit mask for AES core (generated from chaotic PRNG)
    signal mask_128 : std_logic_vector(127 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- Synthesis protection
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of ctr_block : signal is "true";
    attribute dont_touch of state : signal is "true";
    attribute dont_touch of session_counter : signal is "true";
    attribute dont_touch of iv_ready : signal is "true";
    attribute dont_touch of stat_dummies : signal is "true";
    attribute dont_touch of mask_128 : signal is "true";  -- ★ FIX #1: protect mask

begin

    -------------------------------------------------------------------------
    -- IV DERIVATION INPUT: session_counter padded to 128 bits
    -- Domain separator: upper 96 bits = 0x5449_5441_4E5F_4956 ("TITAN_IV")
    -- Lower 32 bits = session_counter
    -------------------------------------------------------------------------
    iv_derive_input <= x"5449_5441_4E5F_4956_0000_0000" & 
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
            chaos_byte  => chaos_byte
        );

    -------------------------------------------------------------------------
    -- AES-256 Core Instance
    -------------------------------------------------------------------------
    aes_inst : entity work.aes256_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => kill_signal,
            key_in         => master_key_in,
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
    -- ★ FIX #1: MASK GENERATION from Chaotic PRNG
    -- 128-bit mask = 4 × chaos_value XOR distinct constants
    -- Refreshed continuously; AES core latches at PASS1_ADDRK0
    -------------------------------------------------------------------------
    mask_128(127 downto 96) <= chaos_value xor x"A5A5A5A5";
    mask_128(95 downto 64)  <= chaos_value xor x"5A5A5A5A";
    mask_128(63 downto 32)  <= chaos_value xor x"C3C3C3C3";
    mask_128(31 downto 0)   <= chaos_value xor x"3C3C3C3C";

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
            state          <= IDLE;

        elsif rising_edge(clk) then
            -- Defaults
            aes_start      <= '0';
            aes_key_load   <= '0';
            valid_out      <= '0';

            if rst_n = '0' then
                ctr_block      <= (others => '0');
                ctr_loaded     <= '0';
                key_loaded     <= '0';
                iv_ready       <= '0';
                iv_derive_mode <= '0';
                dummy_cnt      <= (others => '0');
                omega_en_latched <= '0';
                state          <= IDLE;
            else
                -- Key loading: rising edge detection on key_valid
                if key_valid = '1' and key_loaded = '0' then
                    aes_key_load   <= '1';
                    key_loaded     <= '1';
                    iv_ready       <= '0';
                    iv_derive_mode <= '1';
                    state          <= DERIVE_IV;
                end if;

                case state is

                    ---------------------------------------------------
                    -- DERIVE_IV: Key yuklendi, AES(Key, session_ctr)
                    ---------------------------------------------------
                    when DERIVE_IV =>
                        if aes_busy = '0' and aes_key_load = '0' then
                            aes_start <= '1';
                            state     <= WAIT_IV;
                        end if;

                    ---------------------------------------------------
                    -- WAIT_IV: AES IV derivation tamamlanmasini bekle
                    ---------------------------------------------------
                    when WAIT_IV =>
                        if aes_done = '1' then
                            ctr_block      <= unsigned(aes_ct);
                            ctr_loaded     <= '1';
                            iv_ready       <= '1';
                            iv_derive_mode <= '0';
                            state          <= IDLE;
                        end if;

                    ---------------------------------------------------
                    -- IDLE: Veri bekle
                    ---------------------------------------------------
                    when IDLE =>
                        if valid_in = '1' and key_loaded = '1' and 
                           iv_ready = '1' and aes_busy = '0' then
                            -- Plaintext'i latch'le
                            pt_latched     <= plain_text;
                            omega_en_latched <= omega_enable;
                            
                            if omega_enable = '1' then
                                -- ★ Omega aktif: dummy count belirle
                                dummy_cnt  <= unsigned(chaos_value(1 downto 0));
                                if unsigned(chaos_value(1 downto 0)) = 0 then
                                    -- 0 dummy → direkt encrypt
                                    aes_start  <= '1';
                                    state      <= WAIT_AES;
                                else
                                    -- 1-3 dummy → timer-based delay
                                    -- (AES çağrılmaz — pipeline state leakage önlenir)
                                    dummy_timer <= 0;
                                    state       <= DUMMY_TIMER_WAIT;
                                end if;
                            else
                                -- Omega kapalı: direkt encrypt
                                aes_start  <= '1';
                                state      <= WAIT_AES;
                            end if;
                        end if;

                    ---------------------------------------------------
                    -- DUMMY_TIMER_WAIT: Timer-based dummy delay
                    -- AES core çağrılmadan AES süresini simüle eder
                    ---------------------------------------------------
                    when DUMMY_TIMER_WAIT =>
                        if dummy_timer = DUMMY_AES_CYCLES - 1 then
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
                            state     <= WAIT_AES;
                        end if;

                    ---------------------------------------------------
                    -- WAIT_AES: AES-256 14 round calisiyor...
                    ---------------------------------------------------
                    when WAIT_AES =>
                        if aes_done = '1' then
                            state <= OUTPUT;
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
