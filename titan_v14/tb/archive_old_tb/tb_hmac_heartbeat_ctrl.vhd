--------------------------------------------------------------------------------
-- PROJECT TITAN V14: HMAC Heartbeat Controller Testbench
-- Tests: Challenge-response flow, timeout fail, kill zeroize, combined_hb_ok
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_hmac_heartbeat_ctrl is
end tb_hmac_heartbeat_ctrl;

architecture sim of tb_hmac_heartbeat_ctrl is

    constant CLK_PERIOD : time := 20 ns;  -- 50 MHz
    -- Use tiny intervals for simulation speed
    constant SIM_CLK_FREQ    : integer := 50;
    constant SIM_INTERVAL_MS : integer := 1;  -- 1ms = 50,000 cycles

    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal kill_signal  : std_logic := '0';

    signal hmac_key     : std_logic_vector(255 downto 0) := (others => '0');
    signal trng_data    : std_logic_vector(31 downto 0)  := (others => '0');
    signal trng_valid   : std_logic := '0';

    signal challenge_out   : std_logic_vector(127 downto 0);
    signal challenge_valid : std_logic;
    signal response_in     : std_logic_vector(255 downto 0) := (others => '0');
    signal response_valid  : std_logic := '0';

    signal heartbeat_ok   : std_logic;
    signal heartbeat_fail : std_logic;
    signal hmac_busy      : std_logic;

    signal toggle_hb_in   : std_logic := '1';
    signal combined_hb_ok : std_logic;

    signal sim_done : boolean := false;
    signal pass_cnt : integer := 0;
    signal fail_cnt : integer := 0;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2 when not sim_done;

    -- DUT
    uut : entity work.hmac_heartbeat_ctrl
        generic map (
            CLK_FREQ_MHZ          => SIM_CLK_FREQ,
            HEARTBEAT_INTERVAL_MS => SIM_INTERVAL_MS
        )
        port map (
            clk              => clk,
            rst_n            => rst_n,
            kill_signal      => kill_signal,
            hmac_key         => hmac_key,
            trng_data        => trng_data,
            trng_valid       => trng_valid,
            challenge_out    => challenge_out,
            challenge_valid  => challenge_valid,
            response_in      => response_in,
            response_valid   => response_valid,
            heartbeat_ok     => heartbeat_ok,
            heartbeat_fail   => heartbeat_fail,
            hmac_busy        => hmac_busy,
            toggle_hb_in     => toggle_hb_in,
            combined_hb_ok   => combined_hb_ok
        );

    -- Stimulus
    process
        -- Wait for challenge_valid to rise
        procedure wait_for_challenge(timeout_us : integer := 5000) is
            variable cnt : integer := 0;
        begin
            while challenge_valid /= '1' loop
                wait for CLK_PERIOD;
                cnt := cnt + 1;
                if cnt > timeout_us * 50 then
                    report "TIMEOUT waiting for challenge_valid" severity failure;
                end if;
            end loop;
        end procedure;

        -- Wait for heartbeat_ok or heartbeat_fail
        procedure wait_for_result(timeout_us : integer := 5000) is
            variable cnt : integer := 0;
        begin
            while heartbeat_ok /= '1' and heartbeat_fail /= '1' loop
                wait for CLK_PERIOD;
                cnt := cnt + 1;
                if cnt > timeout_us * 50 then
                    return;  -- timeout OK for some tests
                end if;
            end loop;
        end procedure;

    begin
        report "========================================";
        report " HMAC HEARTBEAT CTRL VERIFICATION";
        report "========================================";

        -- Reset sequence
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- Set a test key
        hmac_key <= x"0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF";
        wait for CLK_PERIOD;

        ---------------------------------------------------------------------
        -- T1: Challenge generation after interval elapsed
        ---------------------------------------------------------------------
        report "T1: Waiting for HMAC heartbeat challenge...";

        -- Supply TRNG data (FSM fetches 2x 32-bit words for 64-bit nonce)
        trng_data  <= x"DEADBEEF";
        trng_valid <= '1';

        wait_for_challenge(5000);

        if challenge_valid = '1' then
            report "T1 PASS: Challenge generated" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T1 FAIL: No challenge generated" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        -- Let challenge_valid deassert
        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------------
        -- T2: Wrong response => heartbeat_fail
        ---------------------------------------------------------------------
        report "T2: Sending WRONG response to trigger fail...";

        -- Send a deliberately wrong response
        response_in    <= (others => '1');  -- wrong tag
        response_valid <= '1';
        wait for CLK_PERIOD;
        response_valid <= '0';

        -- Wait for result
        wait for CLK_PERIOD * 10;

        if heartbeat_fail = '1' then
            report "T2 PASS: Wrong tag => heartbeat_fail asserted" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T2 FAIL: heartbeat_fail not asserted on wrong tag" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        ---------------------------------------------------------------------
        -- T3: Kill signal => zeroization
        ---------------------------------------------------------------------
        report "T3: Testing kill signal...";

        kill_signal <= '1';
        wait for CLK_PERIOD * 3;

        if heartbeat_ok = '0' and heartbeat_fail = '0' then
            report "T3 PASS: Kill cleared heartbeat status" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T3 FAIL: Kill did not clear heartbeat status" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        kill_signal <= '0';
        wait for CLK_PERIOD * 5;

        ---------------------------------------------------------------------
        -- T4: combined_hb_ok requires both toggle and HMAC
        ---------------------------------------------------------------------
        report "T4: Testing combined_hb_ok logic...";

        -- toggle_hb_in = '1' but HMAC heartbeat_ok = '0' after kill
        wait for CLK_PERIOD * 5;

        if combined_hb_ok = '0' then
            report "T4 PASS: combined_hb_ok = 0 when HMAC not OK" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T4 FAIL: combined_hb_ok should be 0" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        ---------------------------------------------------------------------
        -- T5: Recovery after kill -- new challenge cycle
        ---------------------------------------------------------------------
        report "T5: Recovery after kill -- waiting for new challenge...";

        wait_for_challenge(5000);

        if challenge_valid = '1' then
            report "T5 PASS: New challenge after kill recovery" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T5 FAIL: No challenge after kill recovery" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------------
        -- T6: toggle_hb_in = 0 => combined_hb_ok must be 0
        ---------------------------------------------------------------------
        report "T6: Testing toggle_hb_in = 0 effect...";

        toggle_hb_in <= '0';
        wait for CLK_PERIOD * 5;

        if combined_hb_ok = '0' then
            report "T6 PASS: toggle_hb_in=0 => combined_hb_ok=0" severity note;
            pass_cnt <= pass_cnt + 1;
        else
            report "T6 FAIL: combined_hb_ok should be 0 when toggle=0" severity error;
            fail_cnt <= fail_cnt + 1;
        end if;

        toggle_hb_in <= '1';

        ---------------------------------------------------------------------
        -- SUMMARY
        ---------------------------------------------------------------------
        wait for CLK_PERIOD;
        report "========================================";
        report " HMAC HEARTBEAT CTRL: " & integer'image(pass_cnt + 1) & " passed, " & integer'image(fail_cnt) & " failed";
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
