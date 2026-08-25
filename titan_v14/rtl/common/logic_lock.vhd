--------------------------------------------------------------------------------
-- ★ P5 #56: Logic Locking — FPGA Reverse Engineering Koruması
--
-- XOR tabanlı logic locking: Doğru anahtar girilene kadar
-- çıkışlar gated/kilitli kalır.
--
-- Akış:
--   1. MCU boot → SPI üzerinden 64-bit unlock key gönderir
--   2. Key doğrulanırsa output_enable açılır
--   3. Yanlış key → çıkışlar 0, alarm flag set
--
-- Saldırı vektörü: Bitstream reverse engineering + IP theft
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity logic_lock is
  generic (
    -- 64-bit lock key (set during synthesis, unique per device)
    LOCK_KEY : std_logic_vector(63 downto 0) := x"A5B4C3D2E1F00F1E"
  );
  port (
    clk           : in  std_logic;
    rst_n         : in  std_logic;

    -- Key input (from MCU via SPI, bit-serial)
    key_data      : in  std_logic;
    key_valid     : in  std_logic;  -- Pulse: one bit per clock
    key_done      : in  std_logic;  -- Pulse: all 64 bits received

    -- Lock status
    unlocked      : out std_logic;  -- '1' when key matches
    lock_error    : out std_logic;  -- '1' if wrong key attempted

    -- Gate control for protected logic
    data_in       : in  std_logic_vector(31 downto 0);
    data_out      : out std_logic_vector(31 downto 0)
  );
end entity logic_lock;

architecture rtl of logic_lock is

  -- Key shift register
  signal key_shift   : std_logic_vector(63 downto 0) := (others => '0');
  signal bit_count   : unsigned(6 downto 0) := (others => '0');

  -- Lock state
  signal is_unlocked : std_logic := '0';
  signal error_flag  : std_logic := '0';

  -- Maximum unlock attempts before permanent lock
  constant MAX_ATTEMPTS : integer := 3;
  signal attempt_count  : integer range 0 to MAX_ATTEMPTS := 0;

begin

  -- Key shift register: accumulate bits from SPI
  p_key_shift : process(clk, rst_n)
  begin
    if rst_n = '0' then
      key_shift   <= (others => '0');
      bit_count   <= (others => '0');
      is_unlocked <= '0';
      error_flag  <= '0';
      attempt_count <= 0;
    elsif rising_edge(clk) then
      if key_valid = '1' and is_unlocked = '0' then
        -- Shift in one bit (MSB first)
        key_shift <= key_shift(62 downto 0) & key_data;
        bit_count <= bit_count + 1;
      end if;

      -- Check key when all 64 bits received
      if key_done = '1' and is_unlocked = '0' then
        if attempt_count < MAX_ATTEMPTS then
          if key_shift = LOCK_KEY then
            is_unlocked <= '1';
            error_flag  <= '0';
          else
            error_flag    <= '1';
            attempt_count <= attempt_count + 1;
          end if;
        else
          -- Permanent lock: too many attempts
          error_flag <= '1';
        end if;

        -- Reset shift register for next attempt
        key_shift <= (others => '0');
        bit_count <= (others => '0');
      end if;
    end if;
  end process p_key_shift;

  -- Output gating: data passes only when unlocked
  data_out <= data_in when is_unlocked = '1' else (others => '0');

  -- Status outputs
  unlocked   <= is_unlocked;
  lock_error <= error_flag;

end architecture rtl;
