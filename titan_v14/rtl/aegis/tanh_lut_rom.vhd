--------------------------------------------------------------------------------
-- AEGIS Phase 2.2: tanh LUT ROM Entity
--------------------------------------------------------------------------------
-- Single-cycle registered ROM lookup for tanh activation function.
--
-- Architecture:
--   1. Input Q8.8 [-128.0, +127.996] maps to table index [0..255]
--      Active range: [-4.0, +4.0), step = 0.03125
--   2. Out-of-range inputs are SATURATED: x<-4 -> -1.0, x>=+4 -> +1.0
--   3. Output is REGISTERED for clean timing (1 clock latency)
--
-- Resource usage:
--   - 256 x 16-bit = 512 bytes (fits in 1 BRAM18 or distributed ROM)
--   - 1 comparator for saturation
--   - 1 output register
--
-- Usage:
--   Apply x_in, next rising_edge gives y_out = tanh(x_in) in Q8.8
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Import the ROM data from package
use work.tanh_lut_pkg.all;

entity tanh_lut_rom is
    port (
        clk     : in  std_logic;
        rst_n   : in  std_logic;
        x_in    : in  std_logic_vector(15 downto 0);  -- Q8.8 input
        y_out   : out std_logic_vector(15 downto 0)   -- Q8.8 tanh output
    );
end entity tanh_lut_rom;

architecture rtl of tanh_lut_rom is

    -- Q8.8 constants for saturation boundaries
    -- -4.0 in Q8.8 = -1024 = 0xFC00 (signed)
    -- +4.0 in Q8.8 = +1024 = 0x0400 (signed)
    constant X_MIN     : signed(15 downto 0) := to_signed(-1024, 16);  -- -4.0
    constant X_MAX     : signed(15 downto 0) := to_signed(1024, 16);   -- +4.0
    constant Y_SAT_NEG : std_logic_vector(15 downto 0) := x"FF00";     -- -1.0 in Q8.8
    constant Y_SAT_POS : std_logic_vector(15 downto 0) := x"0100";     -- +1.0 in Q8.8

    -- Address calculation:
    -- index = (x_signed - (-1024)) >> 3
    -- Since x ranges from -1024 to +1023 (2048 values),
    -- and we have 256 entries: 2048 / 256 = 8 = 2^3
    -- So index = (x_signed + 1024) >> 3 = (x_signed + 1024) / 8
    constant ADDR_SHIFT : integer := 3;  -- log2(2048/256) = log2(8) = 3
    constant OFFSET     : signed(15 downto 0) := to_signed(1024, 16);  -- +4.0

    signal x_signed : signed(15 downto 0);
    signal lut_addr : integer range 0 to 255;
    signal lut_data : std_logic_vector(15 downto 0);
    signal y_reg    : std_logic_vector(15 downto 0);

begin

    x_signed <= signed(x_in);
    y_out    <= y_reg;

    -- Combinational: address calculation and saturation check
    process(x_signed)
        variable addr_calc : signed(15 downto 0);
        variable addr_int  : integer;
    begin
        if x_signed <= X_MIN then
            -- Below range: saturate to -1.0
            lut_data <= Y_SAT_NEG;

        elsif x_signed >= X_MAX then
            -- Above range: saturate to +1.0
            lut_data <= Y_SAT_POS;

        else
            -- In range: compute LUT address
            -- addr = (x + 1024) / 8 = (x + 1024) >> 3
            addr_calc := x_signed + OFFSET;
            addr_int := to_integer(unsigned(addr_calc(10 downto ADDR_SHIFT)));

            -- Clamp to valid LUT range
            if addr_int > 255 then
                addr_int := 255;
            end if;

            lut_data <= TANH_ROM(addr_int);
        end if;
    end process;

    -- Registered output for clean timing
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            y_reg <= (others => '0');
        elsif rising_edge(clk) then
            y_reg <= lut_data;
        end if;
    end process;

end architecture rtl;
