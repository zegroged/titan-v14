--------------------------------------------------------------------------------
-- TB: pf_hmac_responder — PolarFire HMAC Responder Verification
-- Tests: reset, challenge processing, response readiness, kill wipe, error
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_pf_hmac_responder is
end tb_pf_hmac_responder;

architecture sim of tb_pf_hmac_responder is

    constant CLK_PERIOD : time := 20 ns;
    constant TEST_KEY : std_logic_vector(255 downto 0) :=
        x"0123456789ABCDEF_FEDCBA9876543210_DEADBEEFCAFEBABE_0011223344556677";
    constant TEST_CHALLENGE : std_logic_vector(127 downto 0) :=
        x"AABBCCDD11223344_5566778899AABBCC";

    signal clk              : std_logic := '0';
    signal rst_n            : std_logic := '0';
    signal kill_signal      : std_logic := '0';
    signal hmac_key         : std_logic_vector(255 downto 0) := TEST_KEY;
    signal challenge_in     : std_logic_vector(127 downto 0) := (others => '0');
    signal challenge_valid  : std_logic := '0';
    signal response_tag     : std_logic_vector(255 downto 0);
    signal response_ready   : std_logic;
    signal busy             : std_logic;
    signal error            : std_logic;

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.pf_hmac_responder
        port map (
            clk             => clk,
            rst_n           => rst_n,
            kill_signal     => kill_signal,
            hmac_key        => hmac_key,
            challenge_in    => challenge_in,
            challenge_valid => challenge_valid,
            response_tag    => response_tag,
            response_ready  => response_ready,
            busy            => busy,
            error           => error
        );

    stim: process
    begin
        -----------------------------------------------------------------
        -- T1: Reset state
        -----------------------------------------------------------------
        report "T1: Reset state check";
        rst_n <= '0';
        wait for CLK_PERIOD * 5;

        assert response_ready = '0'
            report "T1 FAIL: response_ready not 0" severity failure;
        assert busy = '0'
            report "T1 FAIL: busy not 0" severity failure;
        assert error = '0'
            report "T1 FAIL: error not 0" severity failure;
        report "T1 PASS";

        -----------------------------------------------------------------
        -- T2: Challenge processing
        -----------------------------------------------------------------
        report "T2: Challenge processing";
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        challenge_in <= TEST_CHALLENGE;
        challenge_valid <= '1';
        wait for CLK_PERIOD;
        challenge_valid <= '0';

        -- Wait for HMAC to compute (typically ~100 cycles for SHA-256)
        for i in 0 to 1000 loop
            wait for CLK_PERIOD;
            if response_ready = '1' then
                report "T2 INFO: Response ready at cycle " & integer'image(i);
                exit;
            end if;
        end loop;

        assert response_ready = '1'
            report "T2 FAIL: response never became ready" severity failure;
        -- Tag should be non-zero (HMAC output)
        assert response_tag /= (255 downto 0 => '0')
            report "T2 FAIL: response_tag is zero (HMAC not computed)" severity failure;
        report "T2 PASS: Challenge processed, tag generated";

        -----------------------------------------------------------------
        -- T3: Kill signal wipe
        -----------------------------------------------------------------
        report "T3: Kill signal wipe";
        kill_signal <= '1';
        wait for CLK_PERIOD * 2;

        assert response_ready = '0'
            report "T3 FAIL: response_ready not 0 after kill" severity failure;
        assert response_tag = (255 downto 0 => '0')
            report "T3 FAIL: tag not zeroed after kill" severity failure;
        report "T3 PASS: Kill wipe works";

        kill_signal <= '0';
        wait for CLK_PERIOD * 2;

        -----------------------------------------------------------------
        -- T4: Second challenge after kill recovery
        -----------------------------------------------------------------
        report "T4: Re-challenge after kill";
        challenge_in <= x"DEADBEEF_CAFEBABE_01234567_89ABCDEF";
        challenge_valid <= '1';
        wait for CLK_PERIOD;
        challenge_valid <= '0';

        for i in 0 to 1000 loop
            wait for CLK_PERIOD;
            if response_ready = '1' then
                exit;
            end if;
        end loop;

        assert response_ready = '1'
            report "T4 FAIL: response not ready" severity failure;
        report "T4 PASS: Re-challenge after kill works";

        -----------------------------------------------------------------
        -- T5: Reset wipe
        -----------------------------------------------------------------
        report "T5: Reset wipe";
        rst_n <= '0';
        wait for CLK_PERIOD * 3;

        assert response_ready = '0'
            report "T5 FAIL: response_ready not 0" severity failure;
        report "T5 PASS";

        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -----------------------------------------------------------------
        report "ALL TESTS PASSED: tb_pf_hmac_responder";
        sim_done <= true;
        wait;
    end process;

end sim;
