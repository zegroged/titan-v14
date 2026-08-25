--------------------------------------------------------------------------------
-- TB: tb_dual_fpga_system
-- Test 1: Stabil durum -> kill=0 (senkron clocklar)
-- Test 2: Glitch injection -> kill=1 (leaky bucket doluyor)
-- Test 3: Kill sonrasi RAM scrub ve DEAD_LOOP
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_dual_fpga_system is
end tb_dual_fpga_system;

architecture Behavioral of tb_dual_fpga_system is
    constant CLK_PERIOD : time := 20 ns;

    -- Test sinyalleri
    signal clk_artix7    : std_logic := '0';
    signal clk_polarfire : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal factory_mode  : std_logic := '0';

    -- Tamper cikislari
    signal kill_signal       : std_logic;
    signal xor_output        : std_logic;
    signal capacitor_voltage : integer range 0 to 100;

    -- Kill protocol cikislari
    signal ram_addr         : std_logic_vector(15 downto 0);
    signal ram_data_out     : std_logic_vector(7 downto 0);
    signal ram_write_enable : std_logic;
    signal led_status_red   : std_logic;
    signal system_halted    : std_logic;

    signal sim_finished : boolean := false;
    signal test_pass : integer := 0;
    signal test_fail : integer := 0;
begin

    -- Tamper detector (leaky bucket)
    UUT_TAMPER: entity work.module_external_tamper
        generic map (
            TAU_NS              => 10000,
            THRESHOLD_NS        => 10000,
            SIMULATION_TIMESTEP => 10
        )
        port map (
            clk_artix7        => clk_artix7,
            clk_polarfire     => clk_polarfire,
            kill_signal       => kill_signal,
            xor_output        => xor_output,
            capacitor_voltage => capacitor_voltage
        );

    -- Kill protocol
    UUT_KILL: entity work.kill_protocol
        generic map (
            KEY_MEMORY_START => 16#1000#,
            KEY_MEMORY_END   => 16#1FFF#,
            RAM_ADDR_WIDTH   => 16
        )
        port map (
            clk              => clk_artix7,
            rst_n            => rst_n,
            kill_pin         => kill_signal,
            factory_mode     => factory_mode,
            ram_addr         => ram_addr,
            ram_data_out     => ram_data_out,
            ram_write_enable => ram_write_enable,
            led_status_red   => led_status_red,
            system_halted    => system_halted
        );

    -- PolarFire clock (senkron, surekli)
    pf_clk: process
    begin
        while not sim_finished loop
            clk_polarfire <= '0';
            wait for CLK_PERIOD / 2;
            clk_polarfire <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- Test stimulus
    process
    begin
        -- Reset
        rst_n <= '0';
        factory_mode <= '0';  -- Armed mode
        clk_artix7 <= '0';
        wait for 100 ns;
        rst_n <= '1';

        --------------------------------------------------------------------
        -- TEST 1: Stabil durum - senkron clocklar -> kill=0
        --------------------------------------------------------------------
        report "=== TEST 1: STABIL DURUM ===" severity note;

        -- Senkron clock: artix7 = polarfire
        for i in 1 to 2000 loop  -- 40us
            clk_artix7 <= '0';
            wait for CLK_PERIOD / 2;
            clk_artix7 <= '1';
            wait for CLK_PERIOD / 2;
        end loop;

        if kill_signal = '0' then
            report "TEST 1 PASS: Stabil durumda kill=0" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 1 FAIL: Stabil durumda kill tetiklendi" severity error;
            test_fail <= test_fail + 1;
        end if;

        --------------------------------------------------------------------
        -- TEST 2: Buyuk faz kaymasi -> XOR=1 -> kill=1
        -- Artix7 clock'u tamamen durduruyoruz (sabit '0')
        -- PolarFire clock devam ediyor -> XOR = 0 xor toggle = toggle
        -- Leaky bucket surekli doluyor -> 10us'de kill tetiklenir
        --------------------------------------------------------------------
        report "=== TEST 2: GLITCH -> KILL ===" severity note;

        -- Artix7 clock'u durdur (sabit low)
        -- PolarFire toggle -> XOR = toggle (surekli degisim)
        -- Ama XOR='1' bucket'i dolduruyor
        -- Artix7 sabit '1' yapalim -> XOR = 1 xor clk_pf
        -- Yarisi '1' yarisi '0' -> bucket yavas yavas dolar

        -- En kolay yol: artix7'yi ters faza gecirelim
        -- Boylece XOR surekli '1' olur
        for i in 1 to 2000 loop  -- 40us (threshold 10us -> bol bol yeter)
            clk_artix7 <= '1';  -- Ters faz: pf='0' iken artix='1'
            wait for CLK_PERIOD / 2;
            clk_artix7 <= '0';  -- Ters faz: pf='1' iken artix='0'
            wait for CLK_PERIOD / 2;
        end loop;

        -- Kill tetiklenmis olmali
        if kill_signal = '1' then
            report "TEST 2 PASS: Faz kaymasi sonrasi kill=1" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 2 FAIL: Kill tetiklenmedi (capacitor=" & integer'image(capacitor_voltage) & "%)" severity error;
            test_fail <= test_fail + 1;
        end if;

        --------------------------------------------------------------------
        -- TEST 3: Kill sonrasi RAM scrub ve sistem durumu
        --------------------------------------------------------------------
        report "=== TEST 3: KILL SONRASI DURUM ===" severity note;

        -- Kill tetiklendikten sonra RAM scrub + DEAD_LOOP bekliyoruz
        -- kill_protocol: DEBOUNCE -> KILL_ACTIVE -> SCRUB_RAM -> DEAD_LOOP
        -- Yeterli zaman ver (50us)
        for i in 1 to 2500 loop
            clk_artix7 <= '0';
            wait for CLK_PERIOD / 2;
            clk_artix7 <= '1';
            wait for CLK_PERIOD / 2;
        end loop;

        if led_status_red = '1' then
            report "TEST 3 PASS: Kill sonrasi LED kirmizi" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 3 FAIL: LED kirmizi degil" severity error;
            test_fail <= test_fail + 1;
        end if;

        --------------------------------------------------------------------
        -- SONUC
        --------------------------------------------------------------------
        report "============================================" severity note;
        report "RESULTS: " & integer'image(test_pass) & " PASS / " & 
               integer'image(test_fail) & " FAIL" severity note;
        report "============================================" severity note;

        if test_fail > 0 then
            report "*** TESTBENCH FAILED ***" severity failure;
        end if;

        sim_finished <= true;
        wait;
    end process;
end Behavioral;
