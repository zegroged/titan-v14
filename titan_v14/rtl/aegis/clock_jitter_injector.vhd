--------------------------------------------------------------------------------
-- AEGIS Phase 3.2: Clock Jitter Injector (MMCM Dynamic Phase Shift)
--------------------------------------------------------------------------------
-- Wraps Xilinx MMCME2_ADV to produce a jittered clock for the AES core.
-- Chaotic PRNG output drives dynamic phase shifting ±2ns.
--
-- Architecture (Artix-7):
--   sys_clk -> MMCME2_ADV [dynamic PS] -> jittered_clk (to AES)
--                                      -> sys_clk_buf  (unchanged)
--
-- Phase shift control:
--   - Artix-7 MMCM step ≈ 18.5 ps (VCO freq dependent)
--   - ±2 ns ≈ ±108 steps max from center
--   - chaos_value MSBs determine shift direction
--   - Rate-limited: wait for PSDONE before next shift
--   - Bounded: track cumulative shift, clamp at ±MAX_STEPS
--
-- Bypass: jitter_enable='0' -> no phase shifts applied
-- Safety: sys_clk output is NEVER phase-shifted
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity clock_jitter_injector is
    generic (
        -- MMCM configuration for 50 MHz input
        CLKFBOUT_MULT_F  : real := 20.0;    -- VCO = 50 * 20 = 1000 MHz
        CLKOUT0_DIVIDE_F : real := 20.0;    -- jittered_clk = 1000/20 = 50 MHz
        CLKOUT1_DIVIDE   : integer := 20;   -- sys_clk_buf  = 50 MHz (no PS)
        DIVCLK_DIVIDE    : integer := 1;
        -- Jitter bounds
        MAX_PHASE_STEPS  : integer := 108;  -- +/-2 ns @ ~18.5 ps/step
        SHIFT_THRESHOLD  : integer := 12;   -- chaos_byte midpoint
        -- Simulation mode: bypass MMCM, passthrough clocks
        SIM_MODE         : boolean := false
    );
    port (
        -- Input clock
        sys_clk        : in  std_logic;
        rst            : in  std_logic;   -- Active HIGH reset

        -- Chaotic control
        chaos_byte     : in  std_logic_vector(7 downto 0);
        chaos_valid    : in  std_logic;
        jitter_enable  : in  std_logic;

        -- Output clocks
        jittered_clk   : out std_logic;  -- Phase-shifted (to AES)
        sys_clk_buf    : out std_logic;  -- Clean buffered (to everything else)
        mmcm_locked    : out std_logic
    );
end entity clock_jitter_injector;

architecture rtl of clock_jitter_injector is

    -- Phase shift controller (shared between sim and synth)
    type ps_fsm_t is (PS_IDLE, PS_SHIFT, PS_WAIT);
    signal ps_fsm        : ps_fsm_t;
    signal phase_accum   : signed(8 downto 0);  -- Tracks cumulative shift
    signal shift_request : std_logic;
    signal shift_dir     : std_logic;  -- '1'=inc, '0'=dec

begin

    -- =================================================================
    -- SIMULATION MODE: Behavioral passthrough (no UNISIM needed)
    -- =================================================================
    gen_sim : if SIM_MODE generate
    begin
        -- In simulation, just pass the clock through
        jittered_clk <= sys_clk;
        sys_clk_buf  <= sys_clk;
        mmcm_locked  <= '1' when rst = '0' else '0';

        -- Phase shift controller still runs for functional verification
        process(sys_clk)
            variable chaos_val : integer;
        begin
            if rising_edge(sys_clk) then
                if rst = '1' then
                    ps_fsm      <= PS_IDLE;
                    phase_accum <= (others => '0');
                else
                    case ps_fsm is
                        when PS_IDLE =>
                            if jitter_enable = '1' and chaos_valid = '1' then
                                chaos_val := to_integer(unsigned(chaos_byte));
                                if chaos_val > 128 + SHIFT_THRESHOLD then
                                    if phase_accum < to_signed(MAX_PHASE_STEPS, 9) then
                                        shift_dir <= '1';
                                        ps_fsm    <= PS_SHIFT;
                                    end if;
                                elsif chaos_val < 128 - SHIFT_THRESHOLD then
                                    if phase_accum > to_signed(-MAX_PHASE_STEPS, 9) then
                                        shift_dir <= '0';
                                        ps_fsm    <= PS_SHIFT;
                                    end if;
                                end if;
                            end if;

                        when PS_SHIFT =>
                            if shift_dir = '1' then
                                phase_accum <= phase_accum + 1;
                            else
                                phase_accum <= phase_accum - 1;
                            end if;
                            ps_fsm <= PS_WAIT;

                        when PS_WAIT =>
                            -- In sim, PSDONE is immediate (1 cycle)
                            ps_fsm <= PS_IDLE;
                    end case;
                end if;
            end if;
        end process;
    end generate gen_sim;

    -- =================================================================
    -- SYNTHESIS MODE: Real MMCM instantiation (Xilinx UNISIM required)
    -- =================================================================
    gen_synth : if not SIM_MODE generate

        -- Pull in UNISIM only for synthesis
        component MMCME2_ADV is
            generic (
                BANDWIDTH           : string;
                CLKFBOUT_MULT_F     : real;
                CLKOUT0_DIVIDE_F    : real;
                CLKOUT1_DIVIDE      : integer;
                CLKOUT0_PHASE       : real;
                CLKOUT1_PHASE       : real;
                DIVCLK_DIVIDE       : integer;
                CLKIN1_PERIOD       : real;
                CLKOUT0_USE_FINE_PS : boolean;
                STARTUP_WAIT        : boolean
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
        end component;

        component BUFG is
            port (
                I : in  std_logic;
                O : out std_logic
            );
        end component;

        signal clkfb_int     : std_logic;
        signal clkfb_buf     : std_logic;
        signal clkout0_int   : std_logic;
        signal clkout1_int   : std_logic;
        signal locked_int    : std_logic;
        signal psen_int      : std_logic;
        signal psincdec_int  : std_logic;
        signal psdone_int    : std_logic;

    begin
        mmcm_locked <= locked_int;

        u_mmcm : MMCME2_ADV
            generic map (
                BANDWIDTH          => "OPTIMIZED",
                CLKFBOUT_MULT_F    => CLKFBOUT_MULT_F,
                CLKOUT0_DIVIDE_F   => CLKOUT0_DIVIDE_F,
                CLKOUT1_DIVIDE     => CLKOUT1_DIVIDE,
                CLKOUT0_PHASE      => 0.0,
                CLKOUT1_PHASE      => 0.0,
                DIVCLK_DIVIDE      => DIVCLK_DIVIDE,
                CLKIN1_PERIOD       => 20.0,
                CLKOUT0_USE_FINE_PS => TRUE,
                STARTUP_WAIT        => FALSE
            )
            port map (
                CLKIN1    => sys_clk,
                CLKIN2    => '0',
                CLKINSEL  => '1',
                CLKFBOUT  => clkfb_int,
                CLKFBIN   => clkfb_buf,
                CLKOUT0   => clkout0_int,
                CLKOUT1   => clkout1_int,
                CLKOUT2   => open,
                CLKOUT3   => open,
                CLKOUT4   => open,
                CLKOUT5   => open,
                CLKOUT6   => open,
                CLKOUT0B  => open,
                CLKOUT1B  => open,
                CLKOUT2B  => open,
                CLKOUT3B  => open,
                CLKFBOUTB => open,
                PSCLK     => sys_clk,
                PSEN      => psen_int,
                PSINCDEC  => psincdec_int,
                PSDONE    => psdone_int,
                LOCKED    => locked_int,
                RST       => rst,
                PWRDWN    => '0',
                DADDR     => (others => '0'),
                DI        => (others => '0'),
                DWE       => '0',
                DEN       => '0',
                DCLK      => '0',
                DO        => open,
                DRDY      => open
            );

        u_fb_buf : BUFG
            port map (I => clkfb_int, O => clkfb_buf);

        u_jit_buf : BUFG
            port map (I => clkout0_int, O => jittered_clk);

        u_sys_buf : BUFG
            port map (I => clkout1_int, O => sys_clk_buf);

        -- Phase Shift Controller
        process(sys_clk)
            variable chaos_val : integer;
        begin
            if rising_edge(sys_clk) then
                if rst = '1' or locked_int = '0' then
                    ps_fsm       <= PS_IDLE;
                    psen_int     <= '0';
                    psincdec_int <= '0';
                    phase_accum  <= (others => '0');
                else
                    psen_int <= '0';

                    case ps_fsm is
                        when PS_IDLE =>
                            if jitter_enable = '1' and chaos_valid = '1' then
                                chaos_val := to_integer(unsigned(chaos_byte));
                                if chaos_val > 128 + SHIFT_THRESHOLD then
                                    if phase_accum < to_signed(MAX_PHASE_STEPS, 9) then
                                        shift_dir <= '1';
                                        ps_fsm    <= PS_SHIFT;
                                    end if;
                                elsif chaos_val < 128 - SHIFT_THRESHOLD then
                                    if phase_accum > to_signed(-MAX_PHASE_STEPS, 9) then
                                        shift_dir <= '0';
                                        ps_fsm    <= PS_SHIFT;
                                    end if;
                                end if;
                            end if;

                        when PS_SHIFT =>
                            psen_int     <= '1';
                            psincdec_int <= shift_dir;
                            if shift_dir = '1' then
                                phase_accum <= phase_accum + 1;
                            else
                                phase_accum <= phase_accum - 1;
                            end if;
                            ps_fsm <= PS_WAIT;

                        when PS_WAIT =>
                            if psdone_int = '1' then
                                ps_fsm <= PS_IDLE;
                            end if;
                    end case;
                end if;
            end if;
        end process;

    end generate gen_synth;

end architecture rtl;

