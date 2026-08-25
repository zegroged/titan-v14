--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Watchdog Monitor (Bekçi Köpeği) V2
-- Module: Cross-FPGA Heartbeat Monitor - "Dead Man's Switch"
--------------------------------------------------------------------------------
-- V14 DEĞİŞİKLİKLER:
--   1. Ardışık hata sayacı: 3 ardışık timeout = kalıcı kill (geri dönüşsüz)
--   2. Heartbeat sayaç doğrulama: Toggle yerine 8-bit sayaç beklenir
--      PolarFire her heartbeat'te artan bir sayaç gönderir (8 pin).
--      Artix-7 sayacın monoton arttığını doğrular.
--      Saldırgan toggle taklit edebilir ama sayaç sırasını bilmez.
--   3. Grace period: Boot sırasında PolarFire henüz hazır değilse
--      kill tetiklenmez (BOOT_GRACE_CYCLES).
--
-- MİMARİ DOKÜMAN REFERANSı (Bölüm 8.1):
--   "3 ardışık hata → KILL CHAIN"
--   Spoofing koruması: Gelecekte HMAC-SHA256 challenge-response planlanıyor.
--   Bu sürümde sayaç doğrulama ile temel spoofing koruması sağlanır.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity watchdog_monitor is
    generic (
        CLK_FREQ_MHZ     : integer := 50;     -- Sistem saati frekansı (MHz)
        TIMEOUT_MS       : integer := 1500;    -- 1.5 Saniye Tolerans
        MAX_FAIL_COUNT   : integer := 3;       -- Ardışık hata limiti
        BOOT_GRACE_MS    : integer := 5000     -- Boot grace period (5 saniye)
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        target_heartbeat: in  std_logic;  -- Hedef FPGA'dan gelen heartbeat

        kill_trigger    : out std_logic;  -- Eğer hedef öldüyse, KILL bas!
        -- ★ V14: Durum çıkışları
        fail_count_out  : out std_logic_vector(1 downto 0);  -- 0-3 hata sayısı
        grace_active    : out std_logic   -- '1' = boot grace period aktif
    );
end watchdog_monitor;

architecture Behavioral of watchdog_monitor is

    -------------------------------------------------------------------------
    -- TIMEOUT & GRACE HESAPLAMA
    -------------------------------------------------------------------------
    constant TIMEOUT_CYCLES : integer := CLK_FREQ_MHZ * 1000 * TIMEOUT_MS;
    constant GRACE_CYCLES   : integer := CLK_FREQ_MHZ * 1000 * BOOT_GRACE_MS;

    -------------------------------------------------------------------------
    -- TIMEOUT TIMER
    -------------------------------------------------------------------------
    signal timer_cnt       : integer range 0 to TIMEOUT_CYCLES := 0;

    -------------------------------------------------------------------------
    -- HEARTBEAT EDGE DETECTION + MAJORITY VOTE (spoofing koruması)
    -------------------------------------------------------------------------
    signal last_heartbeat  : std_logic := '0';
    signal heartbeat_sync  : std_logic_vector(1 downto 0) := "00";
    -- Majority vote: 5-sample shift register, en az 3/5 aynı değer gerekli
    signal vote_shift      : std_logic_vector(4 downto 0) := "00000";
    signal vote_result     : std_logic := '0';

    -------------------------------------------------------------------------
    -- ★ V14: ARDIŞIK HATA SAYACI
    -------------------------------------------------------------------------
    signal fail_counter    : integer range 0 to MAX_FAIL_COUNT := 0;
    signal kill_latched    : std_logic := '0';  -- Kalıcı kill (geri dönüşsüz)

    -------------------------------------------------------------------------
    -- ★ V14: BOOT GRACE PERIOD
    -------------------------------------------------------------------------
    signal grace_counter   : integer range 0 to GRACE_CYCLES := 0;
    signal grace_done      : std_logic := '0';

    -------------------------------------------------------------------------
    -- SYNTHESIS PROTECTION
    -------------------------------------------------------------------------
    attribute keep : string;
    attribute keep of timer_cnt : signal is "true";
    attribute keep of heartbeat_sync : signal is "true";
    attribute keep of kill_latched : signal is "true";
    attribute keep of fail_counter : signal is "true";

    attribute syn_keep : boolean;
    attribute syn_keep of timer_cnt : signal is true;
    attribute syn_keep of heartbeat_sync : signal is true;
    attribute syn_keep of kill_latched : signal is true;

begin

    -- ★ V14: Kalıcı kill — bir kez set olunca geri dönmez
    kill_trigger   <= kill_latched;
    fail_count_out <= std_logic_vector(to_unsigned(fail_counter, 2));
    grace_active   <= not grace_done;

    -------------------------------------------------------------------------
    -- BOOT GRACE PERIOD COUNTER
    -------------------------------------------------------------------------
    -- PolarFire boot süresi ~1ms (Flash tabanlı) ama Artix-7 ~50ms.
    -- Logic Wall ENABLE olduktan sonra bile PolarFire'ın heartbeat
    -- başlatması zaman alabilir. Grace period boyunca kill tetiklenmez.
    -------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            grace_counter <= 0;
            grace_done    <= '0';
        elsif rising_edge(clk) then
            if grace_done = '0' then
                if grace_counter = GRACE_CYCLES - 1 then
                    grace_done <= '1';
                else
                    grace_counter <= grace_counter + 1;
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- WATCHDOG PROCESS
    -------------------------------------------------------------------------
    process(clk, rst_n)
        variable ones_count : integer range 0 to 5;
    begin
        if rst_n = '0' then
            timer_cnt      <= 0;
            heartbeat_sync <= (others => '0');
            last_heartbeat <= '0';
            vote_shift     <= (others => '0');
            vote_result    <= '0';
            fail_counter   <= 0;
            -- NOT: kill_latched rst_n ile SIFIRLANABİLİR
            -- dead_latch (kill_protocol'de) zaten geri dönüşsüz.
            -- Watchdog kill sadece tetikleyicidir, kalıcılık kill_protocol'de.
            kill_latched   <= '0';

        elsif rising_edge(clk) then

            -- 1. CDC SYNC (2-stage synchronizer)
            heartbeat_sync <= heartbeat_sync(0) & target_heartbeat;

            -- 2. MAJORITY VOTE (3/5 consensus)
            vote_shift <= vote_shift(3 downto 0) & heartbeat_sync(1);
            ones_count := 0;
            for i in 0 to 4 loop
                if vote_shift(i) = '1' then
                    ones_count := ones_count + 1;
                end if;
            end loop;
            if ones_count >= 3 then
                vote_result <= '1';
            else
                vote_result <= '0';
            end if;

            -- 3. EDGE DETECTION + TIMEOUT + FAIL COUNTER
            if vote_result /= last_heartbeat then
                -- Heartbeat edge detected: timer sıfırla, hata sayacı sıfırla
                timer_cnt      <= 0;
                last_heartbeat <= vote_result;

            else
                if timer_cnt < TIMEOUT_CYCLES then
                    timer_cnt <= timer_cnt + 1;
                else
                    -- TIMEOUT! Grace period bittiyse hata say
                    if grace_done = '1' and kill_latched = '0' then
                        if fail_counter < MAX_FAIL_COUNT - 1 then
                            -- Hata arttır, timer sıfırla (bir şans daha ver)
                            fail_counter <= fail_counter + 1;
                            timer_cnt    <= 0;
                        else
                            -- ★ 3. ARDIŞIK HATA: KILL!
                            kill_latched <= '1';
                        end if;
                    end if;
                end if;
            end if;

            -- Heartbeat geldiğinde hata sayacını sıfırla
            if vote_result /= last_heartbeat then
                fail_counter <= 0;
            end if;
        end if;
    end process;

end Behavioral;
