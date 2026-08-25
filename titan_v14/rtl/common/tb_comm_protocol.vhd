--------------------------------------------------------------------------------
-- TB: comm_protocol
-- Test 1: TX data submission -> session_active='1'
-- Test 2: Kill -> session_active='0'
-- Test 3: Kill sonrasi error flag'lari temiz
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_comm_protocol is
end tb_comm_protocol;

architecture Behavioral of tb_comm_protocol is
    constant CLK_PERIOD : time := 20 ns;

    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal kill_signal   : std_logic := '0';
    signal mode          : std_logic := '0';  -- TX only
    signal red_rx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal red_rx_valid  : std_logic := '0';
    signal red_tx_byte   : std_logic_vector(7 downto 0);
    signal red_tx_start  : std_logic;
    signal red_tx_busy   : std_logic := '0';
    signal blk_rx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal blk_rx_valid  : std_logic := '0';
    signal blk_tx_byte   : std_logic_vector(7 downto 0);
    signal blk_tx_start  : std_logic;
    signal blk_tx_busy   : std_logic := '0';
    signal aes_pt_out    : std_logic_vector(127 downto 0);
    signal aes_pt_valid  : std_logic;
    signal aes_ct_in     : std_logic_vector(127 downto 0) := (others => '0');
    signal aes_ct_valid  : std_logic := '0';
    signal derived_iv    : std_logic_vector(127 downto 0) := x"00112233445566778899AABBCCDDEEFF";
    signal session_active : std_logic;
    signal mac_error     : std_logic;
    signal frame_error   : std_logic;

    signal test_pass : integer := 0;
    signal test_fail : integer := 0;
begin
    clk <= not clk after CLK_PERIOD/2;

    UUT: entity work.comm_protocol
        port map (
            clk           => clk,
            rst_n         => rst_n,
            kill_signal   => kill_signal,
            mode          => mode,
            red_rx_byte   => red_rx_byte,
            red_rx_valid  => red_rx_valid,
            red_tx_byte   => red_tx_byte,
            red_tx_start  => red_tx_start,
            red_tx_busy   => red_tx_busy,
            blk_rx_byte   => blk_rx_byte,
            blk_rx_valid  => blk_rx_valid,
            blk_tx_byte   => blk_tx_byte,
            blk_tx_start  => blk_tx_start,
            blk_tx_busy   => blk_tx_busy,
            aes_pt_out    => aes_pt_out,
            aes_pt_valid  => aes_pt_valid,
            aes_ct_in     => aes_ct_in,
            aes_ct_valid  => aes_ct_valid,
            derived_iv    => derived_iv,
            session_active => session_active,
            mac_error     => mac_error,
            frame_error   => frame_error
        );

    process
    begin
        -- Reset
        rst_n <= '0';
        mode  <= '0';  -- TX mode only (RX kapali)
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        --------------------------------------------------------------------
        -- TEST 1: TX Data Submission -> TX FSM aktif olmali
        --------------------------------------------------------------------
        report "=== TEST 1: TX DATA SUBMISSION ===" severity note;

        -- First byte = NBLK (block count). Must be 1-16.
        red_rx_byte  <= x"01";  -- NBLK = 1 (1 block = 16 bytes)
        red_rx_valid <= '1';
        wait for CLK_PERIOD;
        red_rx_valid <= '0';
        wait for CLK_PERIOD * 3;

        -- 16 data bytes (1 block payload)
        for i in 0 to 15 loop
            red_rx_byte  <= std_logic_vector(to_unsigned(i + 65, 8));  -- 'A','B','C'...
            red_rx_valid <= '1';
            wait for CLK_PERIOD;
            red_rx_valid <= '0';
            wait for CLK_PERIOD * 3;
        end loop;

        -- TX FSM TX_COLLECT'e gecmis olmali, tx_active='1'
        wait for CLK_PERIOD * 5;

        if session_active = '1' then
            report "TEST 1 PASS: TX session active after data" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 1 FAIL: session_active should be 1 after TX data" severity error;
            test_fail <= test_fail + 1;
        end if;

        --------------------------------------------------------------------
        -- TEST 2: KILL -> session_active='0'
        --------------------------------------------------------------------
        report "=== TEST 2: KILL -> SESSION INACTIVE ===" severity note;

        kill_signal <= '1';
        wait for CLK_PERIOD;  -- 1 cycle kill
        kill_signal <= '0';

        -- Kill async -> FSM'ler aninda IDLE'a doner
        -- mode='0' yani RX baslamayacak -> session_active='0' olmali
        wait for CLK_PERIOD * 3;

        if session_active = '0' then
            report "TEST 2 PASS: session_active=0 after kill" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 2 FAIL: session_active should be 0 after kill" severity error;
            test_fail <= test_fail + 1;
        end if;

        --------------------------------------------------------------------
        -- TEST 3: Error flag'lari kill sonrasi temiz
        --------------------------------------------------------------------
        report "=== TEST 3: ERROR FLAGS CLEAR AFTER KILL ===" severity note;

        if mac_error = '0' and frame_error = '0' then
            report "TEST 3 PASS: Error flags cleared after kill" severity note;
            test_pass <= test_pass + 1;
        else
            report "TEST 3 FAIL: Error flags not cleared" severity error;
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
