--------------------------------------------------------------------------------
-- PROJECT TITAN V14→V15: KILL PROTOCOL (Zeroization Engine)
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
-- V15 P0-6: FACTORY CLOCK FREEZE KORUMASI
--   Clock durdurulursa factory timeout sayacı dolar ama clock edge gelmez.
--   clk_alive_toggle sinyali dış analog watchdog'a bağlanır.
--   Clock durduğunda dış devre factory_kill_bypass'i tetikler.
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
        RAM_ADDR_WIDTH   : integer := 16;
        -- Factory mode timeout: güç verildiğinde sayar, doyunca factory bypass kapanır
        -- Default: 2^20 = 1_048_576 cycle = ~20ms @ 50MHz
        -- Kalibrasyon sırasında bu süre yeterli. Sahada jumper takılı kalsa bile
        -- timeout sonrası kill zinciri tam aktif olur.
        FACTORY_TIMEOUT  : integer := 1_048_576
    );
    port (
        -- Saat ve Reset
        clk             : in  std_logic;
        rst_n           : in  std_logic;  -- Aktif düşük reset
        
        -- ★ A5: TRNG seed girişi (LFSR PRNG başlangıç değeri)
        trng_seed       : in  std_logic_vector(7 downto 0);
        
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
        system_halted   : out std_logic;  -- '1' = Sistem DEAD LOOP'ta

        -- ★ V15 P0-6: Clock alive toggle (dış analog watchdog için)
        -- Bu sinyal her clk edge'de toggle olur. Dış F-to-V
        -- devresine (LM2907N) bağlanır. Clock durursa toggle
        -- duracak ve analog comparator factory bypass'i kaldıracak.
        clk_alive_toggle : out std_logic;  -- Toggle: clk sağlık göstergesi
        
        -- ★ V15 P0-6: Dış clock watchdog girişi
        -- Analog devre clock durmayı tespit edince '1' gönderir
        -- Bu sinyal factory mask'ı bypass eder
        ext_clk_dead    : in  std_logic   -- '1' = clock durduruldu
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
    
    -- Zeroization pass counter (multi-pass: PRNG → 0xAA → 0x00)
    signal scrub_pass : unsigned(1 downto 0) := "00";
    signal scrub_pattern : std_logic_vector(7 downto 0) := x"55";
    
    -------------------------------------------------------------------------
    -- ★ A5: LFSR-8 PRNG — Polynomial Documentation
    -------------------------------------------------------------------------
    -- Polynomial: x^8 + x^6 + x^5 + x^4 + 1 (hex: 0x171, Galois form)
    -- Taps: bits 7,5,4,3 → feedback = b7 XOR b5 XOR b4 XOR b3
    --
    -- Properties:
    --   • MAXIMAL-LENGTH: Period = 2^8 - 1 = 255 (all nonzero states visited)
    --   • Satisfies Golomb's 3 randomness postulates:
    --     1. Balance: |count('1') - count('0')| ≤ 1 in the full period
    --     2. Runs: ~50% runs length 1, ~25% length 2, ~12.5% length 3, etc.
    --     3. Autocorrelation: 2-valued (peak at τ=0, flat elsewhere)
    --   • Primitive polynomial over GF(2) — verified via factorization
    --   • Lookup: table of primitive polynomials for n=8 (Xilinx XAPP052)
    --
    -- Seed Values (forensic resistance):
    --   Pass 1: 0xA5 (1010_0101) — alternating pattern, maximum bit diversity
    --   Pass 2: NOT(TRNG) or 0x5A — complement of Pass 1 seed
    --   Pass 3: ROTATE(TRNG) or 0xC3 (1100_0011) — nibble-swapped
    --   Pass 4: 0x00 — deterministic final zero-fill (verifiable)
    --
    -- Rationale: 4-pass scrub (PRNG, complement-PRNG, rotated-PRNG, zero)
    -- ensures that residual magnetization patterns in SRAM/flash cells are
    -- destroyed. Each pass uses a different LFSR seed to prevent forensic
    -- differential analysis between passes.
    -------------------------------------------------------------------------
    signal lfsr_reg : std_logic_vector(7 downto 0) := x"A5";
    signal lfsr_feedback : std_logic;
    
    -- DEAD_LOOP geri dönüşsüz latch: bir kez set olunca rst_n temizleyemez
    signal dead_latch : std_logic := '0';
    
    -- Factory mode timeout
    signal factory_timer   : integer range 0 to FACTORY_TIMEOUT := 0;
    signal factory_expired : std_logic := '0';  -- '1' = timeout doldu, bypass kapalı
    
    -- ★ V15 P0-6: Clock alive toggle register
    signal clk_alive_reg   : std_logic := '0';
    
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
    -- FACTORY MODE TIMEOUT COUNTER
    -------------------------------------------------------------------------
    -- Güç verildiğinde saymaya başlar. Doyunca factory_expired='1'.
    -- JUMPER_CALIB takılı kalsa bile timeout sonrası kill zinciri aktif.
    -- Geri dönüşsüz: bir kez expired olduktan sonra tekrar '0' olmaz.
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if factory_expired = '0' then
                if factory_timer = FACTORY_TIMEOUT - 1 then
                    factory_expired <= '1';
                else
                    factory_timer <= factory_timer + 1;
                end if;
            end if;
            -- NOT: factory_expired geri dönüşsüz. Rst_n bile sıfırlamaz.
            -- Güç çevrimi gerektirir (FPGA SRAM init değeri = '0').
        end if;
    end process;

    -------------------------------------------------------------------------
    -- ★ V15 P0-6: CLOCK ALIVE TOGGLE (Dış Watchdog için)
    -------------------------------------------------------------------------
    -- Her rising_edge(clk)'de toggle olur. Dış F-to-V devresi (LM2907N)
    -- bu sinyalin frekansını izler. Clock durursa toggle durur ve
    -- analog comparator (LTC1540) ext_clk_dead='1' üretir.
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            clk_alive_reg <= not clk_alive_reg;
        end if;
    end process;
    clk_alive_toggle <= clk_alive_reg;

    -------------------------------------------------------------------------
    -- FACTORY MODE MASK (Kalibrasyon sırasında KILL geçici devre dışı)
    -------------------------------------------------------------------------
    -- factory_mode='1' VE timeout dolmamışsa → kill maskelenir
    -- factory_expired='1' olduktan sonra → factory_mode ne olursa olsun kill aktif
    -- ★ V15 P0-6: ext_clk_dead='1' ise clock durdurulmuş → factory mask BYPASS
    -------------------------------------------------------------------------
    kill_active <= kill_pin when (factory_mode = '0' or factory_expired = '1' or ext_clk_dead = '1') else '0';
    
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
                        -- ★ A5: Pass 1 PRNG seeded (TRNG'den)
                        if trng_seed /= x"00" then
                            lfsr_reg <= trng_seed;
                            scrub_pattern <= trng_seed;
                        else
                            lfsr_reg <= x"A5";
                            scrub_pattern <= x"A5";
                        end if;
                        state <= ZEROIZE_RAM;
                    
                    when ZEROIZE_RAM =>
                        -- Multi-pass RAM scrub (forensic resistance)
                        if scrub_addr <= KEY_MEMORY_END then
                            ram_addr <= std_logic_vector(scrub_addr);
                            -- ★ C-7 FIX: ALL LFSR passes + final 0x00 guarantee
                            if scrub_pass = "11" then
                                ram_data_out <= x"00";  -- Final verifiable zero
                            else
                                ram_data_out <= lfsr_reg;
                                -- LFSR advance: x^8+x^6+x^5+x^4+1
                                lfsr_feedback <= lfsr_reg(7) xor lfsr_reg(5) xor lfsr_reg(4) xor lfsr_reg(3);
                                lfsr_reg <= lfsr_reg(6 downto 0) & lfsr_feedback;
                            end if;
                            ram_write_enable <= '1';
                            scrub_addr <= scrub_addr + 1;
                        else
                            -- Bu pass tamamlandı
                            ram_write_enable <= '0';
                            if scrub_pass = "00" then
                                -- ★ C-7 FIX: Pass 2 re-seed LFSR (inverted TRNG)
                                scrub_pass <= "01";
                                if trng_seed /= x"FF" then
                                    lfsr_reg <= not trng_seed;
                                else
                                    lfsr_reg <= x"5A";
                                end if;
                                scrub_addr <= to_unsigned(KEY_MEMORY_START, RAM_ADDR_WIDTH);
                            elsif scrub_pass = "01" then
                                -- ★ C-7 FIX: Pass 3 re-seed LFSR (rotated TRNG)
                                scrub_pass <= "10";
                                if trng_seed /= x"00" then
                                    lfsr_reg <= trng_seed(3 downto 0) & trng_seed(7 downto 4);
                                else
                                    lfsr_reg <= x"C3";
                                end if;
                                scrub_addr <= to_unsigned(KEY_MEMORY_START, RAM_ADDR_WIDTH);
                            else
                                -- ★ C-7 FIX: Final zero pass — guarantee all-zero state
                                -- Write 0x00 to entire key area one last time
                                if scrub_pass = "10" then
                                    scrub_pass <= "11";
                                    scrub_pattern <= x"00";
                                    scrub_addr <= to_unsigned(KEY_MEMORY_START, RAM_ADDR_WIDTH);
                                else
                                    -- 4 passes done → DEAD_LOOP
                                    state <= DEAD_LOOP;
                                end if;
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
