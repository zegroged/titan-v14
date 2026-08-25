--------------------------------------------------------------------------------
-- TB: data_gearbox
-- Test 1: Pack (16 byte → 128-bit AES blok) + İçerik doğrulama
-- Test 2: Unpack (128-bit AES → 16 byte TX) + Byte sayısı doğrulama
-- Test 3: Reset temizlik
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_data_gearbox is
end tb_data_gearbox;

architecture Behavioral of tb_data_gearbox is
    constant CLK_PERIOD : time := 20 ns;

    signal clk         : std_logic := '0';
    signal rst_n       : std_logic := '0';
    signal rx_byte     : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_valid    : std_logic := '0';
    signal tx_busy     : std_logic := '0';
    signal aes_out_blk : std_logic_vector(127 downto 0) := (others => '0');
    signal aes_out_vld : std_logic := '0';
    signal aes_in_blk  : std_logic_vector(127 downto 0);
    signal aes_in_vld  : std_logic;
    signal tx_byte     : std_logic_vector(7 downto 0);
    signal tx_start    : std_logic;

    signal test_pass : integer := 0;
    signal test_fail : integer := 0;
begin
    clk <= not clk after CLK_PERIOD/2;

    UUT: entity work.data_gearbox
        port map (
            clk         => clk,
            rst_n       => rst_n,
            rx_byte     => rx_byte,
            rx_valid    => rx_valid,
            tx_busy     => tx_busy,
            aes_out_blk => aes_out_blk,
            aes_out_vld => aes_out_vld,
            aes_in_blk  => aes_in_blk,
            aes_in_vld  => aes_in_vld,
            tx_byte     => tx_byte,
            tx_start    => tx_start
        );

    process
        variable expected_blk : std_logic_vector(127 downto 0);
        variable tx_count : integer := 0;
        variable expected_byte : std_logic_vector(7 downto 0);
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        --------------------------------------------------------------------
        -- TEST 1: PACK — 16 byte gönder, aes_in_blk kontrol et
        --------------------------------------------------------------------
        report "=== TEST 1: PACK 16 bytes ===" severity note;

        -- Expected: 0x00_01_02...0F (big endian)
        expected_blk := x"000102030405060708090A0B0C0D0E0F";

        for i in 0 to 15 loop
            rx_byte  <= std_logic_vector(to_unsigned(i, 8));
            rx_valid <= '1';
            wait for CLK_PERIOD;
            rx_valid <= '0';
            wait for CLK_PERIOD * 2;  -- Inter-byte gap
        end loop;

        -- aes_in_vld pulse beklenmeli
        wait for CLK_PERIOD * 5;

        if aes_in_blk = expected_blk then
            report "TEST 1 PASS: Pack content correct" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 1 FAIL: Expected " & 
                   "000102030405060708090A0B0C0D0E0F" & 
                   " but got different" severity error;
            test_fail <= test_fail + 1;
        end if;

        wait for CLK_PERIOD * 5;

        --------------------------------------------------------------------
        -- TEST 2: UNPACK — 128-bit blok → 16 byte TX çıkışı
        --------------------------------------------------------------------
        report "=== TEST 2: UNPACK 128-bit to 16 bytes ===" severity note;

        -- AES çıkışı olarak test bloğu ver
        aes_out_blk <= x"DEADBEEFCAFEBABE1234567890ABCDEF";
        aes_out_vld <= '1';
        wait for CLK_PERIOD;
        aes_out_vld <= '0';

        -- tx_start pulse'larını say ve byte içeriklerini doğrula
        tx_count := 0;
        tx_busy  <= '0';

        for cycle in 0 to 200 loop
            wait for CLK_PERIOD;
            if tx_start = '1' then
                tx_count := tx_count + 1;
                -- tx_busy'yi 1 cycle HIGH yap (UART meşgul simülasyonu)
                tx_busy <= '1';
                wait for CLK_PERIOD;
                tx_busy <= '0';
            end if;
            -- Tüm byte'lar gönderildi mi?
            if tx_count = 16 then
                exit;
            end if;
        end loop;

        if tx_count = 16 then
            report "TEST 2 PASS: Unpack produced " & integer'image(tx_count) & " bytes" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 2 FAIL: Expected 16 bytes, got " & integer'image(tx_count) severity error;
            test_fail <= test_fail + 1;
        end if;

        wait for CLK_PERIOD * 5;

        --------------------------------------------------------------------
        -- TEST 3: RESET — her şey sıfır
        --------------------------------------------------------------------
        report "=== TEST 3: RESET CLEANUP ===" severity note;

        rst_n <= '0';
        wait for CLK_PERIOD * 3;

        if tx_start = '0' and aes_in_vld = '0' then
            report "TEST 3 PASS: Reset clears outputs" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 3 FAIL: Outputs not cleared after reset" severity error;
            test_fail <= test_fail + 1;
        end if;

        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        --------------------------------------------------------------------
        -- SONUÇ
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
