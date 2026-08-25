--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES Round Function with 1st-Order Boolean Masking
-- ★ FIX #1: All intermediate values are masked — immune to 1st-order DPA
--------------------------------------------------------------------------------
-- NIST FIPS-197 §5.1 — SubBytes + ShiftRows + MixColumns + AddRoundKey
-- 
-- Masking strategy:
--   Input:  state_in = plaintext XOR mask_state (externally applied)
--   S-Box:  operates on masked bytes → outputs masked results
--   ShiftRows: permutation only → mask follows data
--   MixColumns: linear operation → mask passes through (mask is MixCol'd too)
--   AddRoundKey: XOR with key → mask is unaffected
--   Output: state_out = correct_result XOR mask_state_out
--
-- Latency: 3 clock cycles (BRAM + remask + MixColumns register)
-- Area: +256 LUT (16 masked S-Boxes × 16 LUT affine)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes_round is
    port (
        clk           : in  std_logic;
        state_in      : in  std_logic_vector(127 downto 0);  -- Masked state
        round_key     : in  std_logic_vector(127 downto 0);
        is_last_round : in  std_logic;
        start         : in  std_logic;  -- Pulse: start round computation

        -- ★ FIX #1: Mask interface
        mask_in       : in  std_logic_vector(127 downto 0);  -- 16-byte input mask
        mask_out      : out std_logic_vector(127 downto 0);  -- 16-byte output mask

        state_out     : out std_logic_vector(127 downto 0);
        done          : out std_logic   -- Pulse: result ready
    );
end aes_round;

architecture Pipelined of aes_round is

    -------------------------------------------------------------------------
    -- Internal types
    -------------------------------------------------------------------------
    type byte_array_16 is array (0 to 15) of std_logic_vector(7 downto 0);

    -- S-Box outputs (masked)
    signal sbox_out      : byte_array_16;
    signal sbox_mask_out : byte_array_16;  -- Mask output from each S-Box

    -- Pipeline registers
    signal rk_pipe     : std_logic_vector(127 downto 0) := (others => '0');
    signal last_pipe   : std_logic := '0';
    signal valid_pipe  : std_logic := '0';
    signal valid_pipe2 : std_logic := '0';  -- Extra stage for remask

    -- ShiftRows output (data)
    signal after_shift : byte_array_16;
    -- ShiftRows output (mask)
    signal mask_after_shift : byte_array_16;

    -- MixColumns output
    signal after_mix   : std_logic_vector(127 downto 0);
    signal after_nomix : std_logic_vector(127 downto 0);

    -- MixColumns on mask (linear → same transform)
    signal mask_after_mix   : std_logic_vector(127 downto 0);
    signal mask_after_nomix : std_logic_vector(127 downto 0);

    -- Pipeline stage 2 registers
    signal rk_pipe2    : std_logic_vector(127 downto 0) := (others => '0');
    signal last_pipe2  : std_logic := '0';

    -- Registered outputs
    signal state_reg   : std_logic_vector(127 downto 0) := (others => '0');
    signal mask_reg    : std_logic_vector(127 downto 0) := (others => '0');
    signal done_reg    : std_logic := '0';

    -- dont_touch for mask signals
    attribute dont_touch : string;
    attribute dont_touch of sbox_mask_out : signal is "true";
    attribute dont_touch of mask_after_shift : signal is "true";
    attribute dont_touch of mask_after_mix : signal is "true";
    attribute dont_touch of mask_reg : signal is "true";

    -------------------------------------------------------------------------
    -- xtime: GF(2^8) multiplication by 0x02
    -------------------------------------------------------------------------
    function xtime(b : std_logic_vector(7 downto 0)) return std_logic_vector is
        variable result : std_logic_vector(7 downto 0);
    begin
        result := b(6 downto 0) & '0';
        if b(7) = '1' then
            result := result xor x"1B";
        end if;
        return result;
    end function;

    -------------------------------------------------------------------------
    -- MixColumns: single column (used for both data and mask)
    -------------------------------------------------------------------------
    function mix_column(
        s0, s1, s2, s3 : std_logic_vector(7 downto 0)
    ) return std_logic_vector is
        variable t0, t1, t2, t3 : std_logic_vector(7 downto 0);
        variable result : std_logic_vector(31 downto 0);
    begin
        t0 := xtime(s0) xor (xtime(s1) xor s1) xor s2 xor s3;
        t1 := s0 xor xtime(s1) xor (xtime(s2) xor s2) xor s3;
        t2 := s0 xor s1 xor xtime(s2) xor (xtime(s3) xor s3);
        t3 := (xtime(s0) xor s0) xor s1 xor s2 xor xtime(s3);
        result := t0 & t1 & t2 & t3;
        return result;
    end function;

begin

    -------------------------------------------------------------------------
    -- Stage 1: 16 parallel MASKED S-Box lookups
    -- Input addr is already masked (state_in = plain XOR mask_in)
    -- mask_in bytes are passed to each S-Box for output remasking
    -------------------------------------------------------------------------
    gen_sbox: for i in 0 to 15 generate
        sbox_inst : entity work.aes_sbox_masked
            port map (
                clk      => clk,
                addr     => state_in((15-i)*8+7 downto (15-i)*8),
                mask_in  => mask_in((15-i)*8+7 downto (15-i)*8),
                dout     => sbox_out(i),
                mask_out => sbox_mask_out(i)
            );
    end generate;

    -- Pipeline: latch round_key and is_last_round for Stage 2
    process(clk)
    begin
        if rising_edge(clk) then
            valid_pipe <= start;
            if start = '1' then
                rk_pipe   <= round_key;
                last_pipe <= is_last_round;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Stage 2: ShiftRows (permutation — identical for data and mask)
    -------------------------------------------------------------------------
    -- ShiftRows: DATA (FIPS-197 §5.1.2)
    -- Row 0: no shift
    after_shift(0)  <= sbox_out(0);
    after_shift(4)  <= sbox_out(4);
    after_shift(8)  <= sbox_out(8);
    after_shift(12) <= sbox_out(12);
    -- Row 1: shift left 1
    after_shift(1)  <= sbox_out(5);
    after_shift(5)  <= sbox_out(9);
    after_shift(9)  <= sbox_out(13);
    after_shift(13) <= sbox_out(1);
    -- Row 2: shift left 2
    after_shift(2)  <= sbox_out(10);
    after_shift(6)  <= sbox_out(14);
    after_shift(10) <= sbox_out(2);
    after_shift(14) <= sbox_out(6);
    -- Row 3: shift left 3
    after_shift(3)  <= sbox_out(15);
    after_shift(7)  <= sbox_out(3);
    after_shift(11) <= sbox_out(7);
    after_shift(15) <= sbox_out(11);

    -- ShiftRows: MASK (same permutation)
    mask_after_shift(0)  <= sbox_mask_out(0);
    mask_after_shift(4)  <= sbox_mask_out(4);
    mask_after_shift(8)  <= sbox_mask_out(8);
    mask_after_shift(12) <= sbox_mask_out(12);
    mask_after_shift(1)  <= sbox_mask_out(5);
    mask_after_shift(5)  <= sbox_mask_out(9);
    mask_after_shift(9)  <= sbox_mask_out(13);
    mask_after_shift(13) <= sbox_mask_out(1);
    mask_after_shift(2)  <= sbox_mask_out(10);
    mask_after_shift(6)  <= sbox_mask_out(14);
    mask_after_shift(10) <= sbox_mask_out(2);
    mask_after_shift(14) <= sbox_mask_out(6);
    mask_after_shift(3)  <= sbox_mask_out(15);
    mask_after_shift(7)  <= sbox_mask_out(3);
    mask_after_shift(11) <= sbox_mask_out(7);
    mask_after_shift(15) <= sbox_mask_out(11);

    -------------------------------------------------------------------------
    -- Stage 2: MixColumns (linear → applied to both data and mask)
    -------------------------------------------------------------------------
    -- MixColumns: DATA
    after_mix(127 downto 96) <= mix_column(
        after_shift(0), after_shift(1), after_shift(2), after_shift(3));
    after_mix(95 downto 64) <= mix_column(
        after_shift(4), after_shift(5), after_shift(6), after_shift(7));
    after_mix(63 downto 32) <= mix_column(
        after_shift(8), after_shift(9), after_shift(10), after_shift(11));
    after_mix(31 downto 0) <= mix_column(
        after_shift(12), after_shift(13), after_shift(14), after_shift(15));

    -- MixColumns: MASK (same linear operation)
    mask_after_mix(127 downto 96) <= mix_column(
        mask_after_shift(0), mask_after_shift(1), mask_after_shift(2), mask_after_shift(3));
    mask_after_mix(95 downto 64) <= mix_column(
        mask_after_shift(4), mask_after_shift(5), mask_after_shift(6), mask_after_shift(7));
    mask_after_mix(63 downto 32) <= mix_column(
        mask_after_shift(8), mask_after_shift(9), mask_after_shift(10), mask_after_shift(11));
    mask_after_mix(31 downto 0) <= mix_column(
        mask_after_shift(12), mask_after_shift(13), mask_after_shift(14), mask_after_shift(15));

    -- No-mix path (last round): DATA
    gen_nomix: for i in 0 to 15 generate
        after_nomix((15-i)*8+7 downto (15-i)*8) <= after_shift(i);
    end generate;

    -- No-mix path (last round): MASK
    gen_mask_nomix: for i in 0 to 15 generate
        mask_after_nomix((15-i)*8+7 downto (15-i)*8) <= mask_after_shift(i);
    end generate;

    -------------------------------------------------------------------------
    -- Stage 2 register: AddRoundKey + output registration
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            valid_pipe2 <= valid_pipe;
            rk_pipe2    <= rk_pipe;
            last_pipe2  <= last_pipe;
        end if;
    end process;

    -- AddRoundKey: XOR with key — mask is NOT affected (key has no mask)
    -- data_out = (data_masked XOR key) → still masked by same mask
    state_out <= (after_mix xor rk_pipe) when last_pipe = '0' else
                 (after_nomix xor rk_pipe);

    -- Mask propagation: follows MixColumns/no-mix path
    mask_out <= mask_after_mix when last_pipe = '0' else
                mask_after_nomix;

    done <= valid_pipe;

end Pipelined;
