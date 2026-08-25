--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES S-Box with 1st-Order Boolean Masking (TABLE RECOMP)
-- FIX #1 V2: Mathematically CORRECT masked S-Box
--------------------------------------------------------------------------------
-- PROBLEM (V1): mask_affine() != S-Box compensation
--               S(x xor m) xor affine(m) != S(x) xor m_out
--               S-Box non-linearity makes XOR-based affine correction IMPOSSIBLE.
--
-- SOLUTION (V2): Pre-computed Masked Table (Byte-Uniform Masking)
--   Before each encryption, build masked_table[a] = S[a XOR m] XOR m
--   At runtime, input is x XOR m -> lookup masked_table[x XOR m] = S[x] XOR m
--
-- MATHEMATICAL PROOF:
--   Let m = mask_byte (constant, same byte for all 16 S-Boxes)
--   Pre-compute: mt[a] = S[a XOR m] XOR m       for all a in {0..255}
--   Runtime input: addr = x XOR m                (data already masked by caller)
--   Lookup: mt[x XOR m] = S[(x XOR m) XOR m] XOR m = S[x] XOR m  (correct!)
--
-- LATENCY:   Recomputation: 259 cycles (one-time per encryption)
--            Runtime lookup: 1 cycle (distributed RAM, registered)
-- AREA:      +256x8 distributed RAM per instance (~32 LUT)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes_sbox_masked is
    port (
        clk          : in  std_logic;

        -- Table recomputation interface
        mask_byte    : in  std_logic_vector(7 downto 0);  -- Single uniform mask
        recomp_start : in  std_logic;  -- Pulse: start recomputation
        recomp_done  : out std_logic;  -- '1' when table is ready

        -- Runtime lookup (1 cycle latency)
        addr         : in  std_logic_vector(7 downto 0);  -- Masked input (x XOR m)
        dout         : out std_logic_vector(7 downto 0);  -- S(x) XOR m (correct!)
        mask_out     : out std_logic_vector(7 downto 0)   -- = mask_byte (uniform)
    );
end aes_sbox_masked;

architecture TableRecomp of aes_sbox_masked is

    -------------------------------------------------------------------------
    -- Internal signals
    -------------------------------------------------------------------------

    -- Original S-Box BRAM interface (used for recomputation reads)
    signal bram_addr     : std_logic_vector(7 downto 0);
    signal bram_dout     : std_logic_vector(7 downto 0);  -- S[bram_addr], 1-cycle

    -- Masked table (256x8 distributed RAM)
    type ram_256x8_t is array (0 to 255) of std_logic_vector(7 downto 0);
    signal masked_table  : ram_256x8_t := (others => (others => '0'));

    -- Recomputation FSM
    type recomp_state_t is (S_IDLE, S_PRIME, S_FILL, S_DONE);
    signal rc_state      : recomp_state_t := S_IDLE;
    signal rc_counter    : unsigned(8 downto 0) := (others => '0');  -- 0..256
    signal rc_mask_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal table_valid   : std_logic := '0';

    -- Pipeline delay for BRAM read
    signal rc_wr_pending : std_logic := '0';
    signal rc_wr_idx     : unsigned(7 downto 0) := (others => '0');

    -- Runtime lookup register
    signal lookup_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal mask_byte_r   : std_logic_vector(7 downto 0) := (others => '0');

    -- Synthesis protection
    attribute dont_touch : string;
    -- NOTE: dont_touch on RAM array crashes Vivado 2025.2 optimizer!
    -- Use ram_style instead for memory inference control
    attribute ram_style : string;
    attribute ram_style of masked_table : signal is "distributed";
    attribute dont_touch of lookup_reg   : signal is "true";
    attribute dont_touch of rc_mask_reg  : signal is "true";
    attribute dont_touch of table_valid  : signal is "true";

begin

    -------------------------------------------------------------------------
    -- Instance: Original BRAM S-Box (256x8 ROM)
    -- Used during recomputation to read S[counter XOR m]
    -------------------------------------------------------------------------
    sbox_core : entity work.aes_sbox
        port map (
            clk  => clk,
            addr => bram_addr,
            dout => bram_dout
        );

    -- Address mux: recomputation vs runtime
    -- During recomp, feed sequential addresses to BRAM
    -- During runtime, BRAM is unused (we read from distributed RAM)
    bram_addr <= std_logic_vector(rc_counter(7 downto 0) xor unsigned(rc_mask_reg))
                 when table_valid = '0'
                 else (others => '0');

    -------------------------------------------------------------------------
    -- Recomputation FSM
    -- Builds masked_table[a] = S[a XOR m] XOR m for a = 0..255
    --
    -- Timing (BRAM has 1-cycle read latency):
    --   S_IDLE:  recomp_start received -> save mask, move to S_PRIME
    --   S_PRIME: BRAM addr = (0 XOR m) presented, counter=0, wait 1 cycle
    --            (BRAM needs 1 cycle to output S[0 XOR m])
    --   S_FILL:  counter increments 0..256
    --            Each cycle: write mt[counter-1] = S[(counter-1) XOR m] XOR m
    --                        present new addr = (counter XOR m) to BRAM
    --            When counter=256: all 256 entries written, move to S_DONE
    --   S_DONE:  table_valid = '1', ready for runtime lookups
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            case rc_state is

                when S_IDLE =>
                    if recomp_start = '1' then
                        rc_mask_reg  <= mask_byte;
                        rc_counter   <= (others => '0');
                        table_valid  <= '0';
                        rc_state     <= S_PRIME;
                    end if;

                when S_PRIME =>
                    -- BRAM is reading S[0 XOR m] this cycle (addr was set combinationally)
                    -- Output will be valid NEXT cycle
                    -- Increment counter to 1 so BRAM gets addr (1 XOR m) next
                    rc_counter <= to_unsigned(1, 9);
                    rc_state   <= S_FILL;

                when S_FILL =>
                    -- bram_dout now contains S[(counter-1) XOR m]
                    -- Write: mt[counter-1] = S[(counter-1) XOR m] XOR m
                    if rc_counter <= 256 then
                        masked_table(to_integer(rc_counter(7 downto 0) - 1))
                            <= bram_dout xor rc_mask_reg;
                    end if;

                    if rc_counter = 256 then
                        -- All 256 entries written (counter went 1..256)
                        table_valid <= '1';
                        rc_state    <= S_DONE;
                    else
                        rc_counter <= rc_counter + 1;
                    end if;

                when S_DONE =>
                    -- Table is valid: runtime lookups active
                    if recomp_start = '1' then
                        rc_mask_reg  <= mask_byte;
                        rc_counter   <= (others => '0');
                        table_valid  <= '0';
                        rc_state     <= S_PRIME;
                    end if;

            end case;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Runtime lookup: read from masked_table (registered output)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if table_valid = '1' then
                if is_x(addr) then
                    lookup_reg <= (others => '0');
                else
                    lookup_reg <= masked_table(to_integer(unsigned(addr)));
                end if;
            else
                lookup_reg <= (others => '0');
            end if;
            mask_byte_r <= rc_mask_reg;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Output assignments
    -------------------------------------------------------------------------
    dout        <= lookup_reg;           -- S(x) XOR m (mathematically correct)
    mask_out    <= mask_byte_r;          -- = m (uniform, constant per encryption)
    recomp_done <= table_valid;          -- '1' when table is ready for lookups

end TableRecomp;
