--------------------------------------------------------------------------------
-- AEGIS Phase 3.1: Chaotic PRNG -- Dual Logistic Map (Q8.24)
--------------------------------------------------------------------------------
-- Two independent Logistic Maps with different r parameters.
-- Outputs are XOR-mixed to break periodic orbits and pass NIST.
--
-- Generator A: x_{n+1} = r_a * x_n * (1 - x_n),  r_a = 3.99
-- Generator B: y_{n+1} = r_b * y_n * (1 - y_n),  r_b = 3.97
--
-- chaos_out  = x XOR y (decorrelated)
-- chaos_byte = (x XOR y)(23 downto 16)
-- chaos_bit  = XOR-fold of (x XOR y)
--
-- The two maps have different orbit lengths (coprime-ish),
-- so XOR output has orbit ≈ LCM(orbit_a, orbit_b) -> much longer.
--
-- Q8.24: 8 integer + 24 fractional bits, 1.0 = 0x01000000
-- Throughput: 4 cycles per output (shared multiplier, time-muxed)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity chaotic_prng is
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        seed        : in  std_logic_vector(31 downto 0);  -- Seed for map A
        r_param     : in  std_logic_vector(31 downto 0);  -- r for map A
        load_seed   : in  std_logic;
        enable      : in  std_logic;
        chaos_out   : out std_logic_vector(31 downto 0);
        chaos_valid : out std_logic;
        chaos_bit   : out std_logic;
        chaos_byte  : out std_logic_vector(7 downto 0);
        -- ★ B-1 FIX: 128-bit independent mask output (4 successive chaos values)
        chaos_out_128   : out std_logic_vector(127 downto 0);
        chaos_128_valid : out std_logic;
        -- ★ UPGRADE: Cycle detection output (Kimseye Güvenme)
        cycle_locked    : out std_logic  -- '1' = cycle detected, auto-reseeded
    );
    attribute use_dsp : string;
    attribute use_dsp of chaotic_prng : entity is "no";
end entity chaotic_prng;

architecture rtl of chaotic_prng is

    constant FRAC      : integer := 24;
    constant Q_ONE     : unsigned(31 downto 0) := x"01000000";
    constant SAFE_A    : unsigned(31 downto 0) := x"0019999A";  -- 0.1
    constant SAFE_B    : unsigned(31 downto 0) := x"00B33333";  -- 0.7
    constant R_B_DEF   : unsigned(31 downto 0) := x"03F851EC";  -- 3.97 in Q8.24

    -- FSM: processes both maps sequentially with 1 shared multiplier
    -- Pipeline: SUB_A -> MUL1_A -> MUL2_A -> SUB_B -> MUL1_B -> MUL2_B -> VALID
    type fsm_t is (S_IDLE, S_SUB_A, S_MUL1_A, S_MUL2_A,
                   S_SUB_B, S_MUL1_B, S_MUL2_B, S_VALID);
    signal fsm : fsm_t;

    -- Map A state
    signal xa_reg       : unsigned(31 downto 0);
    signal ra_reg       : unsigned(31 downto 0);
    signal omx_a        : unsigned(31 downto 0);  -- 1 - xa
    signal temp_a       : unsigned(31 downto 0);

    -- Map B state
    signal xb_reg       : unsigned(31 downto 0);
    signal rb_reg       : unsigned(31 downto 0);
    signal omx_b        : unsigned(31 downto 0);  -- 1 - xb
    signal temp_b       : unsigned(31 downto 0);

    -- Shared multiplier
    signal mul_a_in   : unsigned(31 downto 0);
    signal mul_b_in   : unsigned(31 downto 0);
    signal mul_prod   : unsigned(63 downto 0);
    signal mul_out    : unsigned(31 downto 0);

    attribute use_dsp of mul_prod : signal is "no";

    -- XOR-mixed output
    signal xor_out    : unsigned(31 downto 0);
    signal valid_reg  : std_logic;

    -- ★ B-1 FIX: 128-bit accumulator from 4 successive outputs
    signal sr_128      : std_logic_vector(127 downto 0) := (others => '0');
    signal sr_count    : integer range 0 to 3 := 0;
    signal sr_valid    : std_logic := '0';

    -- ★ UPGRADE: Cycle detection (sliding window of 4 recent outputs)
    signal prev_out_1  : unsigned(31 downto 0) := (others => '0');
    signal prev_out_2  : unsigned(31 downto 0) := (others => '0');
    signal prev_out_3  : unsigned(31 downto 0) := (others => '0');
    signal prev_out_4  : unsigned(31 downto 0) := (others => '0');
    signal cycle_flag  : std_logic := '0';
    signal cycle_cnt   : unsigned(3 downto 0) := (others => '0');  -- Consecutive matches

begin

    -- ===== Shared multiplier =====
    mul_prod <= mul_a_in * mul_b_in;
    mul_out  <= mul_prod(55 downto 24);  -- Q8.24 realign

    -- Multiplier input mux
    process(fsm, xa_reg, omx_a, ra_reg, temp_a,
            xb_reg, omx_b, rb_reg, temp_b)
    begin
        case fsm is
            when S_MUL1_A => mul_a_in <= xa_reg;  mul_b_in <= omx_a;
            when S_MUL2_A => mul_a_in <= ra_reg;  mul_b_in <= temp_a;
            when S_MUL1_B => mul_a_in <= xb_reg;  mul_b_in <= omx_b;
            when S_MUL2_B => mul_a_in <= rb_reg;  mul_b_in <= temp_b;
            when others   => mul_a_in <= (others => '0');
                             mul_b_in <= (others => '0');
        end case;
    end process;

    -- ===== XOR-mixed output =====
    xor_out     <= xa_reg xor xb_reg;
    chaos_out   <= std_logic_vector(xor_out);
    chaos_valid <= valid_reg;
    chaos_bit   <= xor_out(0) xor xor_out(6) xor xor_out(12) xor xor_out(18);
    chaos_byte  <= std_logic_vector(xor_out(23 downto 16));
    chaos_out_128   <= sr_128;
    chaos_128_valid <= sr_valid;
    cycle_locked    <= cycle_flag;

    -- ★ UPGRADE: Cycle detection process
    -- Compare current XOR output against 4 previous outputs.
    -- If the same value appears 3+ times in a row → cycle_flag = '1' → auto reseed.
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            prev_out_1 <= (others => '0');
            prev_out_2 <= (others => '0');
            prev_out_3 <= (others => '0');
            prev_out_4 <= (others => '0');
            cycle_flag <= '0';
            cycle_cnt  <= (others => '0');
        elsif rising_edge(clk) then
            if valid_reg = '1' then
                -- Shift sliding window
                prev_out_4 <= prev_out_3;
                prev_out_3 <= prev_out_2;
                prev_out_2 <= prev_out_1;
                prev_out_1 <= xor_out;

                -- Check: current output matches ANY of previous 4?
                if xor_out = prev_out_1 or xor_out = prev_out_2 or
                   xor_out = prev_out_3 or xor_out = prev_out_4 then
                    if cycle_cnt = x"F" then
                        cycle_flag <= '1';  -- Confirmed cycle → flag
                    else
                        cycle_cnt <= cycle_cnt + 1;
                    end if;
                else
                    cycle_cnt <= (others => '0');  -- Reset counter
                    cycle_flag <= '0';  -- Clear flag on unique output
                end if;
            end if;
        end if;
    end process;

    -- ★ B-1 FIX: Accumulate 4 successive 32-bit outputs into 128-bit register
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            sr_128   <= (others => '0');
            sr_count <= 0;
            sr_valid <= '0';
        elsif rising_edge(clk) then
            sr_valid <= '0';
            if valid_reg = '1' then
                -- Shift-in new 32-bit value (MSB-first: 127..96, 95..64, 63..32, 31..0)
                sr_128 <= sr_128(95 downto 0) & std_logic_vector(xor_out);
                if sr_count = 3 then
                    sr_valid <= '1';  -- Full 128-bit available
                    sr_count <= 0;
                else
                    sr_count <= sr_count + 1;
                end if;
            end if;
        end if;
    end process;

    -- ===== FSM =====
    process(clk, rst_n)
        variable sv : unsigned(31 downto 0);
    begin
        if rst_n = '0' then
            fsm      <= S_IDLE;
            xa_reg   <= SAFE_A;
            ra_reg   <= x"03FD70A4";  -- 3.99
            xb_reg   <= SAFE_B;
            rb_reg   <= R_B_DEF;      -- 3.97
            omx_a    <= (others => '0');
            omx_b    <= (others => '0');
            temp_a   <= (others => '0');
            temp_b   <= (others => '0');
            valid_reg <= '0';

        elsif rising_edge(clk) then
            valid_reg <= '0';

            if load_seed = '1' then
                sv := unsigned(seed);
                if sv = 0 or sv >= Q_ONE then
                    xa_reg <= SAFE_A;
                else
                    xa_reg <= sv;
                end if;
                ra_reg <= unsigned(r_param);
                -- Map B: derive seed from map A seed (offset)
                sv := unsigned(seed) xor x"00555555";
                if sv = 0 or sv >= Q_ONE then
                    xb_reg <= SAFE_B;
                else
                    xb_reg <= sv;
                end if;
                rb_reg <= R_B_DEF;
                fsm <= S_IDLE;

            -- ★ UPGRADE: Auto-reseed on cycle detection
            elsif cycle_flag = '1' then
                xa_reg <= SAFE_A;
                xb_reg <= SAFE_B;
                ra_reg <= x"03FD70A4";  -- 3.99
                rb_reg <= R_B_DEF;
                fsm <= S_IDLE;
            else
                case fsm is
                    when S_IDLE =>
                        if enable = '1' then
                            fsm <= S_SUB_A;
                        end if;

                    -- === Map A computation ===
                    when S_SUB_A =>
                        omx_a <= Q_ONE - xa_reg;
                        fsm <= S_MUL1_A;

                    when S_MUL1_A =>
                        temp_a <= mul_out;
                        fsm <= S_MUL2_A;

                    when S_MUL2_A =>
                        if mul_out = 0 or mul_out >= Q_ONE then
                            xa_reg <= SAFE_A;
                        else
                            xa_reg <= mul_out;
                        end if;
                        fsm <= S_SUB_B;

                    -- === Map B computation ===
                    when S_SUB_B =>
                        omx_b <= Q_ONE - xb_reg;
                        fsm <= S_MUL1_B;

                    when S_MUL1_B =>
                        temp_b <= mul_out;
                        fsm <= S_MUL2_B;

                    when S_MUL2_B =>
                        if mul_out = 0 or mul_out >= Q_ONE then
                            xb_reg <= SAFE_B;
                        else
                            xb_reg <= mul_out;
                        end if;
                        fsm <= S_VALID;

                    -- === Output ===
                    when S_VALID =>
                        valid_reg <= '1';
                        if enable = '1' then
                            fsm <= S_SUB_A;
                        else
                            fsm <= S_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;
