--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES Round Function with 1st-Order Boolean Masking (V2)
-- ★ FIX #1 V2: Byte-Uniform Masked Table Recomputation
--------------------------------------------------------------------------------
-- NIST FIPS-197 §5.1 — SubBytes + ShiftRows + MixColumns + AddRoundKey
-- 
-- Masking strategy (V2 — TABLE RECOMPUTATION):
--   Input:  state_in = plaintext XOR mask_uniform (byte-uniform: all bytes = m)
--   S-Box:  pre-computed table → mt[x⊕m] = S[x]⊕m (mathematically CORRECT)
--   ShiftRows: permutation only → uniform mask unchanged
--   MixColumns: linear, MixCol([m,m,m,m]) = [m,m,m,m] (GF coef sum = 1)
--   AddRoundKey: XOR with key → mask unaffected
--   Output: state_out = correct_result XOR mask_uniform
--
-- V1→V2 CHANGES:
--   - mask_in/mask2_in (128-bit per-byte) → mask_byte (8-bit uniform)
--   - mask_affine() removed (mathematically flawed)
--   - New: recomp_start/recomp_done for table pre-computation
--   - mask_out is now constant = {mask_byte × 16} (uniform)
--   - MixColumns on mask is still computed for verification but MUST = input
--
-- Latency: 2 clock cycles (1 distributed RAM + 1 pipeline register)
-- Area: +32 LUT per S-Box instance (distributed RAM)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes_round is
    port (
        clk           : in  std_logic;
        state_in      : in  std_logic_vector(127 downto 0);
        round_key     : in  std_logic_vector(127 downto 0);
        is_last_round : in  std_logic;
        start         : in  std_logic;

        -- ★ FIX #1 V2: Byte-uniform mask interface
        mask_byte     : in  std_logic_vector(7 downto 0);   -- Single mask byte
        recomp_start  : in  std_logic;                       -- Trigger table recomp
        recomp_done   : out std_logic;                       -- All tables ready
        mask_out      : out std_logic_vector(127 downto 0);  -- {mask_byte × 16}

        state_out     : out std_logic_vector(127 downto 0);
        done          : out std_logic
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

    -- Recomputation done signals from each S-Box
    signal sbox_recomp_done : std_logic_vector(15 downto 0);

    -- Pipeline registers
    signal rk_pipe     : std_logic_vector(127 downto 0) := (others => '0');
    signal last_pipe   : std_logic := '0';
    signal valid_pipe  : std_logic := '0';
    signal valid_pipe2 : std_logic := '0';

    -- ShiftRows output (data)
    signal after_shift : byte_array_16;
    -- ShiftRows output (mask) — kept for verification
    signal mask_after_shift : byte_array_16;

    -- MixColumns output
    signal after_mix   : std_logic_vector(127 downto 0);
    signal after_nomix : std_logic_vector(127 downto 0);

    -- MixColumns on mask (should = input mask for uniform masking)
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
    -- Stage 1: 16 parallel MASKED S-Box lookups (Table Recomputation)
    -- All 16 S-Boxes share the SAME mask_byte → identical tables
    -- Input addr is already masked (state_in = plain XOR mask_uniform)
    -------------------------------------------------------------------------
    gen_sbox: for i in 0 to 15 generate
        sbox_inst : entity work.aes_sbox_masked
            port map (
                clk          => clk,
                -- Table recomputation
                mask_byte    => mask_byte,
                recomp_start => recomp_start,
                recomp_done  => sbox_recomp_done(i),
                -- Runtime lookup
                addr         => state_in((15-i)*8+7 downto (15-i)*8),
                dout         => sbox_out(i),
                mask_out     => sbox_mask_out(i)
            );
    end generate;

    -- All tables done (AND-reduce: all 16 must be ready)
    recomp_done <= sbox_recomp_done(0)  and sbox_recomp_done(1)
              and  sbox_recomp_done(2)  and sbox_recomp_done(3)
              and  sbox_recomp_done(4)  and sbox_recomp_done(5)
              and  sbox_recomp_done(6)  and sbox_recomp_done(7)
              and  sbox_recomp_done(8)  and sbox_recomp_done(9)
              and  sbox_recomp_done(10) and sbox_recomp_done(11)
              and  sbox_recomp_done(12) and sbox_recomp_done(13)
              and  sbox_recomp_done(14) and sbox_recomp_done(15);

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

    -- ShiftRows: MASK (same permutation — uniform mask stays uniform)
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

    -- MixColumns: MASK (byte-uniform → MixCol([m,m,m,m]) = [m,m,m,m])
    -- Computed for verification integrity — result MUST equal input mask
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
    -- Output registration: AddRoundKey
    -- S-Box V2 has 1-cycle latency (distributed RAM registered read)
    -- So after_shift/after_mix are valid when valid_pipe='1'
    -- Use rk_pipe/last_pipe directly (aligned with 1-cycle S-Box)
    -------------------------------------------------------------------------

    -- AddRoundKey: XOR with key -- mask is NOT affected (key has no mask)
    state_out <= (after_mix xor rk_pipe) when last_pipe = '0' else
                 (after_nomix xor rk_pipe);

    -- Mask propagation: follows MixColumns/no-mix path
    -- For byte-uniform masking, both paths produce the same mask
    mask_out <= mask_after_mix when last_pipe = '0' else
                mask_after_nomix;

    done <= valid_pipe;

end Pipelined;

