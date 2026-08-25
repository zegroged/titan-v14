--------------------------------------------------------------------------------
-- ★ P6 #63: JTAG Internal eFUSE Blow
--
-- JTAG port'u kalıcı devre dışı bırakma.
-- MCU SPI komutu ile tetiklenir, GERİ DÖNÜŞSÜZ.
--
-- Akış:
--   1. MCU → SPI "BLOW_JTAG" komutu
--   2. eFUSE blow sequence (Artix-7: FUSE_USER register)
--   3. JTAG port disable → debug erişimi kalıcı kapalı
--   4. Status register'da blown flag set
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity jtag_fuse_blow is
  port (
    clk         : in  std_logic;
    rst_n       : in  std_logic;

    -- SPI command interface
    blow_cmd    : in  std_logic;  -- Pulse: blow JTAG fuse
    blow_key    : in  std_logic_vector(31 downto 0); -- Auth key

    -- Status
    fuse_blown  : out std_logic;  -- '1' = JTAG permanently disabled
    blow_error  : out std_logic   -- '1' = auth failed
  );
end entity jtag_fuse_blow;

architecture rtl of jtag_fuse_blow is

  constant AUTH_KEY : std_logic_vector(31 downto 0) := x"4A544147"; -- 'JTAG'

  -- Fuse state (simulated in BRAM; real: eFUSE register)
  signal fuse_reg    : std_logic := '0';  -- Persistent after config
  signal error_flag  : std_logic := '0';

begin

  p_fuse : process(clk, rst_n)
  begin
    if rst_n = '0' then
      error_flag <= '0';
      -- fuse_reg intentionally NOT reset (persists)
    elsif rising_edge(clk) then
      if blow_cmd = '1' and fuse_reg = '0' then
        if blow_key = AUTH_KEY then
          fuse_reg   <= '1';  -- PERMANENT
          error_flag <= '0';
        else
          error_flag <= '1';
        end if;
      end if;
    end if;
  end process p_fuse;

  fuse_blown <= fuse_reg;
  blow_error <= error_flag;

end architecture rtl;
