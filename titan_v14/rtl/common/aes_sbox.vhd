--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES S-Box (BRAM-Based)
-- NIST FIPS-197 Compliant — Block RAM Implementation
--------------------------------------------------------------------------------
-- Rijndael S-Box: 256-entry × 8-bit ROM, BRAM tabanlı.
-- BRAM okuma: 1 clock cycle latency.
-- LUT kullanımından ~2048 → ~0 LUT tasarrufu (per instance).
--
-- Kullanım:
--   - Rising edge'de addr latch edilir
--   - 1 cycle sonra output geçerli olur
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes_sbox is
    port (
        clk    : in  std_logic;
        addr   : in  std_logic_vector(7 downto 0);
        dout   : out std_logic_vector(7 downto 0)
    );
end aes_sbox;

architecture BRAM of aes_sbox is

    type sbox_rom_t is array (0 to 255) of std_logic_vector(7 downto 0);

    -- NIST FIPS-197 §5.1.1 — Rijndael S-Box
    constant SBOX_ROM : sbox_rom_t := (
        -- 0x00-0x0F
        x"63", x"7C", x"77", x"7B", x"F2", x"6B", x"6F", x"C5",
        x"30", x"01", x"67", x"2B", x"FE", x"D7", x"AB", x"76",
        -- 0x10-0x1F
        x"CA", x"82", x"C9", x"7D", x"FA", x"59", x"47", x"F0",
        x"AD", x"D4", x"A2", x"AF", x"9C", x"A4", x"72", x"C0",
        -- 0x20-0x2F
        x"B7", x"FD", x"93", x"26", x"36", x"3F", x"F7", x"CC",
        x"34", x"A5", x"E5", x"F1", x"71", x"D8", x"31", x"15",
        -- 0x30-0x3F
        x"04", x"C7", x"23", x"C3", x"18", x"96", x"05", x"9A",
        x"07", x"12", x"80", x"E2", x"EB", x"27", x"B2", x"75",
        -- 0x40-0x4F
        x"09", x"83", x"2C", x"1A", x"1B", x"6E", x"5A", x"A0",
        x"52", x"3B", x"D6", x"B3", x"29", x"E3", x"2F", x"84",
        -- 0x50-0x5F
        x"53", x"D1", x"00", x"ED", x"20", x"FC", x"B1", x"5B",
        x"6A", x"CB", x"BE", x"39", x"4A", x"4C", x"58", x"CF",
        -- 0x60-0x6F
        x"D0", x"EF", x"AA", x"FB", x"43", x"4D", x"33", x"85",
        x"45", x"F9", x"02", x"7F", x"50", x"3C", x"9F", x"A8",
        -- 0x70-0x7F
        x"51", x"A3", x"40", x"8F", x"92", x"9D", x"38", x"F5",
        x"BC", x"B6", x"DA", x"21", x"10", x"FF", x"F3", x"D2",
        -- 0x80-0x8F
        x"CD", x"0C", x"13", x"EC", x"5F", x"97", x"44", x"17",
        x"C4", x"A7", x"7E", x"3D", x"64", x"5D", x"19", x"73",
        -- 0x90-0x9F
        x"60", x"81", x"4F", x"DC", x"22", x"2A", x"90", x"88",
        x"46", x"EE", x"B8", x"14", x"DE", x"5E", x"0B", x"DB",
        -- 0xA0-0xAF
        x"E0", x"32", x"3A", x"0A", x"49", x"06", x"24", x"5C",
        x"C2", x"D3", x"AC", x"62", x"91", x"95", x"E4", x"79",
        -- 0xB0-0xBF
        x"E7", x"C8", x"37", x"6D", x"8D", x"D5", x"4E", x"A9",
        x"6C", x"56", x"F4", x"EA", x"65", x"7A", x"AE", x"08",
        -- 0xC0-0xCF
        x"BA", x"78", x"25", x"2E", x"1C", x"A6", x"B4", x"C6",
        x"E8", x"DD", x"74", x"1F", x"4B", x"BD", x"8B", x"8A",
        -- 0xD0-0xDF
        x"70", x"3E", x"B5", x"66", x"48", x"03", x"F6", x"0E",
        x"61", x"35", x"57", x"B9", x"86", x"C1", x"1D", x"9E",
        -- 0xE0-0xEF
        x"E1", x"F8", x"98", x"11", x"69", x"D9", x"8E", x"94",
        x"9B", x"1E", x"87", x"E9", x"CE", x"55", x"28", x"DF",
        -- 0xF0-0xFF
        x"8C", x"A1", x"89", x"0D", x"BF", x"E6", x"42", x"68",
        x"41", x"99", x"2D", x"0F", x"B0", x"54", x"BB", x"16"
    );

    -- Internal signal: BRAM output register (dont_touch hedefi)
    signal dout_reg : std_logic_vector(7 downto 0) := (others => '0');

    -- Force BRAM inference
    attribute rom_style : string;
    attribute rom_style of SBOX_ROM : constant is "block";

    -- Sentez koruması: iç sinyal üzerinde (port değil)
    attribute dont_touch : string;
    attribute dont_touch of dout_reg : signal is "true";

begin

    process(clk)
    begin
        if rising_edge(clk) then
            -- Metavalue guard: addr 'U'/'X' iken to_integer çağrısını engelle
            -- Sentezde is_x hiçbir zaman true olmaz → donanım değişmez
            if is_x(addr) then
                dout_reg <= (others => '0');
            else
                dout_reg <= SBOX_ROM(to_integer(unsigned(addr)));
            end if;
        end if;
    end process;

    -- Port assignment (dont_touch dout_reg'i koruyor, Vivado optimize edemez)
    dout <= dout_reg;

end BRAM;
