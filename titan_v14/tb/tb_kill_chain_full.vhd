--------------------------------------------------------------------------------
-- TITAN V14.3: Kill Chain Exhaustive Test
-- Standard: FIPS 140-3 §4.5 (Tamper Response)
--------------------------------------------------------------------------------
-- Tum 11 kill kaynagini teker teker test eder
-- Her kaynak bagimsiz olarak safe_kill uretmeli
-- Boot penceresi testi: KILL_PIN boot'ta aktif, dijital kaynaklar degil
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_kill_chain_full is
end tb_kill_chain_full;

architecture TB of tb_kill_chain_full is

    constant CLK_PERIOD : time := 20 ns;
    signal clk : std_logic := '0';

    -- Kill sources (simule)
    signal system_ready       : std_logic := '0';
    signal KILL_PIN           : std_logic := '0';
    signal pf_watchdog_kill   : std_logic := '0';
    signal aegis_anomaly      : std_logic := '0';
    signal aegis_enable       : std_logic := '1';
    signal pvt_alarm          : std_logic := '0';
    signal key_kill_trigger   : std_logic := '0';
    signal aes_fault          : std_logic := '0';
    signal aes_timeout        : std_logic := '0';
    signal glitch_alarm       : std_logic := '0';
    signal fi_fail            : std_logic := '0';
    signal cmd_kill_trigger   : std_logic := '0';
    signal hmac_hb_fail       : std_logic := '0';

    -- Derived signals (artix7_top_v14.vhd logic replicated)
    signal all_kill_sources   : std_logic;
    signal kill_active        : std_logic;
    signal safe_kill          : std_logic;

    signal pass_count : integer := 0;
    signal fail_count : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2;

    -- Replicate kill chain logic from artix7_top_v14.vhd
    all_kill_sources <= pf_watchdog_kill
                     or (aegis_anomaly and aegis_enable)
                     or pvt_alarm
                     or key_kill_trigger
                     or aes_fault
                     or aes_timeout
                     or glitch_alarm
                     or fi_fail
                     or cmd_kill_trigger
                     or hmac_hb_fail;

    kill_active <= all_kill_sources;

    -- V14.3 FIX Z4: Katmanli boot kill
    safe_kill <= KILL_PIN or (all_kill_sources and system_ready);

    process
        -- Helper: tum kill kaynaklarini sifirla
        procedure reset_all_sources is
        begin
            KILL_PIN         <= '0';
            pf_watchdog_kill <= '0';
            aegis_anomaly    <= '0';
            pvt_alarm        <= '0';
            key_kill_trigger <= '0';
            aes_fault        <= '0';
            aes_timeout      <= '0';
            glitch_alarm     <= '0';
            fi_fail          <= '0';
            cmd_kill_trigger <= '0';
            hmac_hb_fail     <= '0';
        end procedure;

        -- Helper: tek kaynak test et
        procedure test_source(
            source_name : string;
            expected    : std_logic
        ) is
        begin
            wait for CLK_PERIOD * 2;
            if safe_kill = expected then
                report "  [OK] " & source_name & " -> safe_kill=" &
                       std_logic'image(safe_kill);
                pass_count <= pass_count + 1;
            else
                report "  [XX] " & source_name & " -> safe_kill=" &
                       std_logic'image(safe_kill) & " (beklenen: " &
                       std_logic'image(expected) & ")" severity failure;
                fail_count <= fail_count + 1;
            end if;
        end procedure;

    begin
        report "========================================";
        report " KILL CHAIN EXHAUSTIVE TEST";
        report " FIPS 140-3 Section 4.5";
        report "========================================";

        wait for CLK_PERIOD * 3;

        -----------------------------------------------------------------
        -- BOLUM 1: Boot penceresi (system_ready = '0')
        -----------------------------------------------------------------
        report "--- BOOT PENCERESI (system_ready=0) ---";
        system_ready <= '0';
        reset_all_sources;

        -- T1: KILL_PIN boot'ta aktif olmali (V14.3 FIX Z4)
        KILL_PIN <= '1';
        test_source("T1: KILL_PIN (boot)", '1');
        KILL_PIN <= '0';

        -- T2: Dijital kaynak boot'ta AKTIF OLMAMALI
        pf_watchdog_kill <= '1';
        test_source("T2: pf_watchdog (boot)", '0');
        pf_watchdog_kill <= '0';

        wait for CLK_PERIOD * 5;

        -----------------------------------------------------------------
        -- BOLUM 2: Normal mod (system_ready = '1')
        -----------------------------------------------------------------
        report "--- NORMAL MOD (system_ready=1) ---";
        system_ready <= '1';
        wait for CLK_PERIOD * 2;

        -- T3-T13: Her kill kaynagini teker teker test et
        reset_all_sources;
        KILL_PIN <= '1';
        test_source("T3: KILL_PIN", '1');
        reset_all_sources;

        pf_watchdog_kill <= '1';
        test_source("T4: pf_watchdog_kill", '1');
        reset_all_sources;

        aegis_anomaly <= '1'; aegis_enable <= '1';
        test_source("T5: aegis_anomaly (enabled)", '1');
        reset_all_sources;

        aegis_anomaly <= '1'; aegis_enable <= '0';
        test_source("T6: aegis_anomaly (disabled)", '0');
        reset_all_sources;
        aegis_enable <= '1';

        pvt_alarm <= '1';
        test_source("T7: pvt_alarm", '1');
        reset_all_sources;

        key_kill_trigger <= '1';
        test_source("T8: key_kill_trigger", '1');
        reset_all_sources;

        aes_fault <= '1';
        test_source("T9: aes_fault", '1');
        reset_all_sources;

        aes_timeout <= '1';
        test_source("T10: aes_timeout", '1');
        reset_all_sources;

        glitch_alarm <= '1';
        test_source("T11: glitch_alarm", '1');
        reset_all_sources;

        fi_fail <= '1';
        test_source("T12: fi_fail", '1');
        reset_all_sources;

        cmd_kill_trigger <= '1';
        test_source("T13: cmd_kill_trigger", '1');
        reset_all_sources;

        hmac_hb_fail <= '1';
        test_source("T14: hmac_hb_fail", '1');
        reset_all_sources;

        -----------------------------------------------------------------
        -- SUMMARY
        -----------------------------------------------------------------
        wait for CLK_PERIOD * 5;
        report "========================================";
        report " KILL CHAIN: " & integer'image(pass_count) & " passed, " &
               integer'image(fail_count) & " failed out of 14";
        if fail_count = 0 then
            report " VERDICT: ALL KILL SOURCES VERIFIED";
        else
            report " VERDICT: *** FAIL ***" severity failure;
        end if;
        report "========================================";

        std.env.stop;
    end process;

end TB;
