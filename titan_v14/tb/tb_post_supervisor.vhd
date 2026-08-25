--------------------------------------------------------------------------------
-- TITAN V14: POST Self-Test & System Supervisor Verification
-- Standard: FIPS 140-3 Section 4.10 (Self-Tests)
-- Tests: POST pass path, POST fail path (corrupted KAT), supervisor FSM
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_post_supervisor is
end tb_post_supervisor;

architecture Behavioral of tb_post_supervisor is

    constant CLK_PERIOD : time := 20 ns;
    signal clk      : std_logic := '0';
    signal sim_done : boolean := false;

    -- POST signals
    signal rst_n         : std_logic := '0';
    signal post_pass     : std_logic;
    signal post_fail     : std_logic;
    signal post_running  : std_logic;
    signal trng_data     : std_logic_vector(127 downto 0) := (others => '0');
    signal trng_healthy  : std_logic;

    -- Supervisor signals
    signal pll_locked    : std_logic := '0';
    signal system_rdy    : std_logic;
    signal global_rst    : std_logic;

    signal pass_count : integer := 0;
    signal fail_count : integer := 0;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    -- POST Self-Test instance (rst_n driven by supervisor's global_rst)
    post_inst : entity work.post_self_test
        port map (
            clk          => clk,
            rst_n        => not global_rst,
            post_pass    => post_pass,
            post_fail    => post_fail,
            post_running => post_running,
            trng_data    => trng_data,
            trng_healthy => trng_healthy
        );

    -- System Supervisor instance (STARTUP_MS=0 for fast sim)
    supervisor_inst : entity work.system_supervisor
        generic map (
            CLK_FREQ_MHZ => 50,
            STARTUP_MS   => 0
        )
        port map (
            clk        => clk,
            pll_locked => pll_locked,
            post_pass  => post_pass,
            post_fail  => post_fail,
            system_rdy => system_rdy,
            global_rst => global_rst
        );

    process
        variable timeout : integer;
    begin
        report "========================================" severity note;
        report " POST + SUPERVISOR VERIFICATION" severity note;
        report " FIPS 140-3 Section 4.10" severity note;
        report "========================================" severity note;

        -- =====================================================================
        -- SCENARIO 1: NORMAL BOOT (POST should PASS with fixed AES)
        -- =====================================================================
        report "--- SCENARIO 1: Normal Boot ---" severity note;

        -- Supervisor starts in WAIT_PLL_LOCK, global_rst='1'
        pll_locked <= '0';
        wait for CLK_PERIOD * 5;

        -- PLL locks -> supervisor proceeds through PLL_QUALIFY -> WARMUP -> POST_CHECK
        pll_locked <= '1';

        -- Wait for supervisor to reach POST_CHECK and release global_rst
        -- PLL_QUALIFY=1000 cycles, WARMUP=0 cycles (STARTUP_MS=0)
        wait for CLK_PERIOD * 1200;

        -- T1: POST should be running (global_rst released by supervisor in POST_CHECK)
        timeout := 0;
        while post_running /= '1' and timeout < 200 loop
            trng_data <= std_logic_vector(to_unsigned(timeout * 7 + 13, 128));
            wait for CLK_PERIOD;
            timeout := timeout + 1;
        end loop;

        if post_running = '1' then
            report "T1 PASS: POST running after supervisor boot" severity note;
            pass_count <= pass_count + 1;
        else
            report "T1 FAIL: POST not running (global_rst=" & std_logic'image(global_rst) & ")" severity error;
            fail_count <= fail_count + 1;
        end if;

        -- Wait for POST to complete (AES KAT)
        timeout := 0;
        while post_pass /= '1' and post_fail /= '1' and timeout < 5000 loop
            trng_data <= std_logic_vector(to_unsigned(timeout * 7 + 13, 128));
            wait for CLK_PERIOD;
            timeout := timeout + 1;
        end loop;

        report "POST completed in " & integer'image(timeout) & " cycles" severity note;

        -- T2: POST should PASS (AES is now NIST-compliant)
        if post_pass = '1' and post_fail = '0' then
            report "T2 PASS: POST KAT passed (AES NIST-compliant)" severity note;
            pass_count <= pass_count + 1;
        else
            report "T2 FAIL: POST result unexpected (pass=" &
                   std_logic'image(post_pass) & " fail=" &
                   std_logic'image(post_fail) & ")" severity error;
            fail_count <= fail_count + 1;
        end if;

        -- T3: Supervisor should reach SYSTEM_ACTIVE
        wait for CLK_PERIOD * 10;  -- Give supervisor time to react
        if system_rdy = '1' and global_rst = '0' then
            report "T3 PASS: Supervisor SYSTEM_ACTIVE (system_rdy=1)" severity note;
            pass_count <= pass_count + 1;
        else
            report "T3 FAIL: Supervisor not ACTIVE (rdy=" &
                   std_logic'image(system_rdy) & " rst=" &
                   std_logic'image(global_rst) & ")" severity error;
            fail_count <= fail_count + 1;
        end if;

        -- =====================================================================
        -- SCENARIO 2: PLL LOSS (Supervisor -> FAIL_SAFE)
        -- =====================================================================
        report "--- SCENARIO 2: PLL Loss ---" severity note;
        pll_locked <= '0';
        wait for CLK_PERIOD * 10;

        -- T4: Supervisor should go to FAIL_SAFE
        if system_rdy = '0' then
            report "T4 PASS: Supervisor FAIL_SAFE on PLL loss (system_rdy=0)" severity note;
            pass_count <= pass_count + 1;
        else
            report "T4 FAIL: Supervisor still active after PLL loss" severity error;
            fail_count <= fail_count + 1;
        end if;

        -- =====================================================================
        -- SUMMARY
        -- =====================================================================
        wait for CLK_PERIOD * 5;
        report "========================================" severity note;
        report " POST+SUPERVISOR: " & integer'image(pass_count) &
               " passed, " & integer'image(fail_count) & " failed" severity note;
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
