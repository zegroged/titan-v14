--------------------------------------------------------------------------------
-- TITAN V14: Watchdog Monitor V2 Verification
-- FAZ 4: Φ4 Kimseye Güvenme — MAD Heartbeat Hardening
-- Tests: grace period, single timeout recovery, 3-fail kill, heartbeat keeps alive
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_watchdog_v2 is
end tb_watchdog_v2;

architecture Behavioral of tb_watchdog_v2 is

    constant CLK_PERIOD : time := 20 ns;  -- 50 MHz

    -- Kisa sureler (test icin hizli)
    constant TEST_CLK_MHZ     : integer := 1;     -- 1 MHz (hizli sim)
    constant TEST_TIMEOUT_MS  : integer := 1;      -- 1ms timeout
    constant TEST_GRACE_MS    : integer := 2;      -- 2ms grace
    constant TEST_MAX_FAIL    : integer := 3;      -- 3 ardisik hata = kill
    -- Gercek calisma: TIMEOUT_CYCLES = 1 * 1000 * 1 = 1000 cycle
    -- Grace: 1 * 1000 * 2 = 2000 cycle

    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal heartbeat    : std_logic := '0';
    signal kill_trigger : std_logic;
    signal fail_cnt_out : std_logic_vector(1 downto 0);
    signal grace_out    : std_logic;

    signal sim_done : boolean := false;
    signal pass_count : integer := 0;
    signal fail_count : integer := 0;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    dut : entity work.watchdog_monitor
        generic map (
            CLK_FREQ_MHZ     => TEST_CLK_MHZ,
            TIMEOUT_MS       => TEST_TIMEOUT_MS,
            MAX_FAIL_COUNT   => TEST_MAX_FAIL,
            BOOT_GRACE_MS    => TEST_GRACE_MS
        )
        port map (
            clk              => clk,
            rst_n            => rst_n,
            target_heartbeat => heartbeat,
            kill_trigger     => kill_trigger,
            fail_count_out   => fail_cnt_out,
            grace_active     => grace_out
        );

    process
        -- Heartbeat toggle procedure
        procedure do_heartbeat is
        begin
            wait until rising_edge(clk);
            heartbeat <= not heartbeat;
        end procedure;

        -- Wait N clock cycles
        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;
    begin
        report "========================================" severity note;
        report " WATCHDOG MONITOR V2 VERIFICATION" severity note;
        report " FAZ 4: MAD Heartbeat Hardening" severity note;
        report "========================================" severity note;

        -- Reset
        rst_n <= '0';
        wait_cycles(5);
        rst_n <= '1';
        wait_cycles(5);

        ---------------------------------------------------------------
        -- TEST 1: Grace period — no kill during boot
        ---------------------------------------------------------------
        -- Grace = 2000 cycles. Don't send heartbeat. Should NOT kill.
        wait_cycles(1500);  -- Still within grace

        if kill_trigger = '0' then
            report "T1 PASS: No kill during grace period" severity note;
            pass_count <= pass_count + 1;
        else
            report "T1 FAIL: Kill triggered during grace!" severity error;
            fail_count <= fail_count + 1;
        end if;

        if grace_out = '1' then
            report "T1b PASS: grace_active = '1'" severity note;
            pass_count <= pass_count + 1;
        else
            report "T1b FAIL: grace_active should be '1'" severity error;
            fail_count <= fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- TEST 2: Grace period ends
        ---------------------------------------------------------------
        -- Now start sending heartbeats before grace ends
        -- Grace = 2000 cycles. We're at ~1510. Send heartbeats.
        for i in 1 to 10 loop
            do_heartbeat;
            wait_cycles(50);
        end loop;

        -- Wait for grace to end
        wait_cycles(1000);  -- Total should be past 2000

        if grace_out = '0' then
            report "T2 PASS: Grace period ended" severity note;
            pass_count <= pass_count + 1;
        else
            report "T2 FAIL: Grace period still active" severity error;
            fail_count <= fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- TEST 3: Regular heartbeat keeps alive
        ---------------------------------------------------------------
        -- Send heartbeats regularly, well within timeout (1000 cycles)
        for i in 1 to 20 loop
            do_heartbeat;
            wait_cycles(200);  -- 200 < 1000 timeout
        end loop;

        if kill_trigger = '0' then
            report "T3 PASS: Regular heartbeat prevents kill" severity note;
            pass_count <= pass_count + 1;
        else
            report "T3 FAIL: Kill triggered despite heartbeat!" severity error;
            fail_count <= fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- TEST 4: Single timeout — fail_counter increments, no kill
        ---------------------------------------------------------------
        -- Stop heartbeat, wait for 1 timeout
        wait_cycles(1100);  -- > 1000 timeout cycles

        if kill_trigger = '0' then
            report "T4 PASS: Single timeout, no kill (fail_counter=1)" severity note;
            pass_count <= pass_count + 1;
        else
            report "T4 FAIL: Kill on first timeout!" severity error;
            fail_count <= fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- TEST 5: Heartbeat recovery after single timeout
        ---------------------------------------------------------------
        -- Send heartbeat to reset fail counter
        do_heartbeat;
        wait_cycles(10);

        if kill_trigger = '0' then
            report "T5 PASS: Heartbeat recovers after single timeout" severity note;
            pass_count <= pass_count + 1;
        else
            report "T5 FAIL: Kill not cleared after recovery!" severity error;
            fail_count <= fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- TEST 6: 3 consecutive timeouts — KILL!
        ---------------------------------------------------------------
        -- Stop heartbeat and wait for 3 full timeouts
        wait_cycles(1100);  -- timeout 1
        wait_cycles(1100);  -- timeout 2
        wait_cycles(1100);  -- timeout 3

        if kill_trigger = '1' then
            report "T6 PASS: 3 consecutive timeouts = KILL" severity note;
            pass_count <= pass_count + 1;
        else
            report "T6 FAIL: No kill after 3 consecutive timeouts!" severity error;
            fail_count <= fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- TEST 7: Kill is latched — heartbeat can't rescue
        ---------------------------------------------------------------
        do_heartbeat;
        wait_cycles(50);
        do_heartbeat;
        wait_cycles(50);

        if kill_trigger = '1' then
            report "T7 PASS: Kill latched, heartbeat can't rescue" severity note;
            pass_count <= pass_count + 1;
        else
            report "T7 FAIL: Kill unlatched by heartbeat!" severity error;
            fail_count <= fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- FINAL VERDICT
        ---------------------------------------------------------------
        wait_cycles(3);
        report "========================================" severity note;
        report " WATCHDOG V2: " & integer'image(pass_count) & " passed, " & integer'image(fail_count) & " failed" severity note;
        if fail_count = 0 then
            report " VERDICT: PASS" severity note;
        else
            report " VERDICT: FAIL" severity error;
        end if;
        report "========================================" severity note;

        sim_done <= true;
        wait;
    end process;

end Behavioral;
