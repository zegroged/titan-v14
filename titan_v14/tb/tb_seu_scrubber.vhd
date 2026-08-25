--------------------------------------------------------------------------------
-- PROJECT TITAN V14.2: SEU Scrubber — Functional Testbench
-- Validates FSM transitions: IDLE → SCAN_INIT → SCAN_READ → REPORT → IDLE
-- NOTE: No real FRAME_ECCE2 — sim mode exercises logic only
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_seu_scrubber is
end tb_seu_scrubber;

architecture sim of tb_seu_scrubber is

    signal clk              : std_logic := '0';
    signal rst_n            : std_logic := '0';
    signal kill_signal      : std_logic := '0';
    signal enable           : std_logic := '0';
    signal force_scan       : std_logic := '0';

    signal scan_active      : std_logic;
    signal seu_detected     : std_logic;
    signal seu_critical     : std_logic;
    signal corrected_count  : std_logic_vector(15 downto 0);
    signal last_error_frame : std_logic_vector(15 downto 0);
    signal scan_count       : std_logic_vector(31 downto 0);
    signal state_dbg        : std_logic_vector(2 downto 0);

    constant CLK_PERIOD : time := 20 ns;
    signal test_done    : boolean := false;
    signal pass_count   : integer := 0;
    signal fail_count   : integer := 0;

begin

    -- Clock
    clk <= not clk after CLK_PERIOD / 2 when not test_done else '0';

    -- DUT: Small frame count + short interval for fast simulation
    DUT: entity work.seu_scrubber
        generic map (
            G_SCAN_INTERVAL => 100,   -- Very short for sim
            G_FRAME_COUNT   => 16,    -- Only 16 frames for fast test
            G_SIM_MODE      => true
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            kill_signal     => kill_signal,
            enable          => enable,
            force_scan      => force_scan,
            scan_active     => scan_active,
            seu_detected    => seu_detected,
            seu_critical    => seu_critical,
            corrected_count => corrected_count,
            last_error_frame=> last_error_frame,
            scan_count      => scan_count,
            state_dbg       => state_dbg
        );

    process
    begin
        report "========================================";
        report "TB_SEU_SCRUBBER: SEU Scrubber FSM Tests";
        report "========================================";

        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------
        -- TEST 1: Verify IDLE state after reset
        ---------------------------------------------------------------
        report "TEST 1: IDLE state after reset";
        if state_dbg = "000" and scan_active = '0' then
            pass_count <= pass_count + 1;
            report "  [PASS] State=IDLE, scan_active=0";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] Expected IDLE state" severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 2: Force scan trigger
        ---------------------------------------------------------------
        report "TEST 2: Force scan trigger";
        enable     <= '1';
        force_scan <= '1';
        wait for CLK_PERIOD;
        force_scan <= '0';

        -- Wait for scan to start
        wait for CLK_PERIOD * 3;
        if scan_active = '1' then
            pass_count <= pass_count + 1;
            report "  [PASS] Scan started after force trigger";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] Scan did not start" severity error;
        end if;

        -- Wait for scan to complete (16 frames + overhead)
        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if scan_active = '0' and state_dbg = "000" then
                exit;
            end if;
        end loop;

        if scan_count = x"00000001" then
            pass_count <= pass_count + 1;
            report "  [PASS] Scan completed, scan_count=1";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] scan_count=" & to_hstring(scan_count)
                severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 3: No SEU errors in simulation mode
        ---------------------------------------------------------------
        report "TEST 3: No SEU errors in sim mode";
        if corrected_count = x"0000" and seu_critical = '0' then
            pass_count <= pass_count + 1;
            report "  [PASS] No errors detected (expected in sim mode)";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] Unexpected errors" severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 4: Periodic scan via interval timer
        ---------------------------------------------------------------
        report "TEST 4: Periodic scan (interval=100 cycles)";

        -- Wait for interval to trigger next scan
        for i in 0 to 200 loop
            wait for CLK_PERIOD;
            if scan_active = '1' then
                exit;
            end if;
        end loop;

        if scan_active = '1' then
            pass_count <= pass_count + 1;
            report "  [PASS] Periodic scan triggered";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] Periodic scan not triggered" severity error;
        end if;

        -- Wait for it to complete
        for i in 0 to 50 loop
            wait for CLK_PERIOD;
            if scan_active = '0' then
                exit;
            end if;
        end loop;

        if scan_count = x"00000002" then
            pass_count <= pass_count + 1;
            report "  [PASS] Second scan completed, scan_count=2";
        else
            fail_count <= fail_count + 1;
            report "  [FAIL] scan_count=" & to_hstring(scan_count)
                severity error;
        end if;

        ---------------------------------------------------------------
        -- TEST 5: Kill signal resets all state
        ---------------------------------------------------------------
        report "TEST 5: Kill signal resets state";
        kill_signal <= '1';
        wait for CLK_PERIOD * 2;
        kill_signal <= '0';
        wait for CLK_PERIOD;

        if state_dbg = "000" and scan_count = x"00000000" then
            pass_count <= pass_count + 1;
            report "  [PASS] Kill reset all counters and state";
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
            report "*** TB_SEU_SCRUBBER: ALL TESTS PASSED ***";
        else
            report "*** TB_SEU_SCRUBBER: " & integer'image(fail_count) & " FAILURES ***"
                severity failure;
        end if;
        report "========================================";

        test_done <= true;
        wait;
    end process;

end sim;
