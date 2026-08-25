--------------------------------------------------------------------------------
-- MMCME2_ADV behavioral model for GHDL simulation
-- Produces output clocks from CLKIN1 with dynamic phase shift on CLKOUT0.
-- Phase shift: each PSEN pulse adds/subtracts ~18 ps to CLKOUT0 phase.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

library unisim;

entity MMCME2_ADV is
    generic (
        BANDWIDTH          : string  := "OPTIMIZED";
        CLKFBOUT_MULT_F    : real    := 5.0;
        CLKOUT0_DIVIDE_F   : real    := 1.0;
        CLKOUT1_DIVIDE     : integer := 1;
        CLKOUT0_PHASE      : real    := 0.0;
        CLKOUT1_PHASE      : real    := 0.0;
        DIVCLK_DIVIDE      : integer := 1;
        CLKIN1_PERIOD       : real   := 10.0;
        CLKOUT0_USE_FINE_PS : boolean := FALSE;
        STARTUP_WAIT        : boolean := FALSE
    );
    port (
        CLKIN1    : in  std_logic;
        CLKIN2    : in  std_logic;
        CLKINSEL  : in  std_logic;
        CLKFBOUT  : out std_logic;
        CLKFBIN   : in  std_logic;
        CLKOUT0   : out std_logic;
        CLKOUT1   : out std_logic;
        CLKOUT2   : out std_logic;
        CLKOUT3   : out std_logic;
        CLKOUT4   : out std_logic;
        CLKOUT5   : out std_logic;
        CLKOUT6   : out std_logic;
        CLKOUT0B  : out std_logic;
        CLKOUT1B  : out std_logic;
        CLKOUT2B  : out std_logic;
        CLKOUT3B  : out std_logic;
        CLKFBOUTB : out std_logic;
        PSCLK     : in  std_logic;
        PSEN      : in  std_logic;
        PSINCDEC  : in  std_logic;
        PSDONE    : out std_logic;
        LOCKED    : out std_logic;
        RST       : in  std_logic;
        PWRDWN    : in  std_logic;
        DADDR     : in  std_logic_vector(6 downto 0);
        DI        : in  std_logic_vector(15 downto 0);
        DWE       : in  std_logic;
        DEN       : in  std_logic;
        DCLK      : in  std_logic;
        DO        : out std_logic_vector(15 downto 0);
        DRDY      : out std_logic
    );
end entity MMCME2_ADV;

architecture sim of MMCME2_ADV is
    -- Phase shift step: ~18 ps (Artix-7 at VCO ~1000 MHz)
    constant PS_STEP_PS : integer := 18;

    signal locked_int   : std_logic := '0';
    signal lock_cnt     : integer := 0;
    signal ps_pending   : integer := 0;

    -- Phase shift accumulator (in picoseconds)
    signal phase_ps     : integer := 0;

    -- Internal clock signals
    signal clkout0_int  : std_logic := '0';
begin

    -- ===== Fixed outputs: pass through CLKIN1 =====
    CLKFBOUT  <= CLKIN1;
    CLKOUT1   <= CLKIN1;
    CLKOUT2   <= '0';
    CLKOUT3   <= '0';
    CLKOUT4   <= '0';
    CLKOUT5   <= '0';
    CLKOUT6   <= '0';
    CLKOUT1B  <= not CLKIN1;
    CLKOUT2B  <= '0';
    CLKOUT3B  <= '0';
    CLKFBOUTB <= not CLKIN1;
    DO        <= (others => '0');
    DRDY      <= '0';
    LOCKED    <= locked_int;

    -- ===== CLKOUT0: Phase-shifted clock =====
    -- Generate CLKOUT0 with applied phase offset from PS accumulator.
    -- The phase is applied by delaying/advancing the output edges.
    clk0_proc: process
        variable half_period_ns : integer;
        variable offset_ps     : integer;
        variable high_time_ps  : integer;
        variable low_time_ps   : integer;
    begin
        -- Compute half-period from CLKIN1_PERIOD (in ns, as real)
        -- For simplicity, use integer ps arithmetic
        half_period_ns := integer(CLKIN1_PERIOD * 500.0);  -- half-period in ps

        while true loop
            offset_ps := phase_ps;

            -- Low phase: half_period + offset
            low_time_ps := half_period_ns + offset_ps;
            if low_time_ps < 100 then
                low_time_ps := 100;  -- minimum 100 ps
            end if;
            clkout0_int <= '0';
            wait for low_time_ps * 1 ps;

            -- High phase: half_period - offset
            high_time_ps := half_period_ns - offset_ps;
            if high_time_ps < 100 then
                high_time_ps := 100;  -- minimum 100 ps
            end if;
            clkout0_int <= '1';
            wait for high_time_ps * 1 ps;
        end loop;
    end process;

    CLKOUT0  <= clkout0_int;
    CLKOUT0B <= not clkout0_int;

    -- ===== Lock simulation: assert LOCKED after RST deasserts + 10 cycles =====
    lock_proc: process(CLKIN1, RST)
    begin
        if RST = '1' then
            lock_cnt   <= 0;
            locked_int <= '0';
        elsif rising_edge(CLKIN1) then
            if lock_cnt < 10 then
                lock_cnt <= lock_cnt + 1;
            else
                locked_int <= '1';
            end if;
        end if;
    end process;

    -- ===== Phase shift handler =====
    -- On PSEN pulse: accumulate phase_ps by ±PS_STEP_PS
    -- Assert PSDONE 2 PSCLK cycles after PSEN
    ps_proc: process(PSCLK)
    begin
        if rising_edge(PSCLK) then
            if RST = '1' then
                phase_ps   <= 0;
                ps_pending <= 0;
            else
                if PSEN = '1' and locked_int = '1' then
                    if PSINCDEC = '1' then
                        phase_ps <= phase_ps + PS_STEP_PS;
                    else
                        phase_ps <= phase_ps - PS_STEP_PS;
                    end if;
                    ps_pending <= 2;
                end if;

                if ps_pending > 0 then
                    ps_pending <= ps_pending - 1;
                end if;
            end if;
        end if;
    end process;

    PSDONE <= '1' when ps_pending = 1 else '0';

end architecture sim;
