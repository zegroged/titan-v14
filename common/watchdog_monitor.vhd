--------------------------------------------------------------------------------
-- PROJECT TITAN V13: Watchdog Monitor (Bekçi Köpeği)
-- Module: Cross-FPGA Heartbeat Monitor - "Dead Man's Switch"
--------------------------------------------------------------------------------
-- AMAÇ: Bir FPGA'nın canlılığını izlemek ve donma/kablo kopması durumunda
--       kill sinyali göndermek.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity watchdog_monitor is
    generic (
        CLK_FREQ_MHZ : integer := 50;    -- Sistem saati frekansı (MHz)
        TIMEOUT_MS   : integer := 1500   -- 1.5 Saniye Tolerans
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        target_heartbeat: in  std_logic;  -- Hedef FPGA'dan gelen heartbeat
        
        kill_trigger    : out std_logic   -- Eğer hedef öldüyse, KILL bas!
    );
end watchdog_monitor;

architecture Behavioral of watchdog_monitor is

    -------------------------------------------------------------------------
    -- TIMEOUT HESAPLAMA
    -------------------------------------------------------------------------
    constant TIMEOUT_CYCLES : integer := CLK_FREQ_MHZ * 1000 * TIMEOUT_MS;
    
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
    -- SYNTHESIS PROTECTION
    -------------------------------------------------------------------------
    attribute keep : string;
    attribute keep of timer_cnt : signal is "true";
    attribute keep of heartbeat_sync : signal is "true";
    
    attribute syn_keep : boolean;
    attribute syn_keep of timer_cnt : signal is true;
    attribute syn_keep of heartbeat_sync : signal is true;

begin

    -------------------------------------------------------------------------
    -- WATCHDOG PROCESS
    -------------------------------------------------------------------------
    process(clk, rst_n)
        variable ones_count : integer range 0 to 5;
    begin
        if rst_n = '0' then
            timer_cnt <= 0;
            kill_trigger <= '0';
            heartbeat_sync <= (others => '0');
            last_heartbeat <= '0';
            vote_shift <= (others => '0');
            vote_result <= '0';
            
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
            
            -- 3. EDGE DETECTION (on filtered signal)
            if vote_result /= last_heartbeat then
                timer_cnt <= 0;
                last_heartbeat <= vote_result;
                kill_trigger <= '0';
                
            else
                if timer_cnt < TIMEOUT_CYCLES then
                    timer_cnt <= timer_cnt + 1;
                else
                    -- TIMEOUT! Target is dead.
                    kill_trigger <= '1';
                end if;
            end if;
        end if;
    end process;

end Behavioral;
