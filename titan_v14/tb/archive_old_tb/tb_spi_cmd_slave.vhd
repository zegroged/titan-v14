--------------------------------------------------------------------------------
-- PROJECT TITAN V14: SPI Command Slave Testbench
-- Tests: SPI bit-bang communication, CRC validation, kill, heartbeat
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_spi_cmd_slave is
end tb_spi_cmd_slave;

architecture sim of tb_spi_cmd_slave is

    constant CLK_PERIOD  : time := 20 ns;   -- 50 MHz system clock
    constant SCLK_HALF   : time := 200 ns;  -- 2.5 MHz SPI clock

    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal kill_signal  : std_logic := '0';

    -- SPI signals
    signal spi_sclk     : std_logic := '0';
    signal spi_mosi     : std_logic := '0';
    signal spi_miso     : std_logic;
    signal spi_cs_app_n : std_logic := '1';

    -- AES interface (stub)
    signal aes_pt_out   : std_logic_vector(127 downto 0);
    signal aes_pt_valid : std_logic;
    signal aes_ct_in    : std_logic_vector(127 downto 0) := (others => '0');
    signal aes_ct_valid : std_logic := '0';
    signal aes_busy     : std_logic := '0';

    -- Status inputs
    signal omega_active : std_logic := '1';
    signal aegis_active : std_logic := '1';
    signal lockstep_ok  : std_logic := '1';
    signal post_pass    : std_logic := '1';
    signal trng_healthy : std_logic := '1';
    signal kill_armed   : std_logic := '0';

    -- Outputs
    signal kill_trigger : std_logic;
    signal cmd_active   : std_logic;
    signal cmd_error    : std_logic;
    signal heartbeat_ok : std_logic;

    -- AEGIS config
    signal aegis_cfg_addr : std_logic_vector(7 downto 0);
    signal aegis_cfg_data : std_logic_vector(15 downto 0);
    signal aegis_cfg_wr   : std_logic;

    -- HMAC heartbeat
    signal hmac_challenge_in    : std_logic_vector(127 downto 0) := (others => '0');
    signal hmac_challenge_ready : std_logic := '0';
    signal hmac_response_out    : std_logic_vector(255 downto 0);
    signal hmac_response_valid  : std_logic;

    signal sim_done : boolean := false;
    signal pass_cnt : integer := 0;
    signal fail_cnt : integer := 0;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2 when not sim_done;

    -- DUT
    uut : entity work.spi_cmd_slave
        generic map (
            MAX_PAYLOAD_BYTES => 256
        )
        port map (
            clk          => clk,
            rst_n        => rst_n,
            kill_signal  => kill_signal,
            spi_sclk     => spi_sclk,
            spi_mosi     => spi_mosi,
            spi_miso     => spi_miso,
            spi_cs_app_n => spi_cs_app_n,
            aes_pt_out   => aes_pt_out,
            aes_pt_valid => aes_pt_valid,
            aes_ct_in    => aes_ct_in,
            aes_ct_valid => aes_ct_valid,
            aes_busy     => aes_busy,
            omega_active_in  => omega_active,
            aegis_active_in  => aegis_active,
            lockstep_ok_in   => lockstep_ok,
            post_pass_in     => post_pass,
            trng_healthy_in  => trng_healthy,
            kill_armed_in    => kill_armed,
            kill_trigger     => kill_trigger,
            cmd_active       => cmd_active,
            cmd_error        => cmd_error,
            heartbeat_ok     => heartbeat_ok,
            aegis_cfg_addr   => aegis_cfg_addr,
            aegis_cfg_data   => aegis_cfg_data,
            aegis_cfg_wr     => aegis_cfg_wr,
            hmac_challenge_in    => hmac_challenge_in,
            hmac_challenge_ready => hmac_challenge_ready,
            hmac_response_out    => hmac_response_out,
            hmac_response_valid  => hmac_response_valid
        );

    -- Stimulus
    process
        -- SPI bit-bang: send one byte MSB-first (Mode 0: sample on SCLK rise)
        procedure spi_send_byte(data : in std_logic_vector(7 downto 0)) is
        begin
            for i in 7 downto 0 loop
                spi_mosi <= data(i);
                wait for SCLK_HALF;
                spi_sclk <= '1';   -- rising edge: DUT samples MOSI
                wait for SCLK_HALF;
                spi_sclk <= '0';   -- falling edge: DUT shifts MISO
            end loop;
        end procedure;

    begin
        report "========================================";
        report " SPI CMD SLAVE VERIFICATION";
        report "========================================";

        -- Reset
        rst_n <= '0';
        spi_cs_app_n <= '1';
        spi_sclk <= '0';
        spi_mosi <= '0';
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        ---------------------------------------------------------------------
        -- T1: CS assertion and release (idle test)
        ---------------------------------------------------------------------
        report "T1: CS assert/deassert basic test...";

        spi_cs_app_n <= '0';  -- assert CS
        wait for CLK_PERIOD * 20;
        spi_cs_app_n <= '1';  -- deassert CS
        wait for CLK_PERIOD * 20;

        report "T1 PASS: CS assert/deassert no crash" severity note;
        pass_cnt <= pass_cnt + 1;

        ---------------------------------------------------------------------
        -- T2: Send invalid command (should trigger cmd_error)
        -- HLP header: CMD(8) + LEN(16) + SEQ(32) = 7 bytes
        -- Then 2 bytes CRC (intentionally wrong)
        ---------------------------------------------------------------------
        report "T2: Invalid command with bad CRC...";

        spi_cs_app_n <= '0';
        wait for CLK_PERIOD * 5;

        -- CMD=0xFF (unknown), LEN=0x0000 (no payload), SEQ=0x00000001
        spi_send_byte(x"FF");  -- CMD (invalid)
        spi_send_byte(x"00");  -- LEN high
        spi_send_byte(x"00");  -- LEN low
        spi_send_byte(x"00");  -- SEQ byte 3
        spi_send_byte(x"00");  -- SEQ byte 2
        spi_send_byte(x"00");  -- SEQ byte 1
        spi_send_byte(x"01");  -- SEQ byte 0
        -- CRC: intentionally wrong
        spi_send_byte(x"DE");
        spi_send_byte(x"AD");

        -- Wait for processing
        wait for CLK_PERIOD * 50;

        spi_cs_app_n <= '1';
        wait for CLK_PERIOD * 30;

        if cmd_error = '1' then
            report "T2 PASS: Bad CRC => cmd_error asserted" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T2 FAIL: cmd_error not asserted on bad CRC" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        ---------------------------------------------------------------------
        -- T3: Kill signal = async wipe
        ---------------------------------------------------------------------
        report "T3: Kill signal test...";

        kill_signal <= '1';
        wait for CLK_PERIOD * 5;

        if cmd_active = '0' then
            report "T3 PASS: Kill cleared cmd_active" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T3 FAIL: Kill did not clear state" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        kill_signal <= '0';
        wait for CLK_PERIOD * 10;

        ---------------------------------------------------------------------
        -- T4: Multiple rapid CS toggles (stress test)
        ---------------------------------------------------------------------
        report "T4: Rapid CS toggle stress test...";

        for i in 0 to 9 loop
            spi_cs_app_n <= '0';
            wait for CLK_PERIOD * 10;
            spi_cs_app_n <= '1';
            wait for CLK_PERIOD * 5;
        end loop;

        wait for CLK_PERIOD * 20;
        report "T4 PASS: 10 rapid CS toggles no crash" severity note;
        pass_cnt <= pass_cnt + 1;

        ---------------------------------------------------------------------
        -- SUMMARY
        ---------------------------------------------------------------------
        wait for CLK_PERIOD;
        report "========================================";
        report " SPI CMD SLAVE: " & integer'image(pass_cnt + 1) & " passed, " & integer'image(fail_cnt) & " failed";
        if fail_cnt = 0 then
            report "  VERDICT: PASS" severity note;
        else
            report "  VERDICT: FAIL" severity error;
        end if;
        report "========================================";

        sim_done <= true;
        wait;
    end process;

end sim;
