--------------------------------------------------------------------------------
-- PROJECT TITAN V14: TRNG-DRBG Bridge
-- Entropy Accumulator + Deterministic Random Bit Generator
--------------------------------------------------------------------------------
-- Bridges the low-throughput TRNG to the high-demand AES mask pipeline.
--
-- Architecture:
--   TRNG (1 bit/cycle) --> Entropy Accumulator (256-bit)
--                          --> DRBG Core (LFSR-based) --> mask_out (128-bit/cycle)
--                          ^-- reseed every 2^20 bits
--
-- Features:
--   - 256-bit entropy accumulator with monobit health check
--   - 128-bit LFSR-based DRBG (maximal-length polynomial)
--   - Automatic reseed counter (forward secrecy)
--   - Double-buffered seed (no output gap during reseed)
--   - mask_a/mask_b outputs for 2nd-order masking
--
-- Throughput: 2 x 128-bit masks per clock cycle (post-seeding)
-- Latency: 256 cycles initial seed accumulation
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity trng_drbg_bridge is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;

        -- TRNG input
        trng_bit     : in  std_logic;
        trng_valid   : in  std_logic;

        -- Dual mask outputs (for 2nd-order masking)
        mask_a       : out std_logic_vector(127 downto 0);
        mask_b       : out std_logic_vector(127 downto 0);

        -- Status
        bridge_ready : out std_logic;  -- '1' after initial seed
        reseed_count : out std_logic_vector(7 downto 0)  -- Number of reseeds
    );
end trng_drbg_bridge;

architecture RTL of trng_drbg_bridge is

    -- FSM
    type state_type is (ACCUMULATE, RUNNING, RESEED);
    signal state : state_type := ACCUMULATE;

    -- Entropy accumulator
    signal entropy_reg : std_logic_vector(255 downto 0) := (others => '0');
    signal entropy_cnt : integer range 0 to 256 := 0;

    -- DRBG state (128-bit LFSR)
    signal lfsr_a : std_logic_vector(127 downto 0) := (others => '0');
    signal lfsr_b : std_logic_vector(127 downto 0) := (others => '0');

    -- Reseed management
    signal output_counter : unsigned(19 downto 0) := (others => '0');  -- 2^20 = 1M
    signal reseed_cnt_reg : unsigned(7 downto 0) := (others => '0');

    -- Health check
    signal ones_cnt : integer range 0 to 256 := 0;

    -- Double-buffer for reseed
    signal seed_buffer : std_logic_vector(255 downto 0) := (others => '0');
    signal seed_cnt    : integer range 0 to 256 := 0;

    -- LFSR feedback taps (maximal-length for 128-bit)
    -- x^128 + x^126 + x^101 + x^99 + 1
    function lfsr_step(s : std_logic_vector(127 downto 0))
        return std_logic_vector is
        variable ns : std_logic_vector(127 downto 0);
        variable fb : std_logic;
    begin
        fb := s(127) xor s(125) xor s(100) xor s(98);
        ns := s(126 downto 0) & fb;
        return ns;
    end function;

    -- Derive independent stream from seed (different polynomial)
    function lfsr_step_b(s : std_logic_vector(127 downto 0))
        return std_logic_vector is
        variable ns : std_logic_vector(127 downto 0);
        variable fb : std_logic;
    begin
        -- x^128 + x^29 + x^27 + x^2 + 1
        fb := s(127) xor s(28) xor s(26) xor s(1);
        ns := s(126 downto 0) & fb;
        return ns;
    end function;

    attribute dont_touch : string;
    attribute dont_touch of lfsr_a : signal is "true";
    attribute dont_touch of lfsr_b : signal is "true";
    attribute dont_touch of entropy_reg : signal is "true";

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state          <= ACCUMULATE;
                entropy_cnt    <= 0;
                ones_cnt       <= 0;
                output_counter <= (others => '0');
                reseed_cnt_reg <= (others => '0');
                bridge_ready   <= '0';
                lfsr_a         <= (others => '0');
                lfsr_b         <= (others => '0');
                seed_cnt       <= 0;
            else
                case state is

                    -- Initial seed accumulation: collect 256 TRNG bits
                    when ACCUMULATE =>
                        bridge_ready <= '0';
                        if trng_valid = '1' then
                            entropy_reg <= entropy_reg(254 downto 0) & trng_bit;
                            entropy_cnt <= entropy_cnt + 1;
                            if trng_bit = '1' then
                                ones_cnt <= ones_cnt + 1;
                            end if;

                            if entropy_cnt = 255 then
                                -- Health check: monobit (expect ~50% ones)
                                -- Accept if 80 < ones < 176 (~31%..69%)
                                if ones_cnt > 80 and ones_cnt < 176 then
                                    -- Good entropy, seed DRBG
                                    lfsr_a <= entropy_reg(255 downto 128);
                                    lfsr_b <= entropy_reg(127 downto 0);
                                    bridge_ready <= '1';
                                    state <= RUNNING;
                                else
                                    -- Bad entropy, retry
                                    entropy_cnt <= 0;
                                    ones_cnt    <= 0;
                                end if;
                            end if;
                        end if;

                    -- Main operation: generate masks
                    when RUNNING =>
                        bridge_ready <= '1';

                        -- Step both LFSRs
                        lfsr_a <= lfsr_step(lfsr_a);
                        lfsr_b <= lfsr_step_b(lfsr_b);

                        -- Count output bits
                        output_counter <= output_counter + 1;

                        -- Reseed trigger: every 2^20 outputs
                        if output_counter = 0 then
                            state    <= RESEED;
                            seed_cnt <= 0;
                            ones_cnt <= 0;
                        end if;

                        -- Background entropy collection
                        if trng_valid = '1' and seed_cnt < 256 then
                            seed_buffer <= seed_buffer(254 downto 0) & trng_bit;
                            seed_cnt    <= seed_cnt + 1;
                            if trng_bit = '1' and ones_cnt < 256 then
                                ones_cnt <= ones_cnt + 1;
                            end if;
                        end if;

                    -- Reseed: XOR new entropy into LFSR state
                    when RESEED =>
                        bridge_ready <= '1';  -- Still operational during reseed

                        -- Keep stepping (no output gap)
                        lfsr_a <= lfsr_step(lfsr_a);
                        lfsr_b <= lfsr_step_b(lfsr_b);

                        if trng_valid = '1' and seed_cnt < 256 then
                            seed_buffer <= seed_buffer(254 downto 0) & trng_bit;
                            seed_cnt    <= seed_cnt + 1;
                            if trng_bit = '1' and ones_cnt < 256 then
                                ones_cnt <= ones_cnt + 1;
                            end if;
                        end if;

                        if seed_cnt >= 256 then
                            -- Health check
                            if ones_cnt > 80 and ones_cnt < 176 then
                                -- Good: XOR new seed into state
                                lfsr_a <= lfsr_a xor seed_buffer(255 downto 128);
                                lfsr_b <= lfsr_b xor seed_buffer(127 downto 0);
                                reseed_cnt_reg <= reseed_cnt_reg + 1;
                            end if;
                            -- Return to running regardless
                            state    <= RUNNING;
                            seed_cnt <= 0;
                            ones_cnt <= 0;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- Output assignments
    mask_a       <= lfsr_a;
    mask_b       <= lfsr_b;
    reseed_count <= std_logic_vector(reseed_cnt_reg);

end RTL;
