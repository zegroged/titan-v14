--------------------------------------------------------------------------------
-- PROJECT TITAN V14: HMAC Heartbeat Controller (P3-9)
-- Module: Cryptographic Challenge-Response Heartbeat Authentication
--------------------------------------------------------------------------------
--
-- KİMSEYE GÜVENME:
--   Toggle heartbeat taklit edilebilir. HMAC heartbeat → paylaşılan sır gerekli.
--   Replay saldırısı: monoton artış gösteren counter.
--
-- MİMARİ:
--   [Artix-7 FPGA] ←→ [PolarFire FPGA]
--   1. Artix: Nonce üret (TRNG), counter artır
--   2. Artix: HMAC(key, nonce || counter) hesapla
--   3. Artix: SPI ile PolarFire'a gönder: [nonce(64) || counter(64)]
--   4. PolarFire: Aynı key ile HMAC hesaplar, Artix'e tag gönderir
--   5. Artix: Tag doğrula → heartbeat_valid
--
-- Bu modül Artix-7 tarafıdır.
-- SPI cmd slave'e yeni portlar eklenir:
--   - hmac_challenge_out (128 bit: nonce || counter)
--   - hmac_response_in   (256 bit: PolarFire'dan gelen tag)
--   - hmac_challenge_valid (pulse)
--   - hmac_response_valid  (pulse)
--   - hmac_heartbeat_ok    (doğrulama sonucu)
--
-- TIMING: Her heartbeat ~700 cycle (HMAC computation)
-- INTERVAL: heartbeat_interval timer ile periyodik tetikleme
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity hmac_heartbeat_ctrl is
    generic (
        CLK_FREQ_MHZ       : integer := 50;
        HEARTBEAT_INTERVAL_MS : integer := 500  -- Her 500ms'de bir HMAC heartbeat
    );
    port (
        clk              : in  std_logic;
        rst_n            : in  std_logic;
        kill_signal      : in  std_logic;

        -- Shared key (from key injection system)
        hmac_key         : in  std_logic_vector(255 downto 0);

        -- TRNG arayüzü (nonce için)
        trng_data        : in  std_logic_vector(31 downto 0);
        trng_valid       : in  std_logic;

        -- SPI challenge/response arayüzü
        challenge_out    : out std_logic_vector(127 downto 0);  -- nonce || counter
        challenge_valid  : out std_logic;                        -- challenge hazır
        response_in      : in  std_logic_vector(255 downto 0);  -- PolarFire HMAC tag
        response_valid   : in  std_logic;                        -- tag alındı

        -- Sonuç
        heartbeat_ok     : out std_logic;   -- '1' = son doğrulama başarılı
        heartbeat_fail   : out std_logic;   -- '1' = son doğrulama başarısız
        hmac_busy        : out std_logic;   -- '1' = hesaplama devam ediyor

        -- Toggle heartbeat bypass (mevcut sistem uyumluluğu)
        toggle_hb_in     : in  std_logic;   -- Mevcut GPIO toggle heartbeat
        combined_hb_ok   : out std_logic    -- Toggle AND HMAC her ikisi de OK
    );
end hmac_heartbeat_ctrl;

architecture Behavioral of hmac_heartbeat_ctrl is

    -------------------------------------------------------------------------
    -- FSM
    -------------------------------------------------------------------------
    type hb_state_t is (
        HB_IDLE,           -- Bekleme (periyodik timer)
        HB_RANDOM_WAIT,    -- ★ V14.3 FIX Z2: Rastgele gecikme (DPA kırıcı)
        HB_GET_NONCE,      -- TRNG'den nonce al (2x32 = 64 bit)
        HB_COMPUTE,        -- HMAC(key, nonce||counter) hesapla
        HB_WAIT_HMAC,      -- HMAC sonucu bekle
        HB_SEND_CHALLENGE, -- Challenge'ı SPI'a gönder
        HB_WAIT_RESPONSE,  -- PolarFire cevabını bekle
        HB_VERIFY,         -- Tag karşılaştır
        HB_DONE            -- Sonuç
    );
    signal state : hb_state_t := HB_IDLE;

    -------------------------------------------------------------------------
    -- Timing
    -------------------------------------------------------------------------
    constant INTERVAL_CYCLES : integer := CLK_FREQ_MHZ * 1000 * HEARTBEAT_INTERVAL_MS;
    signal interval_cnt      : integer range 0 to INTERVAL_CYCLES := 0;

    -- Response timeout (same as heartbeat interval)
    constant RESP_TIMEOUT : integer := CLK_FREQ_MHZ * 1000 * HEARTBEAT_INTERVAL_MS;
    signal resp_timer     : integer range 0 to RESP_TIMEOUT := 0;

    -------------------------------------------------------------------------
    -- Crypto state
    -------------------------------------------------------------------------
    signal nonce         : std_logic_vector(63 downto 0) := (others => '0');
    signal counter       : unsigned(63 downto 0) := (others => '0');
    signal nonce_words   : integer range 0 to 1 := 0;
    signal our_tag       : std_logic_vector(255 downto 0) := (others => '0');

    -- ★ V14.3 FIX Z2: Random delay counter (DPA trace alignment kırıcı)
    signal random_delay_cnt : integer range 0 to 511 := 0;

    -------------------------------------------------------------------------
    -- HMAC Core Interface
    -------------------------------------------------------------------------
    signal hmac_start     : std_logic := '0';
    signal hmac_msg       : std_logic_vector(127 downto 0) := (others => '0');
    signal hmac_out       : std_logic_vector(255 downto 0);
    signal hmac_valid     : std_logic;
    signal hmac_busy_int  : std_logic;

    -------------------------------------------------------------------------
    -- Results
    -------------------------------------------------------------------------
    signal hb_ok_reg      : std_logic := '0';
    signal hb_fail_reg    : std_logic := '0';
    signal toggle_ok_sync : std_logic_vector(1 downto 0) := "00";

    -- Sentez koruması
    attribute dont_touch : string;
    attribute dont_touch of counter  : signal is "true";
    attribute dont_touch of nonce    : signal is "true";
    attribute dont_touch of our_tag  : signal is "true";

begin

    heartbeat_ok   <= hb_ok_reg;
    heartbeat_fail <= hb_fail_reg;
    hmac_busy      <= hmac_busy_int;

    -- Toggle heartbeat CDC sync
    process(clk)
    begin
        if rising_edge(clk) then
            toggle_ok_sync <= toggle_ok_sync(0) & toggle_hb_in;
        end if;
    end process;

    -- Combined OK: both toggle and HMAC must be OK
    combined_hb_ok <= hb_ok_reg and toggle_ok_sync(1);

    -------------------------------------------------------------------------
    -- HMAC-SHA256 Core Instance
    -------------------------------------------------------------------------
    hmac_inst : entity work.hmac_sha256
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => kill_signal,
            key_in      => hmac_key,
            msg_in      => hmac_msg,
            start       => hmac_start,
            hmac_out    => hmac_out,
            hmac_valid  => hmac_valid,
            busy        => hmac_busy_int
        );

    -------------------------------------------------------------------------
    -- Main FSM
    -------------------------------------------------------------------------
    process(clk)
        variable compare_xor : std_logic_vector(255 downto 0);
        variable mismatch    : std_logic;
    begin
        if rising_edge(clk) then
            if rst_n = '0' or kill_signal = '1' then
                state           <= HB_IDLE;
                interval_cnt    <= 0;
                resp_timer      <= 0;
                nonce           <= (others => '0');
                counter         <= (others => '0');
                nonce_words     <= 0;
                our_tag         <= (others => '0');
                hb_ok_reg       <= '0';
                hb_fail_reg     <= '0';
                hmac_start      <= '0';
                challenge_valid <= '0';
                challenge_out   <= (others => '0');
            else
                -- Default pulses
                hmac_start      <= '0';
                challenge_valid <= '0';

                case state is
                    -----------------------------------------------------------
                    -- IDLE: Wait for interval timer
                    -----------------------------------------------------------
                    when HB_IDLE =>
                        if interval_cnt >= INTERVAL_CYCLES - 1 then
                            interval_cnt <= 0;
                            state        <= HB_RANDOM_WAIT;  -- ★ V14.3 FIX Z2
                            -- Seed random delay from TRNG (32-287 cycles)
                            random_delay_cnt <= 32 + to_integer(unsigned(trng_data(7 downto 0)));
                            nonce_words  <= 0;
                        else
                            interval_cnt <= interval_cnt + 1;
                        end if;

                    -----------------------------------------------------------
                    -- ★ V14.3 FIX Z2: RANDOM WAIT — DPA trace alignment boz
                    -- TRNG'den alinan 8-bit rastgele deger kadar bekle
                    -- Bu HMAC hesaplama zamanlamasini her seferinde farkli yapar
                    -----------------------------------------------------------
                    when HB_RANDOM_WAIT =>
                        if random_delay_cnt <= 1 then
                            state <= HB_GET_NONCE;
                        else
                            random_delay_cnt <= random_delay_cnt - 1;
                        end if;

                    -----------------------------------------------------------
                    -- GET_NONCE: Read 2x32-bit from TRNG
                    -----------------------------------------------------------
                    when HB_GET_NONCE =>
                        if trng_valid = '1' then
                            if nonce_words = 0 then
                                nonce(63 downto 32) <= trng_data;
                                nonce_words <= 1;
                            else
                                nonce(31 downto 0) <= trng_data;
                                -- Increment monotonic counter
                                counter <= counter + 1;
                                state   <= HB_COMPUTE;
                            end if;
                        end if;

                    -----------------------------------------------------------
                    -- COMPUTE: Start HMAC(key, nonce || counter)
                    -----------------------------------------------------------
                    when HB_COMPUTE =>
                        hmac_msg   <= nonce & std_logic_vector(counter);
                        hmac_start <= '1';
                        state      <= HB_WAIT_HMAC;

                    -----------------------------------------------------------
                    -- WAIT_HMAC: Wait for HMAC result
                    -----------------------------------------------------------
                    when HB_WAIT_HMAC =>
                        if hmac_valid = '1' then
                            our_tag <= hmac_out;
                            state   <= HB_SEND_CHALLENGE;
                        end if;

                    -----------------------------------------------------------
                    -- SEND_CHALLENGE: Send nonce||counter to PolarFire
                    -----------------------------------------------------------
                    when HB_SEND_CHALLENGE =>
                        challenge_out   <= nonce & std_logic_vector(counter);
                        challenge_valid <= '1';
                        resp_timer      <= 0;
                        state           <= HB_WAIT_RESPONSE;

                    -----------------------------------------------------------
                    -- WAIT_RESPONSE: Wait for PolarFire HMAC tag
                    -----------------------------------------------------------
                    when HB_WAIT_RESPONSE =>
                        if response_valid = '1' then
                            state <= HB_VERIFY;
                        elsif resp_timer >= RESP_TIMEOUT - 1 then
                            -- Timeout — PolarFire cevap vermedi
                            hb_fail_reg <= '1';
                            hb_ok_reg   <= '0';
                            state       <= HB_DONE;
                        else
                            resp_timer <= resp_timer + 1;
                        end if;

                    -----------------------------------------------------------
                    -- VERIFY: Constant-time tag comparison
                    -----------------------------------------------------------
                    when HB_VERIFY =>
                        compare_xor := our_tag xor response_in;
                        mismatch := '0';
                        for i in 0 to 255 loop
                            mismatch := mismatch or compare_xor(i);
                        end loop;

                        if mismatch = '0' then
                            hb_ok_reg   <= '1';
                            hb_fail_reg <= '0';
                        else
                            hb_ok_reg   <= '0';
                            hb_fail_reg <= '1';
                        end if;
                        state <= HB_DONE;

                    -----------------------------------------------------------
                    -- DONE: Return to idle
                    -----------------------------------------------------------
                    when HB_DONE =>
                        state <= HB_IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
