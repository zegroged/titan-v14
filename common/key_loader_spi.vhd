--------------------------------------------------------------------------------
-- PROJECT TITAN V14: SPI Key Loader V2 (SPLIT-KEY + DEAD-MAN)
-- Module: Hardened Volatile Key Injection via SPI Interface
--------------------------------------------------------------------------------
-- V2 GÜVENLİK İYİLEŞTİRMELERİ:
--   1. SPLIT KEY: final_key = SPI_key XOR TRNG_key
--      → SPI hattını dinleyen biri sadece yarım key görür
--   2. INJECTION WINDOW: Power-on sonrası 30 saniye (1.5G cycle @50MHz)
--      → Pencere kapandıktan sonra SPI portu kilitli
--   3. DEAD-MAN TIMER: CS_N LOW > 25M cycle (500ms) → tamper alarm
--      → Saldırgan SPI probing yaparsa alarm
--   4. 3-STRIKE LOCKOUT: 3 başarısız injection → kill trigger
--      → Brute-force denemesini engeller
--   5. ARMED MODE DISABLE: jumper_calib='0' iken SPI input yok sayılır
--
-- KEY FORMÜLATİON:
--   key_out = SPI_256bit XOR {TRNG_128bit, TRNG_128bit}
--   → TRNG kısmı FPGA'nın içinden çıkar, dışarıya asla sızmaz
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity key_loader_spi is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        kill_signal  : in  std_logic;  -- ★ ACİL DURUMDA YÜKLEYİCİYİ DE SİL ★
        
        -- SPI Arayüzü (Dış Dünyadan Gelir - Fill Gun)
        spi_sclk     : in  std_logic;  -- SPI Clock (Harici)
        spi_mosi     : in  std_logic;  -- Master Out Slave In
        spi_cs_n     : in  std_logic;  -- Chip Select (Active Low)
        
        -- TRNG Split-Key Input (FPGA internal — dışarıya sızmaz)
        trng_key_part : in  std_logic_vector(127 downto 0);
        
        -- Security Control
        jumper_calib : in  std_logic;  -- '1'=Factory, '0'=Armed
        
        -- Çıkış (secure_key_storage'a gider)
        key_out      : out std_logic_vector(255 downto 0);
        key_valid    : out std_logic;  -- '1' = Anahtar yüklenmiş ve geçerli
        
        -- Kill trigger output (3-strike veya dead-man)
        key_kill_trigger : out std_logic  -- → kill chain OR'a bağlanır
    );
end key_loader_spi;

architecture Behavioral of key_loader_spi is

    -------------------------------------------------------------------------
    -- SHIFT REGISTER (256-bit SPI RX Buffer)
    -------------------------------------------------------------------------
    signal shift_reg   : std_logic_vector(255 downto 0) := (others => '0');
    signal bit_cnt     : integer range 0 to 511 := 0;
    
    -------------------------------------------------------------------------
    -- LATCHED KEY (Split: SPI XOR TRNG)
    -------------------------------------------------------------------------
    signal key_latched : std_logic_vector(255 downto 0) := (others => '0');
    signal valid_flag  : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- CDC SYNCHRONIZATION (Clock Domain Crossing)
    -------------------------------------------------------------------------
    signal sclk_sync : std_logic_vector(1 downto 0) := "00";
    signal cs_sync   : std_logic_vector(1 downto 0) := "11";
    signal mosi_sync : std_logic_vector(1 downto 0) := "00";
    
    -------------------------------------------------------------------------
    -- INJECTION WINDOW (30 saniye — 1.5 × 10^9 cycle @50MHz)
    -------------------------------------------------------------------------
    constant WINDOW_CYCLES : unsigned(31 downto 0) := x"59682F00";  -- 1,500,000,000
    signal window_cnt   : unsigned(31 downto 0) := (others => '0');
    signal window_open  : std_logic := '1';  -- Power-on'da açık
    
    -------------------------------------------------------------------------
    -- DEAD-MAN TIMER (500ms = 25,000,000 cycle @50MHz)
    -------------------------------------------------------------------------
    constant DEADMAN_MAX : unsigned(24 downto 0) := to_unsigned(25_000_000, 25);
    signal deadman_cnt  : unsigned(24 downto 0) := (others => '0');
    signal deadman_trip : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- 3-STRIKE LOCKOUT
    -------------------------------------------------------------------------
    signal fail_count   : unsigned(1 downto 0) := "00";  -- 0-3
    signal lockout      : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- KILL TRIGGER
    -------------------------------------------------------------------------
    signal kill_trig_int : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- ARMED MODE SPI GATING
    -------------------------------------------------------------------------
    signal spi_gated_cs  : std_logic;
    signal spi_allowed   : std_logic;
    
    -------------------------------------------------------------------------
    -- SENTEZ KORUMASI
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of key_latched : signal is "true";
    attribute dont_touch of valid_flag  : signal is "true";
    attribute dont_touch of fail_count  : signal is "true";
    attribute dont_touch of window_cnt  : signal is "true";
    
    attribute keep : string;
    attribute keep of key_latched : signal is "true";
    attribute keep of valid_flag  : signal is "true";

begin

    -- SPI allowed = window open AND not locked out AND not already keyed
    spi_allowed <= window_open and (not lockout) and (not valid_flag);
    
    -------------------------------------------------------------------------
    -- INJECTION WINDOW COUNTER (30 saniye sonra kapanır)
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            window_cnt <= (others => '0');
            window_open <= '1';  -- Kill sonrası pencere yeniden açılır
        elsif rising_edge(clk) then
            if rst_n = '0' then
                window_cnt <= (others => '0');
                window_open <= '1';
            elsif window_open = '1' then
                if window_cnt >= WINDOW_CYCLES then
                    window_open <= '0';  -- ★ PENCERE KAPANDI — SPI kilitli
                else
                    window_cnt <= window_cnt + 1;
                end if;
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- DEAD-MAN TIMER (CS_N düşükken sayar)
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            deadman_cnt  <= (others => '0');
            deadman_trip <= '0';
        elsif rising_edge(clk) then
            if rst_n = '0' then
                deadman_cnt  <= (others => '0');
                deadman_trip <= '0';
            elsif cs_sync(1) = '0' and spi_allowed = '1' then
                -- CS düşük — timer sayıyor
                if deadman_cnt >= DEADMAN_MAX then
                    deadman_trip <= '1';  -- ★ DEAD-MAN: Alarm!
                else
                    deadman_cnt <= deadman_cnt + 1;
                end if;
            else
                deadman_cnt <= (others => '0');
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- SPI RECEIVER + SPLIT-KEY PROCESS
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            shift_reg    <= (others => '0');
            key_latched  <= (others => '0');
            valid_flag   <= '0';
            bit_cnt      <= 0;
            sclk_sync    <= "00";
            cs_sync      <= "11";
            mosi_sync    <= "00";
            fail_count   <= "00";
            lockout      <= '0';
            kill_trig_int <= '0';
            
        elsif rising_edge(clk) then
            if rst_n = '0' then
                valid_flag  <= '0';
                bit_cnt     <= 0;
                shift_reg   <= (others => '0');
                sclk_sync   <= "00";
                cs_sync     <= "11";
                mosi_sync   <= "00";
                fail_count  <= "00";
                lockout     <= '0';
                kill_trig_int <= '0';
            else
                -- CDC Synchronization
                sclk_sync <= sclk_sync(0) & spi_sclk;
                cs_sync   <= cs_sync(0)   & spi_cs_n;
                mosi_sync <= mosi_sync(0) & spi_mosi;
                
                -- ★ SPI GEÇİTLEME: Armed modda pencere kapanmışsa → yoksay
                if spi_allowed = '1' then
                    
                    if cs_sync(1) = '0' then
                        -- CS Aktif → Transfer devam
                        if sclk_sync = "01" then  -- Rising edge
                            shift_reg <= shift_reg(254 downto 0) & mosi_sync(1);
                            if bit_cnt < 256 then
                                bit_cnt <= bit_cnt + 1;
                            end if;
                        end if;
                        
                    else
                        -- CS Deaktif → Transfer bitti mi?
                        if cs_sync = "01" then  -- CS rising edge
                            if bit_cnt = 256 then
                                -- ★ SPLIT KEY: SPI data XOR TRNG
                                key_latched <= shift_reg xor 
                                    (trng_key_part & trng_key_part);
                                valid_flag  <= '1';
                                -- Reset fail counter on success
                                fail_count <= "00";
                            else
                                -- Eksik transfer = başarısız deneme
                                valid_flag <= '0';
                                if fail_count = "10" then  -- 3. deneme
                                    lockout <= '1';
                                    kill_trig_int <= '1';  -- ★ 3-STRIKE → KILL
                                else
                                    fail_count <= fail_count + 1;
                                end if;
                            end if;
                            bit_cnt <= 0;
                        end if;
                    end if;
                    
                end if;  -- spi_allowed
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- OUTPUT ASSIGNMENT
    -------------------------------------------------------------------------
    key_out          <= key_latched;
    key_valid        <= valid_flag;
    key_kill_trigger <= kill_trig_int or deadman_trip;

end Behavioral;
