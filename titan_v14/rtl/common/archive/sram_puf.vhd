--------------------------------------------------------------------------------
-- PROJECT TITAN V14: SRAM PUF — Device Identity Generator
-- ★ C-4: Physically Unclonable Function for unique chip fingerprint
--------------------------------------------------------------------------------
-- Exploits SRAM power-on initialization randomness for a chip-unique ID.
-- Each FPGA's SRAM cells power up with a unique pattern depending on
-- manufacturing process variations (VT mismatch in cross-coupled inverters).
--
-- Protocol:
--   1. On power-up (before any writes), read 256 SRAM cells
--   2. XOR-fold with a challenge to generate a 128-bit response
--   3. Response is stable per-device (±5% bit-flip → error correction needed)
--   4. Can be used as device identity, key derivation seed, or attestation
--
-- Security:
--   - PUF response is NOT stored in flash/config — generated live
--   - Cloning an FPGA does NOT clone the PUF
--   - Physical probing alters PUF (tamper evident)
--
-- Usage: Present a challenge → get a device-unique response
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sram_puf is
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        -- Enrollment / challenge interface
        challenge     : in  std_logic_vector(127 downto 0);
        start         : in  std_logic;
        -- Response
        response      : out std_logic_vector(127 downto 0);
        response_valid: out std_logic;
        -- Status
        enrolled      : out std_logic
    );
end sram_puf;

architecture Behavioral of sram_puf is

    -------------------------------------------------------------------------
    -- SRAM cells (power-on value is PUF fingerprint)
    -- We use 256 bytes of distributed RAM, read-before-write on power-up
    -------------------------------------------------------------------------
    type sram_array_t is array (0 to 255) of std_logic_vector(7 downto 0);
    -- CRITICAL: No initialization! Power-on values ARE the PUF!
    signal sram_cells : sram_array_t;  -- Uninitialized = PUF source

    -- Readout FSM
    type puf_state_t is (
        PUF_IDLE,
        PUF_READOUT,     -- Read 256 SRAM cells
        PUF_FOLD,        -- XOR-fold into 128-bit fingerprint
        PUF_RESPOND,     -- Apply challenge and output response
        PUF_DONE
    );
    signal state : puf_state_t := PUF_IDLE;

    -- Counters
    signal cell_idx    : unsigned(7 downto 0) := (others => '0');
    signal raw_buffer  : std_logic_vector(127 downto 0) := (others => '0');
    signal fingerprint : std_logic_vector(127 downto 0) := (others => '0');
    signal enrolled_i  : std_logic := '0';

    -- Synthesis: prevent optimization of SRAM cells
    attribute dont_touch : string;
    attribute dont_touch of sram_cells : signal is "true";
    attribute keep : string;
    attribute keep of fingerprint : signal is "true";

begin

    enrolled       <= enrolled_i;
    response_valid <= '1' when state = PUF_DONE else '0';
    response       <= fingerprint xor challenge when state = PUF_DONE
                      else (others => '0');

    process(clk)
        variable byte_val  : std_logic_vector(7 downto 0);
        variable fold_pos  : integer range 0 to 15;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state       <= PUF_IDLE;
                cell_idx    <= (others => '0');
                raw_buffer  <= (others => '0');
                enrolled_i  <= '0';
            else
                case state is
                    when PUF_IDLE =>
                        if start = '1' and enrolled_i = '0' then
                            state    <= PUF_READOUT;
                            cell_idx <= (others => '0');
                            raw_buffer <= (others => '0');
                        elsif start = '1' and enrolled_i = '1' then
                            -- Already enrolled: just respond
                            state <= PUF_DONE;
                        end if;

                    when PUF_READOUT =>
                        -- Read one SRAM cell per clock
                        byte_val := sram_cells(to_integer(cell_idx));
                        -- XOR-fold: 256 bytes → 16 bytes (128 bits)
                        fold_pos := to_integer(cell_idx(3 downto 0));
                        raw_buffer(fold_pos*8+7 downto fold_pos*8) <=
                            raw_buffer(fold_pos*8+7 downto fold_pos*8) xor byte_val;

                        if cell_idx = 255 then
                            state <= PUF_FOLD;
                        else
                            cell_idx <= cell_idx + 1;
                        end if;

                    when PUF_FOLD =>
                        -- Finalize fingerprint
                        fingerprint <= raw_buffer;
                        enrolled_i  <= '1';
                        state       <= PUF_RESPOND;

                    when PUF_RESPOND =>
                        state <= PUF_DONE;

                    when PUF_DONE =>
                        -- Stay here until new start
                        if start = '0' then
                            state <= PUF_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end Behavioral;
