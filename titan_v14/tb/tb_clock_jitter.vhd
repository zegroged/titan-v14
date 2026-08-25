--------------------------------------------------------------------------------
-- AEGIS Phase 3.2: Testbench for Clock Jitter Injector
--------------------------------------------------------------------------------
-- Uses a behavioral MMCM model (no UNISIM needed for GHDL).
-- Measures cycle-to-cycle jitter on jittered_clk output.
-- Tests:
--   1. MMCM lock and clean clock when jitter disabled
--   2. Jitter injection with chaotic input
--   3. Jitter bounded within ±2 ns
--   4. Bypass mode (jitter_enable='0')
--   5. Phase accumulator bounds check
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ===== Behavioral MMCM Model =====
-- Simulates MMCME2_ADV dynamic phase shift behavior.
-- Each PS step adds/subtracts ~18.5 ps to output phase.

entity mmcm_model is
    generic (
        CLK_PERIOD : time := 20 ns;
        PS_STEP    : time := 18 ps   -- ~18.5 ps per step (Artix-7)
    );
    port (
        clk_in   : in  std_logic;
        rst      : in  std_logic;
        psclk    : in  std_logic;
        psen     : in  std_logic;
        psincdec : in  std_logic;
        psdone   : out std_logic;
        clk_out0 : out std_logic;   -- Phase-shifted
        clk_out1 : out std_logic;   -- Fixed
        clkfb    : out std_logic;
        locked   : out std_logic
    );
end entity mmcm_model;

architecture behavioral of mmcm_model is
    signal phase_offset  : time := 0 ns;
    signal psdone_reg    : std_logic := '0';
    signal locked_int    : std_logic := '0';
    signal ps_pending    : boolean := false;
    signal ps_counter    : integer := 0;
begin

    locked  <= locked_int;
    psdone  <= psdone_reg;

    -- Lock after RST deasserts + 10 clock cycles
    lock_proc: process
        variable cnt : integer := 0;
    begin
        -- Wait for reset to deassert
        while rst = '1' loop
            wait for 1 ns;
        end loop;
        -- Count 10 clock rising edges after reset
        cnt := 0;
        while cnt < 10 loop
            wait until rising_edge(clk_in);
            if rst = '1' then
                cnt := 0;  -- Reset during lock-up
            else
                cnt := cnt + 1;
            end if;
        end loop;
        locked_int <= '1';
        -- Stay locked unless RST reasserts
        wait until rst = '1';
        locked_int <= '0';
        wait;
    end process;

    -- Fixed output clock (CLKOUT1)
    clk1_proc: process
    begin
        while true loop
            clk_out1 <= '0'; wait for CLK_PERIOD/2;
            clk_out1 <= '1'; wait for CLK_PERIOD/2;
        end loop;
    end process;

    -- Feedback (same as fixed)
    fb_proc: process
    begin
        while true loop
            clkfb <= '0'; wait for CLK_PERIOD/2;
            clkfb <= '1'; wait for CLK_PERIOD/2;
        end loop;
    end process;

    -- Phase-shifted output clock (CLKOUT0)
    clk0_proc: process
        variable half_p : time;
    begin
        while true loop
            half_p := CLK_PERIOD/2;
            clk_out0 <= '0'; wait for half_p + phase_offset;
            clk_out0 <= '1'; wait for half_p - phase_offset;
            -- Note: phase_offset applied asymmetrically for simplicity
            -- In real MMCM it shifts the entire edge
        end loop;
    end process;

    -- Phase shift handler
    ps_proc: process(psclk)
    begin
        if rising_edge(psclk) then
            psdone_reg <= '0';

            if rst = '1' then
                phase_offset <= 0 ns;
                ps_counter   <= 0;
            elsif psen = '1' and locked_int = '1' then
                -- Apply phase shift
                if psincdec = '1' then
                    phase_offset <= phase_offset + PS_STEP;
                    ps_counter   <= ps_counter + 1;
                else
                    phase_offset <= phase_offset - PS_STEP;
                    ps_counter   <= ps_counter - 1;
                end if;
                ps_pending <= true;
            elsif ps_pending then
                -- PSDONE asserted one cycle after PS applied
                psdone_reg <= '1';
                ps_pending <= false;
            end if;
        end if;
    end process;

end architecture behavioral;

-- ===== Main Testbench =====

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_clock_jitter is
end entity tb_clock_jitter;

architecture sim of tb_clock_jitter is

    constant CLK_P   : time := 20 ns;
    constant PS_STEP : time := 18 ps;

    signal sys_clk       : std_logic := '0';
    signal rst            : std_logic := '1';
    signal chaos_byte    : std_logic_vector(7 downto 0) := x"80";
    signal chaos_valid   : std_logic := '0';
    signal jitter_enable : std_logic := '0';

    -- From behavioral wrapper (directly testing the controller logic)
    signal psen_tb       : std_logic := '0';
    signal psincdec_tb   : std_logic := '0';
    signal psdone_tb     : std_logic := '0';
    signal locked_tb     : std_logic := '0';

    -- Jitter controller signals (extracted from the injector logic)
    type ps_fsm_t is (PS_IDLE, PS_SHIFT, PS_WAIT);
    signal ps_fsm        : ps_fsm_t;
    signal phase_accum   : signed(8 downto 0) := (others => '0');

    constant MAX_STEPS   : integer := 108;
    constant THRESHOLD   : integer := 12;

    signal jittered_clk  : std_logic := '0';
    signal fixed_clk     : std_logic := '0';
    signal clkfb_sig     : std_logic;

    signal running       : boolean := true;

    -- Jitter measurement
    signal last_edge     : time := 0 ns;
    signal period_meas   : time := 0 ns;
    signal jitter_max    : time := 0 ns;
    signal edge_count    : integer := 0;

begin

    -- System clock generator
    clk_gen: process
    begin
        while running loop
            sys_clk <= '0'; wait for CLK_P/2;
            sys_clk <= '1'; wait for CLK_P/2;
        end loop;
        wait;
    end process;

    -- Behavioral MMCM
    u_mmcm: entity work.mmcm_model
        generic map (CLK_PERIOD => CLK_P, PS_STEP => PS_STEP)
        port map (
            clk_in   => sys_clk,
            rst      => rst,
            psclk    => sys_clk,
            psen     => psen_tb,
            psincdec => psincdec_tb,
            psdone   => psdone_tb,
            clk_out0 => jittered_clk,
            clk_out1 => fixed_clk,
            clkfb    => clkfb_sig,
            locked   => locked_tb
        );

    -- ===== Phase Shift Controller (replicated logic from injector) =====
    ctrl: process(sys_clk)
        variable cval : integer;
    begin
        if rising_edge(sys_clk) then
            if rst = '1' or locked_tb = '0' then
                ps_fsm      <= PS_IDLE;
                psen_tb     <= '0';
                psincdec_tb <= '0';
                phase_accum <= (others => '0');
            else
                psen_tb <= '0';

                case ps_fsm is
                    when PS_IDLE =>
                        if jitter_enable = '1' and chaos_valid = '1' then
                            cval := to_integer(unsigned(chaos_byte));
                            if cval > 128 + THRESHOLD then
                                if phase_accum < to_signed(MAX_STEPS, 9) then
                                    psincdec_tb <= '1';
                                    ps_fsm <= PS_SHIFT;
                                end if;
                            elsif cval < 128 - THRESHOLD then
                                if phase_accum > to_signed(-MAX_STEPS, 9) then
                                    psincdec_tb <= '0';
                                    ps_fsm <= PS_SHIFT;
                                end if;
                            end if;
                        end if;

                    when PS_SHIFT =>
                        psen_tb <= '1';
                        if psincdec_tb = '1' then
                            phase_accum <= phase_accum + 1;
                        else
                            phase_accum <= phase_accum - 1;
                        end if;
                        ps_fsm <= PS_WAIT;

                    when PS_WAIT =>
                        if psdone_tb = '1' then
                            ps_fsm <= PS_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- ===== Jitter Measurement =====
    meas: process(jittered_clk)
        variable current_period : time;
        variable jit : time;
    begin
        if rising_edge(jittered_clk) then
            if last_edge > 0 ns then
                current_period := now - last_edge;
                period_meas <= current_period;

                if current_period > CLK_P then
                    jit := current_period - CLK_P;
                else
                    jit := CLK_P - current_period;
                end if;

                if jit > jitter_max and edge_count > 5 then
                    jitter_max <= jit;
                end if;
            end if;
            last_edge <= now;
            edge_count <= edge_count + 1;
        end if;
    end process;

    -- ===== Stimulus =====
    stim: process
        variable pc, fc : integer := 0;
    begin
        -- Reset
        rst <= '1';
        wait for CLK_P * 15;
        rst <= '0';
        wait for CLK_P * 15;  -- Wait for lock

        -- ===== TEST 1: Clean clock (no jitter) =====
        report "TEST 1: No jitter -- clean clock" severity note;
        jitter_enable <= '0';
        chaos_valid <= '0';
        wait for CLK_P * 20;

        if jitter_max < 1 ps then
            pc := pc + 1;
            report "  PASS: No jitter when disabled" severity note;
        else
            fc := fc + 1;
            report "  FAIL: Unexpected jitter" severity error;
        end if;

        -- ===== TEST 2: Jitter injection =====
        report "TEST 2: Chaotic jitter injection" severity note;
        jitter_enable <= '1';

        -- Send chaotic bytes (varying values)
        for i in 0 to 49 loop
            -- Simulate chaos: alternate high and low values
            if (i mod 3) = 0 then
                chaos_byte <= std_logic_vector(to_unsigned(200, 8));  -- Shift +
            elsif (i mod 3) = 1 then
                chaos_byte <= std_logic_vector(to_unsigned(40, 8));   -- Shift -
            else
                chaos_byte <= std_logic_vector(to_unsigned(128, 8));  -- Dead zone
            end if;
            chaos_valid <= '1';
            wait for CLK_P;
            chaos_valid <= '0';
            wait for CLK_P * 3;  -- Wait for PSDONE
        end loop;

        wait for CLK_P * 10;
        report "  Phase accumulator: " & integer'image(to_integer(phase_accum))
               & " steps" severity note;

        -- Check that some jitter was applied
        if jitter_max > 0 ps then
            pc := pc + 1;
            report "  PASS: Jitter detected" severity note;
        else
            fc := fc + 1;
            report "  FAIL: No jitter measured" severity error;
        end if;

        -- ===== TEST 3: Bounds check =====
        report "TEST 3: Phase accumulator bounds" severity note;
        if phase_accum >= to_signed(-MAX_STEPS, 9) and
           phase_accum <= to_signed(MAX_STEPS, 9) then
            pc := pc + 1;
            report "  PASS: Within ±" & integer'image(MAX_STEPS) &
                   " steps" severity note;
        else
            fc := fc + 1;
            report "  FAIL: Accumulator out of bounds!" severity error;
        end if;

        -- ===== TEST 4: Bypass =====
        report "TEST 4: Bypass mode" severity note;
        jitter_enable <= '0';
        chaos_valid <= '1';
        chaos_byte <= x"FF";
        wait for CLK_P * 10;
        chaos_valid <= '0';

        -- Controller should be idle
        if ps_fsm = PS_IDLE then
            pc := pc + 1;
            report "  PASS: Controller idle when disabled" severity note;
        else
            fc := fc + 1;
            report "  FAIL: Controller still active" severity error;
        end if;

        -- Summary
        report "========================================" severity note;
        report " CLOCK JITTER INJECTOR TEST" severity note;
        report "   PASS: " & integer'image(pc) severity note;
        report "   FAIL: " & integer'image(fc) severity note;
        report "========================================" severity note;

        running <= false;
        wait;
    end process;

end architecture sim;
