--------------------------------------------------------------------------------
-- PROJECT TITAN V14: PolarFire Adversarial Watchdog
-- Module: Cryptographic Challenge-Response + Anomaly Monitoring
--------------------------------------------------------------------------------
-- FELSEFE: PolarFire, Artix-7'ye GÜVENMEMELİ.
--
-- MEKANIZMALAR:
--   1. Challenge gönder (64-bit random) → Artix-7 doğru cevap vermeli
--      Yanlış/geç cevap → Artix-7 compromised → KILL
--   2. Clock frequency monitoring: Artix-7 clock frekansını say
--      Sapma > ±5% → glitch attack → KILL
--   3. Bağımsız kill çıkışı (PolarFire kendi kararını verir)
--
-- KULLANIM:
--   Bu modül PolarFire FPGA'da sentezlenir (Artix-7'de DEĞİL)
--   Artix-7 tarafında buna cevap veren bir modül olmalı
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity polarfire_watchdog is
    generic (
        -- System clock frequency (Hz)
        SYS_CLK_FREQ    : integer := 50_000_000;
        -- Challenge timeout (ms)
        CHALLENGE_TIMEOUT_MS : integer := 100;
        -- Clock monitoring: expected Artix-7 frequency (±5%)
        EXPECTED_TARGET_FREQ : integer := 50_000_000;
        FREQ_TOLERANCE_PCT   : integer := 5;
        -- Measurement window (ms)
        MEASURE_WINDOW_MS    : integer := 10
    );
    port (
        clk              : in  std_logic;   -- PolarFire system clock
        rst_n            : in  std_logic;
        
        -- Challenge-Response Interface (to/from Artix-7)
        challenge_out    : out std_logic_vector(63 downto 0);  -- → Artix-7
        challenge_valid  : out std_logic;
        response_in      : in  std_logic_vector(63 downto 0);  -- ← Artix-7
        response_valid   : in  std_logic;
        
        -- Clock Monitoring (Artix-7 clock wired to this pin)
        target_clk_in    : in  std_logic;   -- Artix-7'nin clock'u
        
        -- TRNG for challenge generation
        trng_random      : in  std_logic_vector(63 downto 0);
        
        -- Kill Interface
        kill_artix7      : out std_logic;   -- → Artix-7 kill pin
        
        -- Status
        watchdog_ok      : out std_logic;   -- '1' = challenge passed
        freq_alarm       : out std_logic;   -- '1' = clock anomaly
        timeout_alarm    : out std_logic    -- '1' = challenge timeout
    );
end polarfire_watchdog;

architecture Behavioral of polarfire_watchdog is

    -------------------------------------------------------------------------
    -- TIMING CONSTANTS
    -------------------------------------------------------------------------
    constant TIMEOUT_CYCLES : integer := SYS_CLK_FREQ / 1000 * CHALLENGE_TIMEOUT_MS;
    constant MEASURE_CYCLES : integer := SYS_CLK_FREQ / 1000 * MEASURE_WINDOW_MS;
    constant CHALLENGE_INTERVAL : integer := SYS_CLK_FREQ;  -- 1 Hz challenge rate
    
    -- Expected clock count in measurement window
    constant EXPECTED_COUNT : integer := EXPECTED_TARGET_FREQ / 1000 * MEASURE_WINDOW_MS;
    constant TOLERANCE      : integer := EXPECTED_COUNT * FREQ_TOLERANCE_PCT / 100;
    constant COUNT_MIN      : integer := EXPECTED_COUNT - TOLERANCE;
    constant COUNT_MAX      : integer := EXPECTED_COUNT + TOLERANCE;

    -------------------------------------------------------------------------
    -- CHALLENGE-RESPONSE FSM
    -------------------------------------------------------------------------
    type cr_state_t is (
        CR_IDLE,        -- Bekleme
        CR_SEND,        -- Challenge gönder
        CR_WAIT,        -- Response bekle
        CR_VERIFY,      -- Response doğrula
        CR_ALARM        -- Alarm durumu (latched)
    );
    signal cr_state      : cr_state_t := CR_IDLE;
    signal interval_cnt  : integer range 0 to CHALLENGE_INTERVAL := 0;
    signal timeout_cnt   : integer range 0 to TIMEOUT_CYCLES := 0;
    signal current_challenge : std_logic_vector(63 downto 0) := (others => '0');
    signal cr_kill       : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- EXPECTED RESPONSE: simple XOR-fold (not AES — PolarFire may not have AES)
    -- expected = challenge XOR x"A5A5A5A5A5A5A5A5" (shared pre-arranged transform)
    -- Real implementation: AES(shared_key, challenge)
    -------------------------------------------------------------------------
    constant RESPONSE_MASK : std_logic_vector(63 downto 0) := x"A5A5A5A5A5A5A5A5";
    signal expected_response : std_logic_vector(63 downto 0);

    -------------------------------------------------------------------------
    -- CLOCK FREQUENCY MONITOR
    -------------------------------------------------------------------------
    signal target_sync   : std_logic_vector(2 downto 0) := "000";
    signal measure_cnt   : integer range 0 to MEASURE_CYCLES := 0;
    signal target_edge_cnt : integer range 0 to 2_000_000 := 0;
    signal freq_kill     : std_logic := '0';
    signal freq_valid    : std_logic := '0';

    -------------------------------------------------------------------------
    -- SYNTHESIS PROTECTION
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of cr_state : signal is "true";
    attribute dont_touch of cr_kill  : signal is "true";
    attribute dont_touch of freq_kill : signal is "true";

begin

    -- Expected response computation
    expected_response <= current_challenge xor RESPONSE_MASK;

    -------------------------------------------------------------------------
    -- CHALLENGE-RESPONSE PROCESS
    -------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            cr_state         <= CR_IDLE;
            interval_cnt     <= 0;
            timeout_cnt      <= 0;
            current_challenge <= (others => '0');
            cr_kill          <= '0';
            challenge_valid  <= '0';
        elsif rising_edge(clk) then
            challenge_valid <= '0';
            
            case cr_state is
            
                when CR_IDLE =>
                    if interval_cnt >= CHALLENGE_INTERVAL then
                        -- Time for new challenge
                        current_challenge <= trng_random;
                        cr_state      <= CR_SEND;
                        interval_cnt  <= 0;
                    else
                        interval_cnt <= interval_cnt + 1;
                    end if;
                
                when CR_SEND =>
                    challenge_out   <= current_challenge;
                    challenge_valid <= '1';
                    timeout_cnt     <= 0;
                    cr_state        <= CR_WAIT;
                
                when CR_WAIT =>
                    if response_valid = '1' then
                        cr_state <= CR_VERIFY;
                    elsif timeout_cnt >= TIMEOUT_CYCLES then
                        -- ★ TIMEOUT: Artix-7 cevap vermedi → compromised
                        cr_kill <= '1';
                        cr_state <= CR_ALARM;
                    else
                        timeout_cnt <= timeout_cnt + 1;
                    end if;
                
                when CR_VERIFY =>
                    if response_in = expected_response then
                        -- ✅ Doğru cevap → yaşasın
                        cr_state <= CR_IDLE;
                    else
                        -- ❌ Yanlış cevap → compromised
                        cr_kill <= '1';
                        cr_state <= CR_ALARM;
                    end if;
                
                when CR_ALARM =>
                    -- Latched alarm — FPGA boyunca kill aktif kalır
                    cr_kill <= '1';
                
                when others =>
                    cr_state <= CR_ALARM;
                    
            end case;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- CLOCK FREQUENCY MONITOR
    -------------------------------------------------------------------------
    -- Artix-7 clock'unu say, sapma > ±5% ise alarm
    -------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            target_sync    <= "000";
            measure_cnt    <= 0;
            target_edge_cnt <= 0;
            freq_kill      <= '0';
            freq_valid     <= '0';
        elsif rising_edge(clk) then
            -- CDC sync: target_clk → PolarFire domain
            target_sync <= target_sync(1 downto 0) & target_clk_in;
            
            if measure_cnt >= MEASURE_CYCLES then
                -- Measurement window complete
                if target_edge_cnt < COUNT_MIN or target_edge_cnt > COUNT_MAX then
                    freq_kill <= '1';  -- ★ CLOCK GLITCH DETECTED
                end if;
                freq_valid <= '1';
                measure_cnt <= 0;
                target_edge_cnt <= 0;
            else
                measure_cnt <= measure_cnt + 1;
                -- Count rising edges of target clock
                if target_sync(2) = '0' and target_sync(1) = '1' then
                    target_edge_cnt <= target_edge_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- OUTPUT ASSIGNMENT
    -------------------------------------------------------------------------
    kill_artix7    <= cr_kill or freq_kill;
    watchdog_ok    <= not cr_kill;
    freq_alarm     <= freq_kill;
    timeout_alarm  <= cr_kill;

end Behavioral;
