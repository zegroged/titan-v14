--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Clock/Voltage Glitch Detector
-- Module: Delay-Line Comparison Anti-Tamper Guard
--------------------------------------------------------------------------------
-- ★ A3 ENHANCEMENT: Voltage/clock glitch injection tespiti
--
-- PRENSIP: Aynı sinyali iki farklı gecikme yolundan geçir.
--   Normal koşullarda çıkışlar eşleşir. Glitch enjekte edildiğinde
--   kısa yolun çıkışı hızlı, uzun yolun çıkışı geç değişir → XOR = 1
--
-- BAĞLANTI: glitch_alarm → kill chain (kill_protocol tetikler)
--
-- MİMARİ:
--   ┌──────┐     ╔═══════════╗
--   │ clk  │────→║ Fast Path ║──→ FF1 ──┐
--   │      │     ╚═══════════╝          ├──→ XOR → alarm
--   │      │     ╔═══════════╗          │
--   │      │────→║ Slow Path ║──→ FF2 ──┘
--   │      │     ║(+delay LUT)║
--   └──────┘     ╚═══════════╝
--
-- NOT: Glitch alarm latched → bir kez tetiklenince reset gerekli
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity glitch_detector is
    generic (
        DELAY_STAGES : integer := 8;     -- Gecikme zinciri uzunluğu
        ALARM_COUNT  : integer := 3      -- Kaç glitch olursa alarm? (debounce)
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        
        -- Monitör girişi (genellikle clk'ın kendisi veya PLL output)
        monitor_in    : in  std_logic;
        
        -- Çıkışlar
        glitch_alarm  : out std_logic;   -- '1' = Glitch tespit edildi (latched)
        glitch_count  : out std_logic_vector(7 downto 0)  -- Debug: toplam glitch
    );
end glitch_detector;

architecture Behavioral of glitch_detector is

    -------------------------------------------------------------------------
    -- Delay Chain (LUT zinciri — sentezleyici optimize edemez)
    -------------------------------------------------------------------------
    signal delay_chain : std_logic_vector(DELAY_STAGES-1 downto 0) := (others => '0');
    
    -- Dual-sampled flip-flops
    signal fast_sample : std_logic := '0';
    signal slow_sample : std_logic := '0';
    
    -- Glitch detection
    signal mismatch    : std_logic := '0';
    signal alarm_latch : std_logic := '0';
    signal count_reg   : unsigned(7 downto 0) := (others => '0');
    
    -------------------------------------------------------------------------
    -- Sentez koruması — optimize edilemez!
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of delay_chain : signal is "true";
    attribute dont_touch of fast_sample : signal is "true";
    attribute dont_touch of slow_sample : signal is "true";
    attribute dont_touch of alarm_latch : signal is "true";
    
    attribute keep : string;
    attribute keep of delay_chain : signal is "true";
    
    -- Synplify (PolarFire)
    attribute syn_keep : boolean;
    attribute syn_keep of delay_chain : signal is true;
    attribute syn_preserve : boolean;
    attribute syn_preserve of alarm_latch : signal is true;

begin

    -------------------------------------------------------------------------
    -- 1. DELAY CHAIN (Combinational — sentez'de LUT chain olur)
    -------------------------------------------------------------------------
    delay_chain(0) <= monitor_in;
    gen_delay: for i in 1 to DELAY_STAGES-1 generate
        delay_chain(i) <= delay_chain(i-1);
    end generate;

    -------------------------------------------------------------------------
    -- 2. DUAL SAMPLING — fast path vs slow path
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                fast_sample <= '0';
                slow_sample <= '0';
                mismatch    <= '0';
                count_reg   <= (others => '0');
                alarm_latch <= '0';
            else
                -- Fast path: doğrudan örnekleme
                fast_sample <= monitor_in;
                
                -- Slow path: delay chain sonundan örnekleme
                slow_sample <= delay_chain(DELAY_STAGES-1);
                
                -- XOR karşılaştırma: eşleşmeme = glitch
                mismatch <= fast_sample xor slow_sample;
                
                -- Glitch sayacı (debounce)
                if mismatch = '1' then
                    if count_reg < 255 then
                        count_reg <= count_reg + 1;
                    end if;
                    
                    -- Alarm eşiği aşıldı → LATCH (geri dönüşsüz)
                    if count_reg >= to_unsigned(ALARM_COUNT, 8) then
                        alarm_latch <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Çıkışlar
    glitch_alarm <= alarm_latch;
    glitch_count <= std_logic_vector(count_reg);

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. DELAY_STAGES=8: ~2-4ns gecikme (FPGA LUT delay × 8)
--    Yeterli: tipik glitch süresi 1-5ns
--
-- 2. ALARM_COUNT=3: Metastabilite kaynaklı yanlış pozitif önleme
--    3 eşzamanlı glitch → kesinlikle saldırı
--
-- 3. DONT_TOUCH: Vivado/Libero delay chain'i "gereksiz" diyerek silemez
--
-- 4. LATCH MEKANİZMASI: Glitch alarm geri dönüşsüz
--    → kill chain tetiklenir → DEAD_LOOP
--    → Yalnızca güç kesme ile sıfırlanır
--
-- 5. KULLANIM:
--    glitch_det_inst : entity work.glitch_detector
--        port map (
--            clk => sys_clk, rst_n => not global_rst,
--            monitor_in => sys_clk,  -- veya PLL çıkışı
--            glitch_alarm => glitch_kill,
--            glitch_count => open
--        );
--    -- Kill chain'e bağla: all_kill_sources <= ... or glitch_kill;
--------------------------------------------------------------------------------
