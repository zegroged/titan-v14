--------------------------------------------------------------------------------
-- PROJECT TITAN V13: Artix-7 Clock Infrastructure
-- Module: MMCM-Based Clock Generation with LOCKED Signal
--------------------------------------------------------------------------------
-- AMAÇ: Harici 50 MHz saati MMCM (Mixed-Mode Clock Manager) ile işleyip,
--       jitter temizlenmiş 50 MHz sistem saati ve PLL LOCKED sinyali üretmek.
--
-- NEDEN WIZARD YOK?
--   -> Vivado Clocking Wizard kullanımı kolay ama "black box" yaratır
--   -> Primitive seviyesinde tam kontrol istiyoruz
--   -> LOCKED sinyalini manuel yönetmek gerekiyor (Supervisor için)
--
-- KOMUTAN ŞERHİ: "PLL LOCKED sinyali olmadan boot sequence yapılamaz.
--                 Primitive çağır, kontrolü elden bırakma!"
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Xilinx Primitives
library UNISIM;
use UNISIM.VComponents.all;

entity artix7_clocking is
    port (
        clk_in_50mhz : in  std_logic;  -- Harici 50 MHz (SiTime SiT5356)
        sys_clk      : out std_logic;  -- Sistem saati (50 MHz temiz)
        pll_locked   : out std_logic   -- PLL kilit durumu (Supervisor için)
    );
end artix7_clocking;

architecture Behavioral of artix7_clocking is

    -------------------------------------------------------------------------
    -- Dahili Sinyaller
    -------------------------------------------------------------------------
    signal clkfb_out    : std_logic;  -- MMCM feedback output
    signal clkfb_in     : std_logic;  -- MMCM feedback input (BUFG'den)
    signal sys_clk_raw  : std_logic;  -- MMCM çıkışı (BUFG öncesi)
    signal clk_in_buf   : std_logic;  -- IBUFG çıkışı

begin

    -------------------------------------------------------------------------
    -- 1. INPUT BUFFER (IBUFG)
    -------------------------------------------------------------------------
    -- Harici saati FPGA içine güvenle almak için
    -------------------------------------------------------------------------
    IBUFG_inst : IBUFG
        port map (
            I => clk_in_50mhz,
            O => clk_in_buf
        );

    -------------------------------------------------------------------------
    -- 2. MMCM BASE PRIMITIVE (PLL Core)
    -------------------------------------------------------------------------
    -- VCO = Clk_In × CLKFBOUT_MULT_F / DIVCLK_DIVIDE
    --     = 50 MHz × 20 / 1 = 1000 MHz
    --
    -- Clk_Out = VCO / CLKOUT0_DIVIDE_F
    --         = 1000 MHz / 20 = 50 MHz
    --
    -- Sonuç: 50 MHz giriş -> 50 MHz çıkış (Jitter temizleme + LOCKED)
    -------------------------------------------------------------------------
    MMCME2_BASE_inst : MMCME2_BASE
        generic map (
            BANDWIDTH          => "OPTIMIZED",  -- Jitter performansı
            CLKFBOUT_MULT_F    => 20.0,         -- VCO multiplier
            CLKIN1_PERIOD      => 20.0,         -- 50 MHz = 20ns period
            CLKOUT0_DIVIDE_F   => 20.0,         -- Output divider
            DIVCLK_DIVIDE      => 1,            -- Input divider
            STARTUP_WAIT       => FALSE,        -- Asenkron startup (manuel kontrol)
            
            -- Diğer clock output'ları (kullanılmıyor, varsayılan)
            CLKOUT1_DIVIDE     => 1,
            CLKOUT2_DIVIDE     => 1,
            CLKOUT3_DIVIDE     => 1,
            CLKOUT4_DIVIDE     => 1,
            CLKOUT5_DIVIDE     => 1,
            CLKOUT6_DIVIDE     => 1,
            
            -- Phase ve duty cycle (varsayılan)
            CLKOUT0_DUTY_CYCLE => 0.5,
            CLKOUT0_PHASE      => 0.0
        )
        port map (
            -- Clock Inputs
            CLKIN1   => clk_in_buf,     -- 50 MHz giriş
            
            -- Feedback (Zero-delay buffer modu)
            CLKFBIN  => clkfb_in,       -- Feedback input
            CLKFBOUT => clkfb_out,      -- Feedback output
            
            -- Clock Outputs
            CLKOUT0  => sys_clk_raw,    -- 50 MHz çıkış (raw)
            CLKOUT1  => open,           -- Kullanılmıyor
            CLKOUT2  => open,
            CLKOUT3  => open,
            CLKOUT4  => open,
            CLKOUT5  => open,
            CLKOUT6  => open,
            
            -- Status ve Control
            LOCKED   => pll_locked,     -- ★ KRİTİK: Supervisor'a gider!
            PWRDWN   => '0',            -- Power-down devre dışı
            RST      => '0'             -- Reset yok (always running)
        );

    -------------------------------------------------------------------------
    -- 3. FEEDBACK PATH BUFFER (BUFG)
    -------------------------------------------------------------------------
    -- MMCM'in feedback hattını global network'e basar
    -- Bu "Zero-Delay Buffer" modunu aktive eder
    -------------------------------------------------------------------------
    BUFG_feedback : BUFG
        port map (
            I => clkfb_out,
            O => clkfb_in
        );

    -------------------------------------------------------------------------
    -- 4. OUTPUT CLOCK BUFFER (BUFG)
    -------------------------------------------------------------------------
    -- Sistem saatini global clock tree'ye bas
    -------------------------------------------------------------------------
    BUFG_sysclk : BUFG
        port map (
            I => sys_clk_raw,
            O => sys_clk        -- ← Tüm sisteme dağıtılan saat
        );

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. MMCME2_BASE vs WIZARD
--    -> MMCME2_BASE: Primitive (manuel kontrol, full access)
--    -> Clocking Wizard: Otomatik kod üretir ama "black box"
--    -> Biz primitive kullandık -> Her parametreyi kontrol ediyoruz
--
-- 2. VCO FREQUENCY (1000 MHz)
--    -> Artix-7 MMCM VCO range: 600 MHz - 1200 MHz
--    -> 1000 MHz orta nokta -> Jitter performansı iyi
--    -> Eğer farklı frekanslara ihtiyaç olursa CLKOUT1-6 kullanılabilir
--
-- 3. LOCKED SİNYALİ
--    -> MMCM kilitlendikten sonra '1' olur (~10ms sürer)
--    -> Bu sinyal system_supervisor'a gider
--    -> Supervisor LOCKED='0' iken sistemi RESET'te tutar
--
-- 4. ZERO-DELAY BUFFER MODU
--    -> CLKFBOUT -> BUFG -> CLKFBIN (feedback loop)
--    -> Bu mod, CLKIN ile CLKOUT arasındaki phase farkını minimize eder
--    -> Critical: Source Synchronous uygulamalarda gerekli
--
-- 5. JİTTER TEMİZLEME
--    -> Harici oscillator (SiTime) zaten düşük jitter'lı
--    -> MMCM ek filtreleme yapar (BANDWIDTH => "OPTIMIZED")
--    -> Sonuç: <50ps RMS jitter (typical)
--
-- 6. BAŞARI KRİTERİ (Sentez Sonrası)
--    -> Utilization Report: MMCME2_ADV: 1/6 (Artix-7 100T'de 6 MMCM var)
--    -> Timing: pll_locked sinyali asenkron (false_path gerekli)
--
-- 7. CONSTRAINT GEREKSİNİMLERİ (artix7_constraints.xdc)
--    ```tcl
--    # MMCM çıkış saati
--    create_generated_clock -name sys_clk_mmcm \
--        -source [get_pins artix7_clocking_inst/MMCME2_BASE_inst/CLKIN1] \
--        -master_clock clk_ext_50 \
--        [get_pins artix7_clocking_inst/MMCME2_BASE_inst/CLKOUT0]
--    
--    # LOCKED sinyali asenkron
--    set_false_path -from [get_pins artix7_clocking_inst/MMCME2_BASE_inst/LOCKED]
--    ```
--------------------------------------------------------------------------------
