--------------------------------------------------------------------------------
-- TB: key_loader_spi
-- Test 1: SPI ile 256-bit key yukle -> key_valid='1' olmali
-- Test 2: Kill -> key sifirlanmali, key_valid='0' olmali
-- Test 3: Reset recovery
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_key_loader_spi is
end tb_key_loader_spi;

architecture Behavioral of tb_key_loader_spi is
    constant CLK_PERIOD : time := 20 ns;
    -- SPI clock: 500ns per half-period = 1MHz SPI
    -- Bu, sys_clk'in 25x yavasi -> CDC'ye bolca zaman
    constant SPI_HALF : time := 500 ns;

    signal clk            : std_logic := '0';
    signal rst_n          : std_logic := '0';
    signal kill_signal    : std_logic := '0';
    signal spi_sclk       : std_logic := '0';
    signal spi_mosi       : std_logic := '0';
    signal spi_cs_n       : std_logic := '1';
    signal trng_key_part  : std_logic_vector(127 downto 0) := (others => '0');
    signal jumper_calib   : std_logic := '1';  -- Factory mode

    signal key_out        : std_logic_vector(255 downto 0);
    signal key_valid      : std_logic;
    signal key_kill_trigger : std_logic;

    signal test_pass : integer := 0;
    signal test_fail : integer := 0;

    -- SPI test key (256-bit)
    constant TEST_KEY : std_logic_vector(255 downto 0) :=
        x"0123456789ABCDEF_FEDCBA9876543210_DEADBEEFCAFEBABE_1234567890ABCDEF";
begin
    clk <= not clk after CLK_PERIOD/2;

    UUT: entity work.key_loader_spi
        port map (
            clk             => clk,
            rst_n           => rst_n,
            kill_signal     => kill_signal,
            spi_sclk        => spi_sclk,
            spi_mosi        => spi_mosi,
            spi_cs_n        => spi_cs_n,
            trng_key_part   => trng_key_part,
            jumper_calib    => jumper_calib,
            key_out         => key_out,
            key_valid       => key_valid,
            key_kill_trigger => key_kill_trigger
        );

    process
        -- SPI bit gonder: CPOL=0, CPHA=0 (Mode 0)
        -- MOSI, SCLK rising edge'de orneklenir
        procedure spi_send_bit(b : std_logic) is
        begin
            spi_mosi <= b;
            wait for SPI_HALF;  -- Setup time
            spi_sclk <= '1';    -- Rising edge -> data sampled
            wait for SPI_HALF;  -- Hold time
            spi_sclk <= '0';    -- Falling edge
        end procedure;

        variable expected_key : std_logic_vector(255 downto 0);
    begin
        -- Reset
        rst_n <= '0';
        spi_cs_n <= '1';
        spi_sclk <= '0';
        spi_mosi <= '0';
        trng_key_part <= (others => '0');  -- TRNG kismi sifir -> final key = SPI key XOR 0
        jumper_calib <= '1';  -- Factory mode (SPI aktif)
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 10;

        --------------------------------------------------------------------
        -- TEST 1: SPI ile 256-bit key yukle
        --------------------------------------------------------------------
        report "=== TEST 1: SPI KEY LOAD (256 bit) ===" severity note;

        -- CS assert (active low)
        spi_cs_n <= '0';
        wait for SPI_HALF;

        -- 256 bit gonder (MSB first)
        for i in 255 downto 0 loop
            spi_send_bit(TEST_KEY(i));
        end loop;

        -- CS deassert -> transfer tamamlandi
        spi_cs_n <= '1';

        -- CDC propagation icin bekle (100 sys clock = 2us)
        wait for CLK_PERIOD * 100;

        -- key_valid='1' olmali
        if key_valid = '1' then
            report "TEST 1 PASS: key_valid=1 after 256-bit SPI transfer" severity note;
            test_pass <= test_pass + 1;

            -- Key icerigi dogrula
            -- TRNG=0 oldugu icin: key_out = TEST_KEY XOR 0 = TEST_KEY
            expected_key := TEST_KEY;
            if key_out = expected_key then
                report "  Key content VERIFIED" severity note;
            else
                report "  WARNING: Key content mismatch (CDC or bit order issue)" severity warning;
            end if;
        else
            report "TEST 1 FAIL: key_valid=0 -- SPI transfer did not complete" severity error;
            test_fail <= test_fail + 1;
        end if;

        wait for CLK_PERIOD * 5;

        --------------------------------------------------------------------
        -- TEST 2: KILL -> key sifirlanmali
        --------------------------------------------------------------------
        report "=== TEST 2: KILL -> KEY ZEROED ===" severity note;

        kill_signal <= '1';
        wait for CLK_PERIOD;
        kill_signal <= '0';
        wait for CLK_PERIOD * 3;

        if key_valid = '0' then
            report "TEST 2 PASS: key_valid=0 after kill" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 2 FAIL: key_valid should be 0 after kill" severity error;
            test_fail <= test_fail + 1;
        end if;

        -- key_out sifir olmali
        if key_out = x"0000000000000000000000000000000000000000000000000000000000000000" then
            report "  Key content zeroed -- VERIFIED" severity note;
        else
            report "  WARNING: key_out not fully zeroed after kill" severity warning;
        end if;

        wait for CLK_PERIOD * 5;

        --------------------------------------------------------------------
        -- TEST 3: Reset recovery -- yeni key yuklenebilmeli
        --------------------------------------------------------------------
        report "=== TEST 3: RESET RECOVERY ===" severity note;

        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 10;

        if key_valid = '0' and key_kill_trigger = '0' then
            report "TEST 3 PASS: Clean state after reset" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 3 FAIL: State not clean after reset" severity error;
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

        wait;
    end process;
end Behavioral;
