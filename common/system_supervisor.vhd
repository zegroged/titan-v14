--------------------------------------------------------------------------------
-- PROJECT TITAN V13: System Supervisor (Emniyet Mandalı)
-- Module: Safe Boot Sequencer - Power-On Metastability Protection
--------------------------------------------------------------------------------
-- AMAÇ: FPGA'ya elektrik verildiğinde (Power-On) meydana gelen voltaj
--       dalgalanmaları ve PLL kilitleme süresinde, KILL mekanizmasının
--       yanlışlıkla tetiklenmesini önlemek.
--
-- KOMUTAN ŞERHİ: "Bir sistemin en savunmasız anı, uyandığı andır. PLL
--                 kilitlenmeden ve voltaj oturmadan KILL'e izin verme!"
--
-- GÜVENLİK STRATEJİSİ:
--   1. PLL LOCKED='0' -> Sistem RESET modunda (KILL devre dışı)
--   2. PLL LOCKED='1' -> 100ms warmup timer başlat (voltaj ısınması)
--   3. Timer bitti -> system_ready='1' (KILL artık güvenle çalışabilir)
--   4. PLL unlock olursa -> BAŞ A DÖN (Fail-Safe)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity system_supervisor is
    generic (
        CLK_FREQ_MHZ : integer := 50;   -- Sistem saati frekansı (MHz)
        STARTUP_MS   : integer := 100   -- Güvenli  bekleme süresi (ms)
    );
    port (
        clk         : in  std_logic;
        pll_locked  : in  std_logic;  -- MMCM'den gelen kilit sinyali
        post_pass   : in  std_logic;  -- POST self-test sonucu ('1'=geçti)
        post_fail   : in  std_logic;  -- POST self-test FAIL ('1'=kalıcı hata)
        
        system_rdy  : out std_logic;  -- Güvenlik kilidi (0: Kilitli, 1: Ateş Serbest)
        global_rst  : out std_logic   -- Sisteme giden senkron reset (aktif yüksek)
    );
end system_supervisor;

architecture Behavioral of system_supervisor is

    -------------------------------------------------------------------------
    -- TIMER HESAPLAMALARI
    -------------------------------------------------------------------------
    constant CYCLES_PER_MS : integer := CLK_FREQ_MHZ * 1000;
    constant WAIT_CYCLES   : integer := STARTUP_MS * CYCLES_PER_MS;
    -- 50 MHz × 1000 × 100 = 5,000,000 clock cycle (100ms)
    
    -- PLL GLITCH FİLTRESİ: PLL en az 1000 cycle stabil kalmalı
    constant PLL_STABLE_MIN : integer := 1000;
    
    -------------------------------------------------------------------------
    -- FSM STATES
    -------------------------------------------------------------------------
    type state_type is (
        WAIT_PLL_LOCK,   -- PLL kilidi bekleniyor
        PLL_QUALIFY,     -- PLL kilit kalitesi doğrulanıyor (glitch filtre)
        WARMUP,          -- Voltaj ısınma süresi
        POST_CHECK,      -- POST self-test sonucu bekleniyor
        SYSTEM_ACTIVE,   -- Sistem aktif (güvenli)
        FAIL_SAFE        -- PLL unlock oldu (fail-safe)
    );
    signal state : state_type := WAIT_PLL_LOCK;
    
    -------------------------------------------------------------------------
    -- TIMERS
    -------------------------------------------------------------------------
    signal timer_counter : integer range 0 to WAIT_CYCLES := 0;
    signal pll_stable_cnt : integer range 0 to PLL_STABLE_MIN := 0;

begin

    -------------------------------------------------------------------------
    -- BOOT SEQUENCE FSM
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            
            case state is
                
                -------------------------------------------------------------
                -- STATE 0: PLL KİLİDİ BEKLEME
                -------------------------------------------------------------
                when WAIT_PLL_LOCK =>
                    system_rdy <= '0';
                    global_rst <= '1';
                    timer_counter <= 0;
                    pll_stable_cnt <= 0;
                    
                    if pll_locked = '1' then
                        state <= PLL_QUALIFY;
                    end if;
                
                -------------------------------------------------------------
                -- STATE 1: PLL GLİTCH FİLTRE (1000 cycle stabi kontrol)
                -------------------------------------------------------------
                when PLL_QUALIFY =>
                    global_rst <= '1';
                    system_rdy <= '0';
                    
                    if pll_locked = '0' then
                        -- Glitch tespit: başa dön
                        state <= WAIT_PLL_LOCK;
                    elsif pll_stable_cnt >= PLL_STABLE_MIN then
                        -- PLL stabil, warmup başlat
                        state <= WARMUP;
                    else
                        pll_stable_cnt <= pll_stable_cnt + 1;
                    end if;
                
                -------------------------------------------------------------
                -- STATE 2: VOLTAJ ISINMA SÜRESİ (100ms)
                -------------------------------------------------------------
                when WARMUP =>
                    global_rst <= '1';
                    system_rdy <= '0';
                    
                    -- PLL glitch warmup sırasında da kontrol ediliyor
                    if pll_locked = '0' then
                        state <= FAIL_SAFE;
                    elsif timer_counter < WAIT_CYCLES then
                        timer_counter <= timer_counter + 1;
                    else
                        state <= POST_CHECK;
                    end if;
                
                -------------------------------------------------------------
                -- STATE 2b: POST SELF-TEST KONTROLÜ
                -- AES KAT + TRNG continuous test sonucu bekleniyor
                -------------------------------------------------------------
                when POST_CHECK =>
                    global_rst <= '0';  -- Reset kaldır (POST AES'i kullanacak)
                    system_rdy <= '0';  -- Henüz aktif değil
                    
                    if pll_locked = '0' then
                        state <= FAIL_SAFE;
                    elsif post_pass = '1' then
                        state <= SYSTEM_ACTIVE;  -- POST geçti!
                    elsif post_fail = '1' then
                        -- ★ POST FAIL: Sistem açılamaz — FAIL_SAFE'te bekle
                        -- global_rst='1' kalır, system_rdy='0' kalır
                        state <= FAIL_SAFE;
                    end if;
                    -- post_pass='0' ve post_fail='0' → POST hâlâ çalışıyor, bekle
                
                -------------------------------------------------------------
                -- STATE 3: SİSTEM AKTİF (KILL Ateş Serbest!)
                -------------------------------------------------------------
                when SYSTEM_ACTIVE =>
                    global_rst <= '0';
                    system_rdy <= '1';
                    
                    if pll_locked = '0' then
                        state <= FAIL_SAFE;
                    end if;
                
                -------------------------------------------------------------
                -- STATE 4: FAIL-SAFE (PLL Unlock — tam re-warmup gerekli)
                -------------------------------------------------------------
                when FAIL_SAFE =>
                    system_rdy <= '0';
                    global_rst <= '1';
                    timer_counter <= 0;  -- Warmup timer sıfırla
                    pll_stable_cnt <= 0; -- PLL qualify sıfırla
                    
                    if pll_locked = '1' then
                        state <= PLL_QUALIFY;  -- Tam re-qualify gerekli
                    end if;
                
                when others =>
                    state <= WAIT_PLL_LOCK;
                    
            end case;
        end if;
    end process;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. POWER-ON METASTABİLİTE KORUМASI
--    -> FPGA'ya ilk elektrik verildiğinde voltaj rayları henüz oturmamıştır
--    -> PLL'ler kilitlenmemiştir (LOCKED='0')
--    -> Flip-flop'lar rastgele değerler alabilir (metastability)
--    -> Eğer bu kaos anında KILL tetiklenirse -> Self-bricking!
--
-- 2. 100ms WARMUP SÜRESİ
--    -> PLL kilitlendikten sonra bile voltaj dalgalanmaları olabilir
--    -> Güç kaynağı (SMPS) çıkışı tam oturmamış olabilir
--    -> 100ms = Güvenli marj (typical PSU settling time: 50-200ms)
--
-- 3. FAIL-SAFE MEKANİZMASI
--    -> Sistem çalışırken PLL unlock olursa (power glitch, EMI)
--    -> Derhal system_ready='0' yap, KILL'i devre dışı bırak
--    -> Sistemi tekrar resetle
--    -> PLL kilitlenince yeniden boot sequence
--
-- 4. global_rst SİNYALİ
--    -> Aktif yüksek (active high) reset
--    -> kill_protocol, crypto_core_stub, uart_telemetry'ye gider
--    -> Tüm modüller senkron reset alır
--
-- 5. system_ready KULLANIMI (Artix7_top'ta)
--    safe_kill <= kill_active AND system_ready;
--    -> system_ready='0' -> KILL bloke
--    -> system_ready='1' -> KILL çalışabilir
--
-- 6. TİMİNG
--    -> PLL lock time: ~10ms (typical MMCM)
--    -> Warmup: 100ms
--    -> Toplam boot: ~110ms (güvenli sistem hazır)
--------------------------------------------------------------------------------
