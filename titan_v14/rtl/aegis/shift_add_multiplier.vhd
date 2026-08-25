--------------------------------------------------------------------------------
-- AEGIS PHASE 2.1: Fixed-Point Shift-Add Multiplier
--------------------------------------------------------------------------------
-- Q8.8 signed fixed-point multiplier WITHOUT DSP48 blocks.
-- Uses iterative shift-and-add algorithm (1 bit per clock cycle).
--
-- Algorithm:
--   1. Convert both operands to absolute magnitude
--   2. For each bit of |b|: if bit=1, add shifted |a| to accumulator
--   3. Apply sign correction (XOR of input signs)
--   4. Right-shift accumulator by FRAC_BITS to realign Q-format
--   5. Saturate to output range, flag overflow if needed
--
-- Timing:  16 clock cycles (1 per bit of multiplicand)
-- Area:    ~200 LUTs (no DSP48)
-- Format:  Q(INT_BITS).(FRAC_BITS), default Q8.8
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity shift_add_multiplier is
    generic (
        INT_BITS  : integer := 8;
        FRAC_BITS : integer := 8
    );
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;
        start    : in  std_logic;
        a_in     : in  std_logic_vector(INT_BITS + FRAC_BITS - 1 downto 0);
        b_in     : in  std_logic_vector(INT_BITS + FRAC_BITS - 1 downto 0);
        result   : out std_logic_vector(INT_BITS + FRAC_BITS - 1 downto 0);
        done     : out std_logic;
        overflow : out std_logic
    );
    -- Prevent Vivado from inferring DSP48 slices
    attribute use_dsp : string;
    attribute use_dsp of shift_add_multiplier : entity is "no";
end entity shift_add_multiplier;

architecture rtl of shift_add_multiplier is

    constant WIDTH     : integer := INT_BITS + FRAC_BITS;     -- 16
    constant ACC_WIDTH : integer := 2 * WIDTH;                -- 32
    constant BIT_COUNT : integer := WIDTH;                    -- 16 iterations

    -- Q8.8 output range (signed): -32768 to +32767
    -- But after right-shift of product, we check for overflow of the
    -- INT_BITS portion (values that don't fit in Q8.8 range).
    constant MAX_POS : signed(ACC_WIDTH - 1 downto 0) :=
        to_signed(2**(WIDTH - 1) - 1, ACC_WIDTH);   -- +32767
    constant MAX_NEG : signed(ACC_WIDTH - 1 downto 0) :=
        to_signed(-(2**(WIDTH - 1)), ACC_WIDTH);     -- -32768

    type state_t is (S_IDLE, S_COMPUTE, S_DONE);

    signal state      : state_t;
    signal accumulator : signed(ACC_WIDTH - 1 downto 0);
    signal a_mag       : unsigned(WIDTH - 1 downto 0);
    signal b_reg       : unsigned(WIDTH - 1 downto 0);
    signal bit_idx     : integer range 0 to BIT_COUNT - 1;
    signal result_sign : std_logic;

    signal result_reg   : std_logic_vector(WIDTH - 1 downto 0);
    signal done_reg     : std_logic;
    signal overflow_reg : std_logic;

begin

    result   <= result_reg;
    done     <= done_reg;
    overflow <= overflow_reg;

    process(clk, rst_n)
        variable shifted_a   : signed(ACC_WIDTH - 1 downto 0);
        variable raw_result  : signed(ACC_WIDTH - 1 downto 0);
        variable final_val   : signed(WIDTH - 1 downto 0);
    begin
        if rst_n = '0' then
            state        <= S_IDLE;
            accumulator  <= (others => '0');
            a_mag        <= (others => '0');
            b_reg        <= (others => '0');
            bit_idx      <= 0;
            result_sign  <= '0';
            result_reg   <= (others => '0');
            done_reg     <= '0';
            overflow_reg <= '0';

        elsif rising_edge(clk) then
            case state is

                -- ============================================
                -- IDLE: Wait for start pulse
                -- ============================================
                when S_IDLE =>
                    done_reg     <= '0';
                    overflow_reg <= '0';

                    if start = '1' then
                        -- Determine result sign (XOR of input signs)
                        result_sign <= a_in(WIDTH - 1) xor b_in(WIDTH - 1);

                        -- Convert to absolute magnitude
                        if signed(a_in) < 0 then
                            a_mag <= unsigned(-signed(a_in));
                        else
                            a_mag <= unsigned(a_in);
                        end if;

                        if signed(b_in) < 0 then
                            b_reg <= unsigned(-signed(b_in));
                        else
                            b_reg <= unsigned(b_in);
                        end if;

                        accumulator <= (others => '0');
                        bit_idx     <= 0;
                        state       <= S_COMPUTE;
                    end if;

                -- ============================================
                -- COMPUTE: Process one bit per clock cycle
                -- ============================================
                when S_COMPUTE =>
                    -- If current bit of b is '1', add shifted a to accumulator
                    if b_reg(bit_idx) = '1' then
                        -- Zero-extend a_mag to ACC_WIDTH then shift left
                        shifted_a := shift_left(
                            resize(signed('0' & a_mag), ACC_WIDTH),
                            bit_idx);
                        accumulator <= accumulator + shifted_a;
                    end if;

                    if bit_idx = BIT_COUNT - 1 then
                        state <= S_DONE;
                    else
                        bit_idx <= bit_idx + 1;
                    end if;

                -- ============================================
                -- DONE: Apply sign, right-shift, saturate
                -- ============================================
                when S_DONE =>
                    -- Apply sign
                    if result_sign = '1' then
                        raw_result := -accumulator;
                    else
                        raw_result := accumulator;
                    end if;

                    -- Right-shift by FRAC_BITS to realign
                    -- Q8.8 * Q8.8 = Q16.16, shift right 8 = Q16.8
                    -- Then take lower 16 bits = Q8.8
                    raw_result := shift_right(raw_result, FRAC_BITS);

                    -- Overflow detection and saturation
                    if raw_result > MAX_POS then
                        result_reg   <= std_logic_vector(MAX_POS(WIDTH - 1 downto 0));
                        overflow_reg <= '1';
                    elsif raw_result < MAX_NEG then
                        result_reg   <= std_logic_vector(MAX_NEG(WIDTH - 1 downto 0));
                        overflow_reg <= '1';
                    else
                        result_reg   <= std_logic_vector(raw_result(WIDTH - 1 downto 0));
                        overflow_reg <= '0';
                    end if;

                    done_reg <= '1';
                    state    <= S_IDLE;

            end case;
        end if;
    end process;

end architecture rtl;
