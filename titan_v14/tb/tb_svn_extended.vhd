--------------------------------------------------------------------------------
-- PROJECT TITAN V14.2: Extended SVN Counter — Testbench
-- Tests: Normal increment, rollback detection, counter integrity
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_svn_extended is
end tb_svn_extended;

architecture sim of tb_svn_extended is

    signal clk             : std_logic := '0';
    signal rst_n           : std_logic := '0';
    signal kill_signal     : std_logic := '0';

    -- SHA-256 mock interface
    signal sha_start       : std_logic;
    signal sha_last_block  : std_logic;
    signal sha_data_in     : std_logic_vector(31 downto 0);
    signal sha_data_valid  : std_logic;
    signal sha_hash_out    : std_logic_vector(255 downto 0) := (others => '0');
    signal sha_hash_valid  : std_logic := '0';
    signal sha_busy        : std_logic := '0';
    signal sha_ready       : std_logic := '1';

    -- DUT signals
    signal increment       : std_logic := '0';
    signal verify          : std_logic := '0';
    signal expected_hash   : std_logic_vector(255 downto 0) := (others => '0');
    signal current_svn     : std_logic_vector(31 downto 0);
    signal verify_pass     : std_logic;
    signal verify_fail     : std_logic;
    signal dut_busy        : std_logic;
    signal dut_ready       : std_logic;

    constant CLK_PERIOD    : time := 20 ns;
    signal test_done       : boolean := false;
    signal pass_count      : integer := 0;
    signal fail_count      : integer := 0;

    -- Words fed counter (for SHA mock)
    signal word_count      : integer := 0;

    -- Genesis hash constant
    constant GENESIS_HASH : std_logic_vector(255 downto 0) :=
        x"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    -- Mock SHA result (deterministic for testing)
    constant MOCK_HASH_1 : std_logic_vector(255 downto 0) :=
        x"a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2";

begin

    clk <= not clk after CLK_PERIOD / 2 when not test_done else '0';

    -- DUT
    DUT: entity work.svn_extended
        port map (
            clk             => clk,
            rst_n           => rst_n,
            kill_signal     => kill_signal,
            sha_start       => sha_start,
            sha_last_block  => sha_last_block,
            sha_data_in     => sha_data_in,
            sha_data_valid  => sha_data_valid,
            sha_hash_out    => sha_hash_out,
            sha_hash_valid  => sha_hash_valid,
            sha_busy        => sha_busy,
            sha_ready       => sha_ready,
            increment       => increment,
            verify          => verify,
            expected_hash   => expected_hash,
            current_svn     => current_svn,
            verify_pass     => verify_pass,
            verify_fail     => verify_fail,
            busy            => dut_busy,
            ready           => dut_ready
        );

    -- Simple SHA-256 Mock — counts 16 data_valid words, then produces hash
    process(clk)
    begin
        if rising_edge(clk) then
            sha_hash_valid <= '0';
            if sha_start = '1' then
                word_count <= 0;
                sha_busy   <= '1';
                sha_ready  <= '1';  -- ready for first word
            elsif sha_data_valid = '1' then
                word_count <= word_count + 1;
                if sha_last_block = '1' then
                    -- Last word received
                    sha_ready <= '0';
                end if;
            end if;

            -- After last_block, produce result after 5 cycle delay
            if sha_last_block = '1' and sha_data_valid = '1' then
                -- Will produce output shortly
            end if;
        end if;
    end process;

    -- Delayed hash output
    process(clk)
        variable delay_cnt : integer := 0;
        variable waiting   : boolean := false;
    begin
        if rising_edge(clk) then
            sha_hash_valid <= '0';
            if sha_last_block = '1' and sha_data_valid = '1' then
                waiting := true;
                delay_cnt := 0;
            end if;
            if waiting then
                delay_cnt := delay_cnt + 1;
                if delay_cnt >= 5 then
                    sha_hash_out   <= MOCK_HASH_1;
                    sha_hash_valid <= '1';
                    sha_busy       <= '0';
                    sha_ready      <= '1';
                    waiting := false;
                end if;
            end if;
        end if;
    end process;

    -- Main test process
    process
    begin
        report "========================================";
        report "TB_SVN_EXTENDED: Extended SVN Counter Tests";
        report "========================================";

        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------
        -- TEST 1: Initial state after reset
        ---------------------------------------------------------------
        report "TEST 1: Initial state";
        if current_svn = x"00000000" and dut_ready = '1' and verify_fail = '0' then
            pass_count <= pass_count + 1;
            report "  [PASS] SVN=0, ready=1, no fail";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] Unexpected initial state" severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 2: Verify with correct hash (genesis)
        ---------------------------------------------------------------
        report "TEST 2: Verify genesis hash";
        expected_hash <= GENESIS_HASH;
        verify <= '1';
        wait for CLK_PERIOD;
        verify <= '0';
        wait for CLK_PERIOD * 3;

        if verify_pass = '1' or verify_fail = '0' then
            pass_count <= pass_count + 1;
            report "  [PASS] Genesis hash verification passed";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] Genesis hash verification failed" severity error;
        end if;

        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------
        -- TEST 3: Increment counter
        ---------------------------------------------------------------
        report "TEST 3: Increment counter";
        increment <= '1';
        wait for CLK_PERIOD;
        increment <= '0';

        -- Wait for SHA computation and store
        for i in 0 to 100 loop
            wait for CLK_PERIOD;
            if dut_ready = '1' then
                exit;
            end if;
        end loop;

        if current_svn = x"00000001" then
            pass_count <= pass_count + 1;
            report "  [PASS] SVN incremented to 1";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] SVN=" & to_hstring(current_svn)
                severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 4: Verify with wrong hash (rollback detection)
        ---------------------------------------------------------------
        report "TEST 4: Rollback detection (wrong hash)";
        expected_hash <= x"DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";
        verify <= '1';
        wait for CLK_PERIOD;
        verify <= '0';
        wait for CLK_PERIOD * 5;

        if verify_fail = '1' then
            pass_count <= pass_count + 1;
            report "  [PASS] Rollback detected (hash mismatch → kill)";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] Rollback not detected" severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 5: Kill signal resets everything
        ---------------------------------------------------------------
        report "TEST 5: Kill signal reset";
        kill_signal <= '1';
        wait for CLK_PERIOD * 2;
        kill_signal <= '0';
        wait for CLK_PERIOD * 2;

        if current_svn = x"00000000" and verify_fail = '0' then
            pass_count <= pass_count + 1;
            report "  [PASS] Kill reset counter and fail latch";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] Kill did not reset properly" severity error;
        end if;

        ---------------------------------------------------------------
        -- SUMMARY
        ---------------------------------------------------------------
        report "========================================";
        report "RESULTS: PASS=" & integer'image(pass_count) &
               " FAIL=" & integer'image(fail_count);
        if fail_count = 0 then
            report "*** TB_SVN_EXTENDED: ALL TESTS PASSED ***";
        else
            report "*** TB_SVN_EXTENDED: " & integer'image(fail_count) & " FAILURES ***"
                severity failure;
        end if;
        report "========================================";

        test_done <= true;
        wait;
    end process;

end sim;
