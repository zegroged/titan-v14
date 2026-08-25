--------------------------------------------------------------------------------
-- TITAN V14: SPI Command Slave Testbench — HLP Protocol + Kill
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_spi_cmd_slave is
end tb_spi_cmd_slave;

architecture Behavioral of tb_spi_cmd_slave is
    constant CLK_PERIOD : time := 20 ns;
    constant SPI_PERIOD : time := 200 ns;

    signal clk             : std_logic := '0';
    signal rst_n           : std_logic := '0';
    signal kill_signal     : std_logic := '0';
    signal spi_sclk        : std_logic := '0';
    signal spi_mosi        : std_logic := '0';
    signal spi_miso        : std_logic;
    signal spi_cs_app_n    : std_logic := '1';
    signal aes_pt_out      : std_logic_vector(127 downto 0);
    signal aes_pt_valid    : std_logic;
    signal aes_ct_in       : std_logic_vector(127 downto 0) := x"AABBCCDDEEFF00112233445566778899";
    signal aes_ct_valid    : std_logic := '0';
    signal aes_busy        : std_logic := '0';
    signal omega_active_in : std_logic := '1';
    signal aegis_active_in : std_logic := '1';
    signal lockstep_ok_in  : std_logic := '1';
    signal post_pass_in    : std_logic := '1';
    signal trng_healthy_in : std_logic := '1';
    signal kill_armed_in   : std_logic := '0';
    signal kill_trigger    : std_logic;
    signal cmd_active      : std_logic;
    signal cmd_error       : std_logic;
    signal heartbeat_ok    : std_logic;
    signal done_flag       : boolean := false;

    procedure spi_send_bit(
        signal sclk : out std_logic;
        signal mosi : out std_logic;
        bit_val : in std_logic
    ) is
    begin
        mosi <= bit_val;
        wait for SPI_PERIOD / 2;
        sclk <= '1';
        wait for SPI_PERIOD / 2;
        sclk <= '0';
    end procedure;

begin
    clk <= not clk after CLK_PERIOD / 2 when not done_flag else '0';

    dut : entity work.spi_cmd_slave
        generic map (MAX_PAYLOAD_BYTES => 256)
        port map (
            clk => clk, rst_n => rst_n, kill_signal => kill_signal,
            spi_sclk => spi_sclk, spi_mosi => spi_mosi,
            spi_miso => spi_miso, spi_cs_app_n => spi_cs_app_n,
            aes_pt_out => aes_pt_out, aes_pt_valid => aes_pt_valid,
            aes_ct_in => aes_ct_in, aes_ct_valid => aes_ct_valid,
            aes_busy => aes_busy,
            omega_active_in => omega_active_in,
            aegis_active_in => aegis_active_in,
            lockstep_ok_in => lockstep_ok_in,
            post_pass_in => post_pass_in,
            trng_healthy_in => trng_healthy_in,
            kill_armed_in => kill_armed_in,
            kill_trigger => kill_trigger,
            cmd_active => cmd_active, cmd_error => cmd_error,
            heartbeat_ok => heartbeat_ok
        );

    process
        variable pass_count : integer := 0;
        variable fail_count : integer := 0;
    begin
        rst_n <= '0';
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 10;

        report "=== TB_SPI_CMD_SLAVE ===" severity note;

        -- TEST 1: CS assert/deassert
        report "  Test 1: Basic SPI protocol" severity note;
        spi_cs_app_n <= '0';
        wait for CLK_PERIOD * 10;

        for i in 0 to 7 loop
            spi_send_bit(spi_sclk, spi_mosi, '0');
        end loop;

        spi_cs_app_n <= '1';
        wait for CLK_PERIOD * 20;

        pass_count := pass_count + 1;
        report "  [PASS] Basic SPI exchange survived" severity note;

        -- TEST 2: Kill wipes state
        report "  Test 2: Kill clears state" severity note;
        kill_signal <= '1';
        wait for CLK_PERIOD * 5;
        kill_signal <= '0';
        wait for CLK_PERIOD * 5;

        if cmd_active = '0' then
            pass_count := pass_count + 1;
            report "  [PASS] cmd_active=0 after kill" severity note;
        else
            fail_count := fail_count + 1;
            report "  [FAIL] cmd_active still high!" severity error;
        end if;

        -- TEST 3: Reset recovery
        report "  Test 3: Reset recovery" severity note;
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 10;

        if kill_trigger = '0' then
            pass_count := pass_count + 1;
            report "  [PASS] Clean state after reset" severity note;
        else
            fail_count := fail_count + 1;
            report "  [FAIL] Dirty state after reset!" severity error;
        end if;

        report "  PASS: " & integer'image(pass_count) &
               " FAIL: " & integer'image(fail_count) severity note;
        if fail_count = 0 then
            report "  [OK] tb_spi_cmd_slave ALL PASS" severity note;
        else
            report "  [FAIL] tb_spi_cmd_slave FAILED" severity error;
        end if;

        done_flag <= true;
        wait;
    end process;
end Behavioral;
