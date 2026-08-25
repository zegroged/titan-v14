--------------------------------------------------------------------------------
-- ★ P2 #28: PLL-Independent Watchdog (FPGA)
-- Clock tamper / glitch detection via independent ring oscillator
--
-- 1. Dahili ring oscillator (~10 MHz, PVT bağımlı)
-- 2. PLL çıkışı ile ring osc frekansını karşılaştır
-- 3. Frekans oranı tolerans dışında → clock tamper CARİ
-- 4. Clock tamper CARİ → kill_signal tetikle
--
-- Saldırı vektörü V32: Clock glitching → FSM atlama / güvenlik bypass.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pll_watchdog is
    generic (
        -- Expected ratio: sys_clk / ring_osc ≈ 10 (100MHz / 10MHz)
        EXPECTED_RATIO  : integer := 10;
        -- Tolerance: ±30% of expected ratio
        TOLERANCE_PCT   : integer := 30;
        -- Check interval: every 2^16 sys_clk cycles (~655µs at 100MHz)
        CHECK_INTERVAL  : integer := 65536
    );
    port (
        sys_clk         : in  std_logic;   -- Main system clock (PLL output)
        rst_n           : in  std_logic;
        
        -- Ring oscillator input (from FPGA internal oscillator or LUT chain)
        ring_osc_clk    : in  std_logic;
        
        -- Outputs
        clock_tamper    : out std_logic;   -- '1' = clock anomaly detected
        kill_trigger    : out std_logic;   -- '1' = kill signal (latched)
        
        -- Debug
        measured_ratio  : out std_logic_vector(7 downto 0)  -- Actual ratio
    );
end pll_watchdog;

architecture Behavioral of pll_watchdog is

    -- Counters
    signal sys_counter      : unsigned(15 downto 0) := (others => '0');
    signal ring_counter     : unsigned(15 downto 0) := (others => '0');
    signal ring_counter_sync: unsigned(15 downto 0) := (others => '0');
    
    -- Sampling
    signal sample_ring      : unsigned(15 downto 0) := (others => '0');
    signal check_pending    : std_logic := '0';
    
    -- Tamper detection (latched)
    signal tamper_latch     : std_logic := '0';
    signal consecutive_fail : unsigned(2 downto 0) := (others => '0');
    
    -- Tolerance bounds
    constant RATIO_MIN : integer := EXPECTED_RATIO - (EXPECTED_RATIO * TOLERANCE_PCT / 100);
    constant RATIO_MAX : integer := EXPECTED_RATIO + (EXPECTED_RATIO * TOLERANCE_PCT / 100);
    
    -- Synthesis protection
    attribute dont_touch : string;
    attribute dont_touch of sys_counter : signal is "true";
    attribute dont_touch of ring_counter : signal is "true";
    attribute dont_touch of tamper_latch : signal is "true";

begin

    -------------------------------------------------------------------------
    -- Ring Oscillator Counter (ring_osc_clk domain)
    -------------------------------------------------------------------------
    process(ring_osc_clk)
    begin
        if rising_edge(ring_osc_clk) then
            ring_counter <= ring_counter + 1;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- System Clock Domain: Sample + Check
    -------------------------------------------------------------------------
    process(sys_clk)
        variable ratio : integer;
    begin
        if rising_edge(sys_clk) then
            if rst_n = '0' then
                sys_counter      <= (others => '0');
                ring_counter_sync<= (others => '0');
                sample_ring      <= (others => '0');
                check_pending    <= '0';
                tamper_latch     <= '0';
                consecutive_fail <= (others => '0');
            else
                sys_counter <= sys_counter + 1;
                
                -- Synchronize ring counter (2-stage sync)
                ring_counter_sync <= ring_counter;
                
                -- Check interval reached
                if sys_counter = to_unsigned(CHECK_INTERVAL - 1, 16) then
                    sys_counter   <= (others => '0');
                    sample_ring   <= ring_counter_sync;
                    check_pending <= '1';
                end if;
                
                -- Evaluate ratio
                if check_pending = '1' then
                    check_pending <= '0';
                    
                    -- Ratio = sys_cycles / ring_cycles
                    if sample_ring /= 0 then
                        ratio := CHECK_INTERVAL / to_integer(sample_ring);
                    else
                        ratio := 0;  -- Ring osc dead → tamper
                    end if;
                    
                    measured_ratio <= std_logic_vector(to_unsigned(ratio, 8));
                    
                    -- Check bounds
                    if ratio < RATIO_MIN or ratio > RATIO_MAX then
                        -- Anomaly detected
                        if consecutive_fail < 3 then
                            consecutive_fail <= consecutive_fail + 1;
                        end if;
                        
                        -- 3 consecutive failures → hard tamper
                        if consecutive_fail >= 2 then
                            tamper_latch <= '1';  -- Latched — never clears
                        end if;
                    else
                        -- Normal — reset failure counter
                        consecutive_fail <= (others => '0');
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Outputs
    clock_tamper <= tamper_latch;
    kill_trigger <= tamper_latch;  -- Direct to kill chain

end Behavioral;
