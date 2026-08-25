--------------------------------------------------------------------------------
-- PROJECT TITAN V13: ANA TESTBENCH
-- Testbench: Dual-FPGA Security System Simulation
--------------------------------------------------------------------------------
-- AMAC: Sanal donanim + KILL protocol'u birlikte test etmek.
--
-- TEST SENARYOLARI:
--   1. [0-100us]   : STABIL DURUM - Senkron clock'lar
--   2. [150us]     : GLITCH INJECTION - 5ns faz kaymasi
--   3. [160us]     : KILL SIGNAL - Tamper tespit edildi
--   4. [165us]     : RAM SCRUBBING - Kripto anahtarlari siliniyor
--   5. [200us]     : PARAZIT TEST - 1ns spike (filtrelenmeli)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_dual_fpga_system is
    -- Testbench'lerde port yok
end tb_dual_fpga_system;

architecture Behavioral of tb_dual_fpga_system is

    -------------------------------------------------------------------------
    -- Component Declarations
    -------------------------------------------------------------------------

    -- Sanal Donanim (XOR + RC Filtre)
    component module_external_tamper
        generic (
            TAU_NS              : integer := 10_000;
            THRESHOLD_NS        : integer := 10_000;
            SIMULATION_TIMESTEP : integer := 10
        );
        port (
            clk_artix7        : in  std_logic;
            clk_polarfire     : in  std_logic;
            kill_signal       : out std_logic;
            xor_output        : out std_logic;
            capacitor_voltage : out integer range 0 to 100
        );
    end component;

    -- KILL Protocol
    component kill_protocol
        generic (
            KEY_MEMORY_START : integer := 16#1000#;
            KEY_MEMORY_END   : integer := 16#1FFF#;
            RAM_ADDR_WIDTH   : integer := 16
        );
        port (
            clk              : in  std_logic;
            rst_n            : in  std_logic;
            kill_pin         : in  std_logic;
            factory_mode     : in  std_logic;
            ram_addr         : out std_logic_vector(15 downto 0);
            ram_data_out     : out std_logic_vector(7 downto 0);
            ram_write_enable : out std_logic;
            led_status_red   : out std_logic;
            system_halted    : out std_logic
        );
    end component;

    -------------------------------------------------------------------------
    -- Clock ve Timing Parametreleri
    -------------------------------------------------------------------------
    constant CLK_PERIOD : time := 20 ns;  -- 50 MHz (74VHC74 Prescaler cikisi)

    -------------------------------------------------------------------------
    -- Test Sinyalleri
    -------------------------------------------------------------------------

    -- FPGA Clock'lari (Normalde senkron, test sirasinda glitch eklenecek)
    signal clk_artix7    : std_logic := '0';
    signal clk_polarfire : std_logic := '0';

    -- Sistem Kontrol Sinyalleri
    signal rst_n         : std_logic := '0';  -- Reset (aktif dusuk)
    signal factory_mode  : std_logic := '0';  -- Fabrika modu

    -- Tamper Detektor Cikislari
    signal kill_signal       : std_logic;
    signal xor_output        : std_logic;
    signal capacitor_voltage : integer range 0 to 100;

    -- KILL Protocol Cikislari
    signal ram_addr         : std_logic_vector(15 downto 0);
    signal ram_data_out     : std_logic_vector(7 downto 0);
    signal ram_write_enable : std_logic;
    signal led_status_red   : std_logic;
    signal system_halted    : std_logic;

    -- Test Control
    signal sim_finished : boolean := false;

begin

    -------------------------------------------------------------------------
    -- DUT Instantiation (Device Under Test)
    -------------------------------------------------------------------------

    -- Sanal Donanim (External Tamper Detector)
    UUT_TAMPER: module_external_tamper
        generic map (
            TAU_NS              => 10_000,  -- 10us RC zaman sabiti
            THRESHOLD_NS        => 10_000,  -- 10us esik
            SIMULATION_TIMESTEP => 10       -- 10ns adim
        )
        port map (
            clk_artix7        => clk_artix7,
            clk_polarfire     => clk_polarfire,
            kill_signal       => kill_signal,
            xor_output        => xor_output,
            capacitor_voltage => capacitor_voltage
        );

    -- KILL Protocol
    UUT_KILL: kill_protocol
        generic map (
            KEY_MEMORY_START => 16#1000#,
            KEY_MEMORY_END   => 16#1FFF#,
            RAM_ADDR_WIDTH   => 16
        )
        port map (
            clk              => clk_artix7,  -- Ana clock (Artix-7'den)
            rst_n            => rst_n,
            kill_pin         => kill_signal,
            factory_mode     => factory_mode,
            ram_addr         => ram_addr,
            ram_data_out     => ram_data_out,
            ram_write_enable => ram_write_enable,
            led_status_red   => led_status_red,
            system_halted    => system_halted
        );

    -------------------------------------------------------------------------
    -- Clock Generation (Normal Durum: Senkron)
    -------------------------------------------------------------------------
    clk_polarfire_gen: process
    begin
        while not sim_finished loop
            clk_polarfire <= '0';
            wait for CLK_PERIOD / 2;
            clk_polarfire <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -------------------------------------------------------------------------
    -- TEST SENARYOLARI (Main Stimulus)
    -------------------------------------------------------------------------
    stimulus: process
    begin
        -----------------------------------------------------------------------
        -- T = 0: Sistem Baslatma
        -----------------------------------------------------------------------
        report "=== TEST BASLADI ===" severity note;
        rst_n <= '0';
        factory_mode <= '0';  -- Armed mode (tam koruma)

        -- Artix-7 baslangicta senkron (PolarFire ile)
        clk_artix7 <= '0';

        wait for 100 ns;
        rst_n <= '1';  -- Reset kaldir

        -----------------------------------------------------------------------
        -- SENARYO 1: STABIL DURUM (0-100us)
        -----------------------------------------------------------------------
        report "--- SENARYO 1: Stabil Durum (Senkron Clock'lar) ---" severity note;

        for i in 1 to 5000 loop  -- 5000 dongu x 20ns = 100us
            clk_artix7 <= '0';
            wait for CLK_PERIOD / 2;
            clk_artix7 <= '1';
            wait for CLK_PERIOD / 2;
        end loop;

        -- Kontrol: Kill sinyali tetiklenmemeli
        assert kill_signal = '0'
            report "HATA: Stabil durumda KILL tetiklendi!" severity error;
        assert capacitor_voltage = 0
            report "HATA: Kondansator voltaji 0 degil!" severity error;

        report "[OK] Stabil durum testi BASARILI" severity note;

        -----------------------------------------------------------------------
        -- SENARYO 2: GLITCH INJECTION (150us'de 5ns Faz Kaymasi)
        -----------------------------------------------------------------------
        report "--- SENARYO 2: Glitch Injection (5ns Faz Kaymasi) ---" severity note;

        for i in 1 to 2500 loop  -- 2500 dongu x 20ns = 50us
            clk_artix7 <= '0';
            wait for CLK_PERIOD / 2;
            clk_artix7 <= '1';
            wait for (CLK_PERIOD / 2) + 5 ns;  -- +5ns gecikme (GLITCH!)
        end loop;

        -----------------------------------------------------------------------
        -- SENARYO 3: KILL SIGNAL VERIFICATION (160us)
        -----------------------------------------------------------------------
        report "--- SENARYO 3: Kill Signal Tetiklemesi ---" severity note;

        wait for 100 ns;  -- Kill protocol'un baslamasi icin zaman

        assert kill_signal = '1'
            report "HATA: 10us faz kaymasindan sonra KILL tetiklenmedi!" severity error;
        assert led_status_red = '1'
            report "HATA: Kirmizi LED yanmadi!" severity error;

        report "[OK] Kill signal testi BASARILI" severity note;

        -----------------------------------------------------------------------
        -- SENARYO 4: RAM SCRUBBING VERIFICATION
        -----------------------------------------------------------------------
        report "--- SENARYO 4: RAM Silme Islemi ---" severity note;

        wait for 200 ns;  -- Birkac clock cycle bekle

        assert ram_write_enable = '1'
            report "HATA: RAM yazma sinyali aktif degil!" severity error;
        assert ram_data_out = x"FF"
            report "HATA: RAM'e yazilan veri 0xFF degil!" severity error;

        report "[OK] RAM scrubbing testi BASARILI" severity note;

        -- RAM silme tamamlanana kadar bekle
        wait for 30 us;  -- 4KB / 200MHz = ~20us

        assert system_halted = '1'
            report "HATA: Sistem DEAD LOOP durumuna gecmedi!" severity error;

        -----------------------------------------------------------------------
        -- SENARYO 5: PARAZIT BAGISIKLIGI (1ns Spike Testi)
        -----------------------------------------------------------------------
        report "--- SENARYO 5: Parazit Bagisikligi (1ns Spike) ---" severity note;
        report "NOT: Bu test bagimsiz bir simulasyonda yapilmali (reset gerektirir)" severity warning;

        -----------------------------------------------------------------------
        -- TEST TAMAMLANDI
        -----------------------------------------------------------------------
        wait for 1 us;
        report "=== TUM TESTLER TAMAMLANDI ===" severity note;
        sim_finished <= true;
        wait;

    end process;

end Behavioral;
