--------------------------------------------------------------------------------
-- AEGIS Phase 4.1: Ring Oscillator Frequency Counter (PVT Monitor)
--------------------------------------------------------------------------------
-- Counts edge transitions of the ring oscillator within a configurable
-- measurement window to infer temperature/voltage changes.
--
-- Architecture:
--   ring_osc_out ──► [2-stage CDC sync] ──► [Edge Detector] ──► [Counter]
--                                                                   │
--   sys_clk ──► [Window Timer] ─── gate ─────────────────────► [Latch]
--                                                                   │
--                           [Comparator] ◄──────────────────────────┘
--                               │
--                        ┌──────┴──────┐
--                    temp_alert    count_valid
--
-- CDC: 2-stage FF synchronizer for async ring_osc_out
-- Alarm: ±20% from calibrated nominal -> freeze attack / overheat
-- Measurement: count rising edges in window, report on completion
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ring_osc_counter is
    generic (
        -- System clock frequency (Hz)
        SYS_CLK_FREQ   : integer := 50_000_000;    -- 50 MHz
        -- Measurement window (milliseconds)
        MEASURE_MS      : integer := 1;             -- 1 ms window
        -- Nominal expected count (calibrated at room temp, 1.0V)
        NOMINAL_COUNT   : integer := 100_000;       -- ~100 MHz ring osc
        -- Alarm threshold: ±ALARM_PCT percent
        ALARM_PCT       : integer := 20
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Ring oscillator input (ASYNC clock domain!)
        ring_osc_out    : in  std_logic;

        -- Control
        measure_start   : in  std_logic;   -- Pulse: begin measurement
        continuous       : in  std_logic;   -- '1' = auto-repeat

        -- Outputs
        frequency_count : out std_logic_vector(23 downto 0);
        count_valid     : out std_logic;
        temp_alert      : out std_logic;   -- Latching: outside ±20%

        -- Alert control
        clear_alert     : in  std_logic;

        -- Diagnostic
        alert_high      : out std_logic;   -- Freq too high (cold/overvoltage)
        alert_low       : out std_logic    -- Freq too low  (hot/freeze attack)
    );
end entity ring_osc_counter;

architecture rtl of ring_osc_counter is

    -- ===== Window timer constants =====
    -- Window length in sys_clk cycles
    constant WINDOW_CYCLES : integer := (SYS_CLK_FREQ / 1000) * MEASURE_MS;

    -- Alarm thresholds (pre-computed)
    constant ALARM_UPPER : integer := NOMINAL_COUNT +
                                      (NOMINAL_COUNT * ALARM_PCT / 100);
    constant ALARM_LOWER : integer := NOMINAL_COUNT -
                                      (NOMINAL_COUNT * ALARM_PCT / 100);

    -- ===== CDC synchronizer =====
    signal sync_ff1 : std_logic := '0';
    signal sync_ff2 : std_logic := '0';
    signal sync_ff3 : std_logic := '0';  -- For edge detection

    -- Prevent optimization of synchronizer chain
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sync_ff1 : signal is "TRUE";
    attribute ASYNC_REG of sync_ff2 : signal is "TRUE";

    -- ===== Edge detector =====
    signal edge_pulse : std_logic;

    -- ===== Counting FSM =====
    type fsm_t is (F_IDLE, F_COUNTING, F_REPORT);
    signal fsm : fsm_t;

    signal window_cnt   : unsigned(23 downto 0);  -- Window timer
    signal edge_cnt     : unsigned(23 downto 0);  -- Edge counter
    signal result_reg   : unsigned(23 downto 0);  -- Latched result

    -- ===== Alarm =====
    signal alert_latch  : std_logic;
    signal alert_hi_reg : std_logic;
    signal alert_lo_reg : std_logic;
    signal valid_reg    : std_logic;

begin

    -- ===== Outputs =====
    frequency_count <= std_logic_vector(result_reg);
    count_valid     <= valid_reg;
    temp_alert      <= alert_latch;
    alert_high      <= alert_hi_reg;
    alert_low       <= alert_lo_reg;

    -- ===== 2-Stage CDC Synchronizer =====
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            sync_ff1 <= '0';
            sync_ff2 <= '0';
            sync_ff3 <= '0';
        elsif rising_edge(clk) then
            sync_ff1 <= ring_osc_out;    -- Stage 1
            sync_ff2 <= sync_ff1;        -- Stage 2
            sync_ff3 <= sync_ff2;        -- Delay for edge detect
        end if;
    end process;

    -- Rising edge detection on synchronized signal
    edge_pulse <= sync_ff2 and not sync_ff3;

    -- ===== Measurement FSM =====
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            fsm         <= F_IDLE;
            window_cnt  <= (others => '0');
            edge_cnt    <= (others => '0');
            result_reg  <= (others => '0');
            valid_reg   <= '0';
            alert_latch <= '0';
            alert_hi_reg <= '0';
            alert_lo_reg <= '0';

        elsif rising_edge(clk) then
            valid_reg <= '0';   -- Pulse

            -- Alert clear
            if clear_alert = '1' then
                alert_latch  <= '0';
                alert_hi_reg <= '0';
                alert_lo_reg <= '0';
            end if;

            case fsm is

                -- ==========================================
                -- IDLE: Wait for measurement trigger
                -- ==========================================
                when F_IDLE =>
                    if measure_start = '1' then
                        window_cnt <= (others => '0');
                        edge_cnt   <= (others => '0');
                        fsm        <= F_COUNTING;
                    end if;

                -- ==========================================
                -- COUNTING: Count edges within window
                -- ==========================================
                when F_COUNTING =>
                    -- Count ring osc edges
                    if edge_pulse = '1' then
                        if edge_cnt < x"FFFFFF" then
                            edge_cnt <= edge_cnt + 1;
                        end if;
                    end if;

                    -- Window timer
                    if window_cnt >= to_unsigned(WINDOW_CYCLES - 1, 24) then
                        fsm <= F_REPORT;
                    else
                        window_cnt <= window_cnt + 1;
                    end if;

                -- ==========================================
                -- REPORT: Latch result, check alarms
                -- ==========================================
                when F_REPORT =>
                    result_reg <= edge_cnt;
                    valid_reg  <= '1';

                    -- Alarm check
                    if to_integer(edge_cnt) > ALARM_UPPER then
                        alert_latch  <= '1';
                        alert_hi_reg <= '1';
                    elsif to_integer(edge_cnt) < ALARM_LOWER then
                        alert_latch  <= '1';
                        alert_lo_reg <= '1';
                    end if;

                    -- Auto-repeat or idle
                    if continuous = '1' then
                        window_cnt <= (others => '0');
                        edge_cnt   <= (others => '0');
                        fsm        <= F_COUNTING;
                    else
                        fsm <= F_IDLE;
                    end if;

            end case;
        end if;
    end process;

end architecture rtl;
