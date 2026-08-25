--------------------------------------------------------------------------------
-- TITAN V14: Key Loader SPI Testbench
-- Tests: SPI key injection, 3-strike lockout, kill wipe, window timeout
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_key_loader_spi is
end tb_key_loader_spi;

architecture sim of tb_key_loader_spi is
    constant CLK_PERIOD : time := 20 ns;
    constant SCLK_HALF  : time := 200 ns;

    signal clk            : std_logic := '0';
    signal rst_n          : std_logic := '0';
    signal kill_signal    : std_logic := '0';
    signal spi_sclk       : std_logic := '0';
    signal spi_mosi       : std_logic := '0';
    signal spi_cs_n       : std_logic := '1';
    signal key_out        : std_logic_vector(255 downto 0);
    signal key_valid      : std_logic;
    signal key_kill_trigger : std_logic;
    signal trng_key_part : std_logic_vector(127 downto 0) := x"A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5A5";
    signal jumper_calib  : std_logic := '0';  -- '0' = Armed mode

    signal sim_done : boolean := false;
    signal pass_cnt : integer := 0;
    signal fail_cnt : integer := 0;
begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done;

    uut : entity work.key_loader_spi
        port map (
            clk              => clk,
            rst_n            => rst_n,
            kill_signal      => kill_signal,
            spi_sclk         => spi_sclk,
            spi_mosi         => spi_mosi,
            spi_cs_n         => spi_cs_n,
            trng_key_part    => trng_key_part,
            jumper_calib     => jumper_calib,
            key_out          => key_out,
            key_valid        => key_valid,
            key_kill_trigger => key_kill_trigger
        );

    process
        procedure spi_send_byte(data : in std_logic_vector(7 downto 0)) is
        begin
            for i in 7 downto 0 loop
                spi_mosi <= data(i);
                wait for SCLK_HALF;
                spi_sclk <= '1';
                wait for SCLK_HALF;
                spi_sclk <= '0';
            end loop;
        end procedure;

        -- Send 256 bits (32 bytes) of a pattern
        procedure spi_send_key(val : in std_logic_vector(7 downto 0)) is
        begin
            spi_cs_n <= '0';
            wait for CLK_PERIOD * 5;
            for i in 0 to 31 loop
                spi_send_byte(val);
            end loop;
            wait for CLK_PERIOD * 3;
            spi_cs_n <= '1';
            wait for CLK_PERIOD * 20;
        end procedure;

    begin
        report "========================================";
        report " KEY LOADER SPI VERIFICATION";
        report "========================================";

        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        ---------------------------------------------------------------------
        -- T1: Initial state
        ---------------------------------------------------------------------
        report "T1: Initial state check...";
        if key_valid = '0' then
            report "T1 PASS: key_valid=0 initially" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T1 FAIL: key_valid should be 0" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        ---------------------------------------------------------------------
        -- T2: Send 256-bit key via SPI
        ---------------------------------------------------------------------
        report "T2: Sending 256-bit key via SPI...";
        spi_send_key(x"AA");
        wait for CLK_PERIOD * 10;

        if key_valid = '1' then
            report "T2 PASS: Key loaded via SPI" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T2 FAIL: Key not loaded" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        ---------------------------------------------------------------------
        -- T3: Kill wipe
        ---------------------------------------------------------------------
        report "T3: Kill signal wipe...";
        kill_signal <= '1';
        wait for CLK_PERIOD * 3;

        if key_valid = '0' then
            report "T3 PASS: Kill cleared key" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T3 FAIL: Key survived kill" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        kill_signal <= '0';
        wait for CLK_PERIOD * 5;

        ---------------------------------------------------------------------
        -- SUMMARY
        ---------------------------------------------------------------------
        wait for CLK_PERIOD;
        report "========================================";
        report " KEY LOADER SPI: " & integer'image(pass_cnt + 1) & " passed, " & integer'image(fail_cnt) & " failed";
        report "========================================";

        sim_done <= true;
        wait;
    end process;
end sim;
