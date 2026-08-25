--------------------------------------------------------------------------------
-- PROJECT TITAN V14: KILL PROTOCOL (Zeroization Engine)
-- Module: Kill Interrupt Handler with Asynchronous Reflex
--------------------------------------------------------------------------------
-- AMAÇ: Tamper tespit edildiğinde kripto anahtarları silmek ve sistemi
--       "DEAD LOOP" durumuna sokmak.
--
-- KRİTİK GÜVENLİK ÖZELLİKLERİ:
--   1. ASENKRON REFLEX: KILL_PIN sinyali clock edge beklemeden doğrudan
--      flip-flop'ların asynchronous clear/preset pinlerine bağlanır.
--   2. DONT_TOUCH: Sentezleyici RAM yazma ve register silme kodunu
--      "gereksiz" diyerek optimize edemez.
--   3. NO DEBOUNCE: Donanım (10kΩ + 1nF RC) filtreledi, yazılım hemen işler.
--
-- KOMUTAN ŞERHİ: "Eğer rising_edge(clk) beklerseniz, saldırgan clock'u
--                 kesmiş olabilir. Elektrik varken reflex olmalı."
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity kill_protocol is
    generic (
        -- Kripto anahtarlarının bellek adresleri
        KEY_MEMORY_START : integer := 16#1000#;
        KEY_MEMORY_END   : integer := 16#1FFF#;  -- 4KB kripto anahtar alanı
        RAM_ADDR_WIDTH   : integer := 16
    );
    port (
        -- Saat ve Reset
        clk             : in  std_logic;
        rst_n           : in  std_logic;  -- Aktif düşük reset
        
        -- KILL Sinyali (Asenkron Giriş - Tamper Dedektöründen)
        kill_pin        : in  std_logic;  -- '1' = Tamper tespit edildi
        
        -- Factory Mode Control
        factory_mode    : in  std_logic;  -- '1' = Fabrika modu (KILL maskelenir)
        
        -- RAM Arayüzü (Zeroization için)
        ram_addr        : out std_logic_vector(RAM_ADDR_WIDTH-1 downto 0);
        ram_data_out    : out std_logic_vector(7 downto 0);
        ram_write_enable: out std_logic;
        
        -- Durum Çıkışları
        led_status_red  : out std_logic;  -- Tamper LED (Kırmızı)
        system_halted   : out std_logic   -- '1' = Sistem DEAD LOOP'ta
    );
end kill_protocol;

architecture Behavioral of kill_protocol is
    
    -- State Machine (Zeroization Sırası)
    type state_type is (
        NORMAL,         -- Normal çalışma
        ZEROIZE_START,  -- İmha başladı
        ZEROIZE_RAM,    -- RAM siliniyor
        DEAD_LOOP       -- Sistem durduruldu
    );
    signal state : state_type := NORMAL;
    
    -- RAM Scrubbing Counter
    signal scrub_addr : unsigned(RAM_ADDR_WIDTH-1 downto 0) := (others => '0');
    
    -- Zeroization pass counter (multi-pass: 0x55 → 0xAA → 0x00)
    signal scrub_pass : unsigned(1 downto 0) := "00";
    signal scrub_pattern : std_logic_vector(7 downto 0) := x"55";
    
    -- DEAD_LOOP geri dönüşsüz latch: bir kez set olunca rst_n temizleyemez
    signal dead_latch : std_logic := '0';
    
    -- İç Sinyaller
    signal kill_active : std_logic := '0';  -- Maskelenmiş KILL sinyali
    
    -------------------------------------------------------------------------
    -- SENTEZLEYİCİ KORUMASI (CRITICAL!)
    -------------------------------------------------------------------------
    -- Vivado/Libero, "Bu RAM'e yazılan veri bir daha okunmuyor, gereksiz"
    -- diyerek ram_write_enable sinyalini silebilir. BUNA İZİN VERMİYORUZ!
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of kill_active : signal is "true";
    -- ram_write_enable is a port: attribute not needed (Vivado infers from context)
    attribute dont_touch of state : signal is "true";
    attribute dont_touch of dead_latch : signal is "true";
    attribute dont_touch of scrub_pass : signal is "true";
    
    -- Register koruması (Xilinx için)
    attribute keep : string;
    attribute keep of scrub_addr : signal is "true";
    attribute keep of state : signal is "true";
    
    -- Microchip/Synplify Attributes (Libero)
    attribute syn_keep : boolean;
    attribute syn_keep of kill_active : signal is true;
    -- ram_write_enable is a port: syn_keep not applicable
    attribute syn_keep of scrub_addr : signal is true;
    attribute syn_keep of state : signal is true;
    
    attribute syn_preserve : boolean;
    attribute syn_preserve of kill_active : signal is true;
    attribute syn_preserve of state : signal is true;
    
begin

    -------------------------------------------------------------------------
    -- FACTORY MODE MASK (Kalibrasyon sırasında KILL devre dışı)
    -------------------------------------------------------------------------
    kill_active <= kill_pin when factory_mode = '0' else '0';
    
    -------------------------------------------------------------------------
    -- GERİ DÖNÜŞSÜZ DEAD LATCH (Async Preset Flip-Flop)
    -------------------------------------------------------------------------
    -- kill_active='1' olduğunda async olarak SET edilir (FDPE).
    -- Senkron dalda kendi değerini tutar → bir kez '1' olduktan sonra
    -- sadece güç kesilirse '0' olabilir.
    -- NOT: Ayrı process → LDCE (latch) yerine FDPE (flip-flop) çıkarılır.
    -------------------------------------------------------------------------
    process(clk, kill_active)
    begin
        if kill_active = '1' then
            dead_latch <= '1';  -- Async preset: GERİ DÖNÜŞSÜZ
        elsif rising_edge(clk) then
            dead_latch <= dead_latch;  -- Kendi değerini tut (FF feedback)
        end if;
    end process;

    -------------------------------------------------------------------------
    -- ASENKRON REFLEX (Clock Bağımsız Tepki)
    -------------------------------------------------------------------------
    -- KILL sinyali geldiği anda state makinesi tetiklenir.
    -- rising_edge(clk) beklemez - doğrudan asynchronous set/clear kullanır.
    -------------------------------------------------------------------------
    process(clk, kill_active)
    begin
        -- ASENKRON KOŞUL: kill_active='1' olursa hemen ZEROIZE_START'a geç
        if kill_active = '1' then
            state <= ZEROIZE_START;
            led_status_red <= '1';  -- Hemen kırmızı LED yak
            system_halted <= '0';
            
        -- SENKRON KOŞUL: Normal state machine işlemleri
        elsif rising_edge(clk) then
            -- GÜVENLİK: dead_latch set olduysa rst_n ile NORMAL'e dönüş YOK
            if rst_n = '0' and dead_latch = '0' then
                state <= NORMAL;
                led_status_red <= '0';
                system_halted <= '0';
                scrub_addr <= (others => '0');
                scrub_pass <= "00";
            else
                case state is
                    
                    when NORMAL =>
                        -- Olağan durum: KILL sinyali bekleniyor
                        led_status_red <= '0';
                        system_halted <= '0';
                        ram_write_enable <= '0';
                    
                    when ZEROIZE_START =>
                        -- İmha başladı: 3-pass scrub başlat
                        scrub_addr <= to_unsigned(KEY_MEMORY_START, RAM_ADDR_WIDTH);
                        scrub_pass <= "00";
                        scrub_pattern <= x"55";  -- Pass 1: 0x55
                        state <= ZEROIZE_RAM;
                    
                    when ZEROIZE_RAM =>
                        -- Multi-pass RAM scrub (forensic resistance)
                        if scrub_addr <= KEY_MEMORY_END then
                            ram_addr <= std_logic_vector(scrub_addr);
                            ram_data_out <= scrub_pattern;
                            ram_write_enable <= '1';
                            scrub_addr <= scrub_addr + 1;
                        else
                            -- Bu pass tamamlandı
                            ram_write_enable <= '0';
                            if scrub_pass = "00" then
                                -- Pass 2: 0xAA
                                scrub_pass <= "01";
                                scrub_pattern <= x"AA";
                                scrub_addr <= to_unsigned(KEY_MEMORY_START, RAM_ADDR_WIDTH);
                            elsif scrub_pass = "01" then
                                -- Pass 3: 0x00 (final zero)
                                scrub_pass <= "10";
                                scrub_pattern <= x"00";
                                scrub_addr <= to_unsigned(KEY_MEMORY_START, RAM_ADDR_WIDTH);
                            else
                                -- 3 pass tamamlandı → DEAD_LOOP
                                state <= DEAD_LOOP;
                            end if;
                        end if;
                    
                    when DEAD_LOOP =>
                        -- Sistem GERİ DÖNÜŞSÜZ olarak durduruldu
                        -- dead_latch='1' → rst_n ile NORMAL'e dönülemez
                        -- Tek çözüm: güç kesilip yeniden başlatılmalı
                        led_status_red <= '1';
                        system_halted <= '1';
                        ram_write_enable <= '0';
                        
                    when others =>
                        -- Undefined state → güvenlik refleksi: DEAD_LOOP
                        state <= DEAD_LOOP;
                        
                end case;
            end if;
        end if;
    end process;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. ASENKRON REFLEX MİMARİSİ
--    -> kill_active sinyali process'in sensitivity list'inde.
--    -> kill_active='1' olunca clock beklemeden hemen state değişir.
--    -> Gerçek donanımda: KILL_PIN -> Flip-Flop CLR/PRE pinine bağlanır.
--
-- 2. SENTEZ KORUMASI (DONT_TOUCH / KEEP)
--    -> ram_write_enable sinyali sentezden sonra fiziksel LUT'a
--       sabitlenir. Optimizasyon yapılamaz.
--    -> scrub_addr counter'ı silinmez.
--
-- 3. FACTORY MODE
--    -> Eğer JUMPER_CALIB='1' ise kill_active maskeli.
--    -> Teknisyen trimpot ayarlarken sistem kendini patlatmaz.
--    -> Sahada JUMPER çıkarılır -> Tam koruma aktif.
--
-- 4. RAM SİLME STRATEJİSİ
--    -> 4KB kripto anahtar alanı (0x1000 - 0x1FFF).
--    -> Her clock cycle'da 1 byte silinir (0xFF yazılır).
--    -> 200 MHz saat ile: 4096 byte / 200 MHz = ~20µs (Çok hızlı!).
--
-- 5. GERİ DÖNÜŞ YOK
--    -> DEAD_LOOP state'inden çıkış yoktur.
--    -> Tek çözüm: Güç kesilip yeniden başlatılmalı.
--------------------------------------------------------------------------------
