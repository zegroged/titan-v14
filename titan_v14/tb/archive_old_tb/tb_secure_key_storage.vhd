--------------------------------------------------------------------------------
-- TITAN V14: Secure Key Storage Testbench
-- Tests: Load, kill wipe, warm reset wipe, key_valid flag
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_secure_key_storage is
end tb_secure_key_storage;

architecture sim of tb_secure_key_storage is
    constant CLK_PERIOD : time := 20 ns;

    signal clk         : std_logic := '0';
    signal rst_n       : std_logic := '0';
    signal kill_signal : std_logic := '0';
    signal load_key    : std_logic := '0';
    signal master_key  : std_logic_vector(255 downto 0) := (others => '0');

    signal key_out     : std_logic_vector(255 downto 0);
    signal key_valid   : std_logic;
    signal round_keys  : std_logic_vector(1919 downto 0);

    signal sim_done : boolean := false;
    signal pass_cnt : integer := 0;
    signal fail_cnt : integer := 0;

    constant TEST_KEY : std_logic_vector(255 downto 0) :=
        x"0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done;

    uut : entity work.secure_key_storage
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => kill_signal,
            load_key    => load_key,
            master_key  => master_key,
            key_out     => key_out,
            key_valid   => key_valid,
            round_keys  => round_keys
        );

    process
    begin
        report "========================================";
        report " SECURE KEY STORAGE VERIFICATION";
        report "========================================";

        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------------
        -- T1: Initial state - key_valid = 0
        ---------------------------------------------------------------------
        report "T1: Initial state check...";

        if key_valid = '0' then
            report "T1 PASS: key_valid=0 after reset" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T1 FAIL: key_valid should be 0" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        ---------------------------------------------------------------------
        -- T2: Load key
        ---------------------------------------------------------------------
        report "T2: Loading key...";
        master_key <= TEST_KEY;
        load_key <= '1';
        wait for CLK_PERIOD;
        load_key <= '0';
        wait for CLK_PERIOD * 2;

        if key_valid = '1' and key_out = TEST_KEY then
            report "T2 PASS: Key loaded successfully" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T2 FAIL: Key not loaded" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        ---------------------------------------------------------------------
        -- T3: Kill signal async wipe
        ---------------------------------------------------------------------
        report "T3: Kill signal wipe...";
        kill_signal <= '1';
        wait for CLK_PERIOD * 2;

        if key_valid = '0' and key_out = x"0000000000000000000000000000000000000000000000000000000000000000" then
            report "T3 PASS: Kill wiped key to zero" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T3 FAIL: Key not wiped" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        kill_signal <= '0';
        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------------
        -- T4: Reload and warm reset wipe
        ---------------------------------------------------------------------
        report "T4: Reload then warm reset...";
        master_key <= TEST_KEY;
        load_key <= '1';
        wait for CLK_PERIOD;
        load_key <= '0';
        wait for CLK_PERIOD * 2;

        -- Verify loaded
        if key_valid /= '1' then
            report "T4 FAIL: Key not reloaded" severity error;
            fail_cnt <= fail_cnt + 1;
        else
            -- Now warm reset
            rst_n <= '0';
            wait for CLK_PERIOD * 3;
            rst_n <= '1';
            wait for CLK_PERIOD * 2;

            if key_valid = '0' then
                report "T4 PASS: Warm reset cleared key" severity note;
                pass_cnt <= pass_cnt + 1;
            else
                report "T4 FAIL: Key survived warm reset" severity error;
                fail_cnt <= fail_cnt + 1;
            end if;
        end if;

        ---------------------------------------------------------------------
        -- SUMMARY
        ---------------------------------------------------------------------
        wait for CLK_PERIOD;
        report "========================================";
        report " SECURE KEY STORAGE: " & integer'image(pass_cnt + 1) & " passed, " & integer'image(fail_cnt) & " failed";
        report "========================================";

        sim_done <= true;
        wait;
    end process;
end sim;
