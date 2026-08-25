--------------------------------------------------------------------------------
-- TB: secure_key_storage — Key Vault Verification
-- Tests: reset, key load, async kill wipe, sync reset wipe, key_valid flag
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_secure_key_storage is
end tb_secure_key_storage;

architecture sim of tb_secure_key_storage is

    constant CLK_PERIOD : time := 20 ns;
    constant TEST_KEY : std_logic_vector(255 downto 0) :=
        x"0123456789ABCDEF_FEDCBA9876543210_DEADBEEFCAFEBABE_0011223344556677";

    signal clk         : std_logic := '0';
    signal rst_n       : std_logic := '1';
    signal kill_signal : std_logic := '0';
    signal load_key    : std_logic := '0';
    signal master_key  : std_logic_vector(255 downto 0) := (others => '0');
    signal aes_busy    : std_logic := '1';  -- ★ V15 P0-2: default '1' for backward compat
    signal key_out     : std_logic_vector(255 downto 0);
    signal key_valid   : std_logic;
    signal round_keys  : std_logic_vector(1919 downto 0);

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.secure_key_storage
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => kill_signal,
            load_key    => load_key,
            master_key  => master_key,
            aes_busy    => aes_busy,  -- ★ V15 P0-2: key output gating
            key_out     => key_out,
            key_valid   => key_valid,
            round_keys  => round_keys
        );

    stim: process
    begin
        -----------------------------------------------------------------
        -- T1: Initial state -- key_valid = 0, key_out = 0
        -----------------------------------------------------------------
        report "T1: Initial state check";
        wait for CLK_PERIOD * 3;
        assert key_valid = '0'
            report "T1 FAIL: key_valid not 0" severity failure;
        assert key_out = (255 downto 0 => '0')
            report "T1 FAIL: key_out not zero" severity failure;
        report "T1 PASS";

        -----------------------------------------------------------------
        -- T2: Key load -- master_key -> stored, valid = 1
        -----------------------------------------------------------------
        report "T2: Key load test";
        master_key <= TEST_KEY;
        load_key <= '1';
        wait for CLK_PERIOD;
        load_key <= '0';
        wait for CLK_PERIOD * 2;

        assert key_valid = '1'
            report "T2 FAIL: key_valid not 1 after load" severity failure;
        assert key_out = TEST_KEY
            report "T2 FAIL: key_out mismatch" severity failure;
        report "T2 PASS: Key loaded correctly";

        -----------------------------------------------------------------
        -- T3: Async kill wipe -- key zeroed IMMEDIATELY
        -----------------------------------------------------------------
        report "T3: Async kill wipe";
        kill_signal <= '1';
        wait for 1 ns;  -- Async: should take effect immediately

        assert key_valid = '0'
            report "T3 FAIL: key_valid not 0 after kill" severity failure;
        assert key_out = (255 downto 0 => '0')
            report "T3 FAIL: key_out not zeroed after kill" severity failure;
        report "T3 PASS: Async kill wipe works";

        kill_signal <= '0';
        wait for CLK_PERIOD * 2;

        -----------------------------------------------------------------
        -- T4: Key re-load after kill
        -----------------------------------------------------------------
        report "T4: Re-load after kill";
        master_key <= TEST_KEY;
        load_key <= '1';
        wait for CLK_PERIOD;
        load_key <= '0';
        wait for CLK_PERIOD * 2;

        assert key_valid = '1'
            report "T4 FAIL: key_valid not 1" severity failure;
        assert key_out = TEST_KEY
            report "T4 FAIL: key mismatch" severity failure;
        report "T4 PASS: Re-load after kill works";

        -----------------------------------------------------------------
        -- T5: Sync reset (rst_n) wipe
        -----------------------------------------------------------------
        report "T5: Sync reset wipe";
        rst_n <= '0';
        wait for CLK_PERIOD * 2;

        assert key_valid = '0'
            report "T5 FAIL: key_valid not 0 after rst_n" severity failure;
        assert key_out = (255 downto 0 => '0')
            report "T5 FAIL: key not zeroed after rst_n" severity failure;
        report "T5 PASS: Sync reset wipe works";

        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -----------------------------------------------------------------
        -- T6: round_keys always zero (legacy stub)
        -----------------------------------------------------------------
        report "T6: round_keys legacy stub";
        assert round_keys = (1919 downto 0 => '0')
            report "T6 FAIL: round_keys not zero" severity failure;
        report "T6 PASS";

        -----------------------------------------------------------------
        report "ALL TESTS PASSED: tb_secure_key_storage";
        sim_done <= true;
        wait;
    end process;

end sim;
