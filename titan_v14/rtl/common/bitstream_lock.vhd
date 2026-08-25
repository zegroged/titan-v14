--------------------------------------------------------------------------------
-- ★ P6 #64: Bitstream Version Lock
--
-- Bitstream rollback koruması.
-- Mevcut versiyon BRAM'de saklanır, eski versiyon boot engellenir.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bitstream_lock is
  generic (
    CURRENT_VERSION : unsigned(31 downto 0) := to_unsigned(15, 32) -- V15
  );
  port (
    clk             : in  std_logic;
    rst_n           : in  std_logic;

    -- Stored version (from BRAM/NVM at boot)
    stored_version  : in  std_logic_vector(31 downto 0);

    -- Status
    version_ok      : out std_logic;  -- '1' = current >= stored
    rollback_alert  : out std_logic;  -- '1' = rollback attempt
    boot_allow      : out std_logic   -- '1' = boot permitted
  );
end entity bitstream_lock;

architecture rtl of bitstream_lock is

  signal checked      : std_logic := '0';
  signal is_valid     : std_logic := '0';
  signal is_rollback  : std_logic := '0';

begin

  p_check : process(clk, rst_n)
    variable stored_u : unsigned(31 downto 0);
  begin
    if rst_n = '0' then
      checked     <= '0';
      is_valid    <= '0';
      is_rollback <= '0';
    elsif rising_edge(clk) then
      if checked = '0' then
        stored_u := unsigned(stored_version);

        if CURRENT_VERSION >= stored_u then
          is_valid    <= '1';
          is_rollback <= '0';
        else
          is_valid    <= '0';
          is_rollback <= '1';
        end if;

        checked <= '1';
      end if;
    end if;
  end process p_check;

  version_ok     <= is_valid;
  rollback_alert <= is_rollback;
  boot_allow     <= is_valid and checked;

end architecture rtl;
