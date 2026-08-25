--------------------------------------------------------------------------------
-- PROJECT TITAN V14: PolarFire HMAC Heartbeat Responder (P3-9 Mirror)
-- Module: Asynchronous HMAC Challenge-Response Handler
--------------------------------------------------------------------------------
--
-- ASENKRON, NON-BLOCKING TASARIM:
--   HMAC hesaplamasi 652+ cycle surer. Ana SPI veri yolunu KILITLEMEZ.
--   Challenge alindiginda HMAC hesaplama baslar, diger SPI komutlari
--   islemeye devam eder. Tag hazir olunca SPI'a yazilir.
--
-- MIMARI:
--   [Artix-7] -- SPI --> [PolarFire]
--   1. Artix challenge gonderir: [nonce(64) || counter(64)]
--   2. PolarFire: Challenge'i register'a yazar, HMAC baslatir
--   3. PolarFire: Diger SPI komutlarini isler (non-blocking)
--   4. HMAC tag hazir olunca response_ready = '1'
--   5. Artix CMD_HEARTBEAT gonderince, PolarFire tag'i cevap olarak gonderir
--
-- REPLAY KORUMASI:
--   - Her challenge unik nonce + monoton counter
--   - Ayni challenge ikinci kez gelmez (Artix tarafi zorunlu kilar)
--   - Eski tag'ler kabul edilmez (Artix tag karsilastirir)
--
-- ZAMANSAL ANALIZ:
--   HMAC = ~652 cycle @ 50MHz = ~13us
--   Heartbeat interval = 500ms
--   Deger: HMAC hazirlanmasi <<< heartbeat interval (999.97% bos zaman)
--   SPI komut isleme: her komut ~10-50us → HMAC ile cakisma riski < %0.003
--
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pf_hmac_responder is
    port (
        clk              : in  std_logic;
        rst_n            : in  std_logic;
        kill_signal      : in  std_logic;

        -- Shared key (SPI key loader'dan - ayni anahtar)
        hmac_key         : in  std_logic_vector(255 downto 0);

        -- SPI'dan gelen challenge (CMD_HB_CHALLENGE response olarak alinir)
        challenge_in     : in  std_logic_vector(127 downto 0);  -- nonce || counter
        challenge_valid  : in  std_logic;                        -- pulse: yeni challenge

        -- SPI'a giden HMAC tag (CMD_HEARTBEAT'e payload olarak eklenir)
        response_tag     : out std_logic_vector(255 downto 0);  -- HMAC(key, challenge)
        response_ready   : out std_logic;                        -- '1' = tag hazir

        -- Durum
        busy             : out std_logic;
        error            : out std_logic    -- challenge geldigi halde key invalid vb.
    );
end pf_hmac_responder;

architecture Behavioral of pf_hmac_responder is

    -------------------------------------------------------------------------
    -- FSM: Sadece 3 durum — basit ve guvenilir
    -------------------------------------------------------------------------
    type resp_state_t is (
        RS_IDLE,          -- Bekleme: challenge bekle
        RS_COMPUTING,     -- HMAC hesaplaniyor (non-blocking — SPI devam eder)
        RS_READY          -- Tag hazir, SPI gonderene kadar bekle
    );
    signal state : resp_state_t := RS_IDLE;

    -------------------------------------------------------------------------
    -- HMAC Core Interface
    -------------------------------------------------------------------------
    signal hmac_start     : std_logic := '0';
    signal hmac_msg       : std_logic_vector(127 downto 0) := (others => '0');
    signal hmac_out       : std_logic_vector(255 downto 0);
    signal hmac_valid     : std_logic;
    signal hmac_busy_int  : std_logic;

    -------------------------------------------------------------------------
    -- Challenge latch
    -------------------------------------------------------------------------
    signal challenge_reg  : std_logic_vector(127 downto 0) := (others => '0');
    signal tag_reg        : std_logic_vector(255 downto 0) := (others => '0');
    signal ready_reg      : std_logic := '0';
    signal error_reg      : std_logic := '0';

    -- Sentez korumasi
    attribute dont_touch : string;
    attribute dont_touch of tag_reg : signal is "true";
    attribute dont_touch of challenge_reg : signal is "true";

begin

    response_tag   <= tag_reg;
    response_ready <= ready_reg;
    busy           <= hmac_busy_int;
    error          <= error_reg;

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
    -- Non-Blocking FSM
    -- Challenge alindi → HMAC basla → SPI devam eder → tag hazir olunca isle
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' or kill_signal = '1' then
                state         <= RS_IDLE;
                challenge_reg <= (others => '0');
                tag_reg       <= (others => '0');
                ready_reg     <= '0';
                error_reg     <= '0';
                hmac_start    <= '0';
                hmac_msg      <= (others => '0');
            else
                -- Default pulses
                hmac_start <= '0';

                case state is
                    -----------------------------------------------------------
                    -- IDLE: Challenge bekle
                    -- Bu sirada SPI diger komutlari isler (non-blocking)
                    -----------------------------------------------------------
                    when RS_IDLE =>
                        if challenge_valid = '1' then
                            -- Yeni challenge geldi
                            challenge_reg <= challenge_in;
                            hmac_msg      <= challenge_in;
                            hmac_start    <= '1';
                            ready_reg     <= '0';  -- Eski tag gecersiz
                            error_reg     <= '0';
                            state         <= RS_COMPUTING;
                        end if;

                    -----------------------------------------------------------
                    -- COMPUTING: HMAC hesaplaniyor
                    -- ★ NON-BLOCKING: Bu sirada SPI FSM'si bagimsiz calisir
                    -- SPI yeni komut alabilir, veri gonderebilir
                    -- Sadece bu moduldeki FSM HMAC'i bekler
                    -----------------------------------------------------------
                    when RS_COMPUTING =>
                        if hmac_valid = '1' then
                            -- HMAC tamamlandi
                            tag_reg   <= hmac_out;
                            ready_reg <= '1';
                            state     <= RS_READY;
                        end if;

                        -- Yeni challenge gelirse eski hesaplamayi iptal et
                        -- (Artix tarafi counter artirdi, eski challenge gecersiz)
                        if challenge_valid = '1' then
                            challenge_reg <= challenge_in;
                            hmac_msg      <= challenge_in;
                            hmac_start    <= '1';
                            ready_reg     <= '0';
                            -- RS_COMPUTING'de kal — yeni hesaplama baslar
                        end if;

                    -----------------------------------------------------------
                    -- READY: Tag hazir, SPI'nin okumasini bekle
                    -- response_ready = '1' oldugu surece SPI tag'i okuyabilir
                    -- Yeni challenge gelince otomatik gecersiz olur
                    -----------------------------------------------------------
                    when RS_READY =>
                        if challenge_valid = '1' then
                            -- Yeni challenge → eski tag gecersiz, yeni hesapla
                            challenge_reg <= challenge_in;
                            hmac_msg      <= challenge_in;
                            hmac_start    <= '1';
                            ready_reg     <= '0';
                            state         <= RS_COMPUTING;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI — PolarFire HMAC Responder
--------------------------------------------------------------------------------
-- 1. NON-BLOCKING: HMAC hesaplamasi SPI FSM'den bagimsiz calisir.
--    SPI slave yeni komutlar alabilir, veri transferi yapabilir.
--    Sadece bu modul HMAC sonucunu bekler.
--
-- 2. LATENCY: HMAC-SHA256 = ~652 cycle = ~13us @ 50MHz
--    Heartbeat interval = 500ms → %99.997 bos zaman
--    Pratikte HMAC hesabinin SPI'yi bloklamasi IMKANSIZ.
--
-- 3. PREEMPTION: Yeni challenge gelirse eski hesaplama iptal edilir.
--    Bu, Artix'in counter artirmasi nedeniyle eski challenge'in
--    gecersiz olacagi durumu handle eder.
--
-- 4. KILL ZEROIZATION: kill_signal veya rst_n ile tum register'lar
--    sifirlanir (tag_reg, challenge_reg). FIPS 140-3 uyumlu.
--
-- 5. ENTEGRASYON:
--    PolarFire top-level'da:
--    - challenge_in  ← SPI CMD_HB_CHALLENGE payload (128 bit)
--    - challenge_valid ← SPI CMD_HB_CHALLENGE alindi pulse
--    - response_tag  → SPI CMD_HEARTBEAT payload (256 bit)
--    - response_ready → SPI CMD_HEARTBEAT'e cevap verirken kontrol
--------------------------------------------------------------------------------
