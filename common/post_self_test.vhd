--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Power-On Self-Test (FIPS 140-3 Compliance)
-- Module: AES-256 Known Answer Test (KAT) + TRNG Repetition Test
--------------------------------------------------------------------------------
-- BOOT SEQUENCE:
--   PLL lock → Warmup → POST begins → AES KAT → PASS/FAIL
--
-- Eğer self-test FAIL ederse:
--   → post_pass = '0' (kalıcı)
--   → system_supervisor SYSTEM_ACTIVE'e geçemez
--   → pipeline tamamen kilitli
--   → Cihaz KULLANILMAZ (LED kırmızı yanar)
--
-- KAT Modülü kendi dahili AES-256 instance'ını kullanır:
--   → Ana pipeline ile çakışma yok
--   → Boot sırasında bağımsız test
--   → Test sonrası AES idle (kaynak waste minimal)
--
-- NIST AES-256 Test Vector (FIPS 197, Appendix C.3):
--   Key:        000102030405060708090a0b0c0d0e0f
--               101112131415161718191a1b1c1d1e1f
--   Plaintext:  00112233445566778899aabbccddeeff
--   Ciphertext: 8ea2b7ca516745bfeafc49904b496089
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity post_self_test is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;   -- Active-low reset

        -- POST Sonuçları
        post_pass    : out std_logic;   -- '1' = TEST GEÇTİ
        post_fail    : out std_logic;   -- '1' = KALICI HATA
        post_running : out std_logic;   -- '1' = Test çalışıyor

        -- TRNG Health (Continuous test)
        trng_data    : in  std_logic_vector(127 downto 0);
        trng_healthy : out std_logic    -- '0' = TRNG repetition fail
    );
end post_self_test;

architecture Behavioral of post_self_test is

    -------------------------------------------------------------------------
    -- NIST AES-256 KAT Vectors (FIPS 197, Appendix C.3)
    -------------------------------------------------------------------------
    constant KAT_KEY : std_logic_vector(255 downto 0) :=
        x"000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F";

    constant KAT_PLAINTEXT : std_logic_vector(127 downto 0) :=
        x"00112233445566778899AABBCCDDEEFF";

    constant KAT_EXPECTED : std_logic_vector(127 downto 0) :=
        x"8EA2B7CA516745BFEAFC49904B496089";

    -------------------------------------------------------------------------
    -- FSM
    -------------------------------------------------------------------------
    type state_type is (
        S_IDLE,          -- Reset sonrası bekle
        S_LOAD_KEY,      -- Test key'i AES'e yükle
        S_WAIT_KEY,      -- Key load settle (1 cycle)
        S_START_AES,     -- Plaintext gönder, şifreleme başlat
        S_WAIT_AES,      -- AES'in bitmesini bekle
        S_COMPARE,       -- Sonucu karşılaştır
        S_PASS,          -- ✅ Test geçti
        S_FAIL           -- ☠️ Test başarısız — kalıcı kilit
    );
    signal state : state_type := S_IDLE;

    -------------------------------------------------------------------------
    -- Dahili AES Core sinyalleri
    -------------------------------------------------------------------------
    signal kat_key_load  : std_logic := '0';
    signal kat_start     : std_logic := '0';
    signal kat_ct        : std_logic_vector(127 downto 0);
    signal kat_done      : std_logic;
    signal kat_busy      : std_logic;
    signal kat_fault     : std_logic;  -- ★ AES fault injection detection

    -------------------------------------------------------------------------
    -- TRNG Continuous Repetition Test
    -------------------------------------------------------------------------
    signal trng_prev     : std_logic_vector(127 downto 0) := (others => '0');
    signal trng_sampled  : std_logic := '0';
    signal trng_rep_fail : std_logic := '0';

    -------------------------------------------------------------------------
    -- Startup delay
    -------------------------------------------------------------------------
    signal startup_cnt : unsigned(7 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- Synthesis protection
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of state : signal is "true";

begin

    -------------------------------------------------------------------------
    -- DAHİLİ AES-256 CORE (Sadece KAT için — boot sonrası idle)
    -------------------------------------------------------------------------
    kat_aes_inst : entity work.aes256_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => '0',         -- KAT sırasında kill yok
            key_in         => KAT_KEY,
            key_load       => kat_key_load,
            plaintext      => KAT_PLAINTEXT,
            start          => kat_start,
            ciphertext     => kat_ct,
            done           => kat_done,
            busy           => kat_busy,
            fault_detected => kat_fault,   -- ★ Fault injection tespiti
            -- ★ FIX #1: Zero mask for KAT (deterministic output required)
            trng_mask      => (others => '0')
        );

    -------------------------------------------------------------------------
    -- AES Known Answer Test FSM
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state        <= S_IDLE;
                post_pass    <= '0';
                post_fail    <= '0';
                post_running <= '0';
                kat_key_load <= '0';
                kat_start    <= '0';
                startup_cnt  <= (others => '0');
            else
                -- Defaults
                kat_key_load <= '0';
                kat_start    <= '0';

                case state is

                    ----------------------------------------------------------
                    -- IDLE: 64 cycle bekle (metastability settle)
                    ----------------------------------------------------------
                    when S_IDLE =>
                        post_running <= '1';
                        post_pass    <= '0';
                        post_fail    <= '0';
                        if startup_cnt >= 63 then
                            state <= S_LOAD_KEY;
                        else
                            startup_cnt <= startup_cnt + 1;
                        end if;

                    ----------------------------------------------------------
                    -- LOAD KEY: NIST test key'i AES motoruna yükle
                    ----------------------------------------------------------
                    when S_LOAD_KEY =>
                        kat_key_load <= '1';
                        state        <= S_WAIT_KEY;

                    ----------------------------------------------------------
                    -- WAIT KEY: Key load settle (1 cycle)
                    ----------------------------------------------------------
                    when S_WAIT_KEY =>
                        if kat_busy = '0' then
                            state <= S_START_AES;
                        end if;

                    ----------------------------------------------------------
                    -- START AES: Test plaintext ile şifreleme başlat
                    ----------------------------------------------------------
                    when S_START_AES =>
                        if kat_busy = '0' then
                            kat_start <= '1';
                            state     <= S_WAIT_AES;
                        end if;

                    ----------------------------------------------------------
                    -- WAIT AES: Şifrelemenin bitmesini bekle (~30 cycle)
                    ----------------------------------------------------------
                    when S_WAIT_AES =>
                        if kat_done = '1' then
                            state <= S_COMPARE;
                        end if;

                    ----------------------------------------------------------
                    -- COMPARE: Sonucu NIST beklenen değerle karşılaştır
                    ----------------------------------------------------------
                    when S_COMPARE =>
                        if kat_fault = '1' then
                            -- ★ Fault injection saldırısı tespit edildi!
                            state <= S_FAIL;
                        elsif kat_ct = KAT_EXPECTED then
                            state <= S_PASS;
                        else
                            state <= S_FAIL;
                        end if;

                    ----------------------------------------------------------
                    -- PASS: ✅ Test başarılı — sistem açılabilir
                    ----------------------------------------------------------
                    when S_PASS =>
                        post_pass    <= '1';
                        post_fail    <= '0';
                        post_running <= '0';

                    ----------------------------------------------------------
                    -- FAIL: ☠️ KALICI — sistem ASLA açılamaz
                    ----------------------------------------------------------
                    when S_FAIL =>
                        post_pass    <= '0';
                        post_fail    <= '1';
                        post_running <= '0';
                        -- Bu state'ten çıkış YOK (power cycle gerekli)

                    when others =>
                        state <= S_FAIL;

                end case;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- TRNG Continuous Repetition Test (FIPS 140-3 §4.9.2)
    -- Aynı 128-bit değer art arda gelirse → TRNG bozuk
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                trng_prev     <= (others => '0');
                trng_sampled  <= '0';
                trng_rep_fail <= '0';
            else
                if trng_sampled = '0' then
                    trng_prev    <= trng_data;
                    trng_sampled <= '1';
                else
                    if trng_data = trng_prev then
                        trng_rep_fail <= '1';
                    else
                        trng_rep_fail <= '0';
                    end if;
                    trng_prev <= trng_data;
                end if;
            end if;
        end if;
    end process;

    trng_healthy <= not trng_rep_fail;

end Behavioral;
