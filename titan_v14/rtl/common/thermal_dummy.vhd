--------------------------------------------------------------------------------
-- ★ P5 #57: Thermal Dummy Loads — DPA/Power Analysis Koruması
--
-- Kripto operasyonlarından bağımsız sabit güç tüketimi.
-- LFSR-driven dummy toggling ile power trace flattening.
--
-- Teknik:
--   1. 32-bit Galois LFSR sürekli çalışır
--   2. LFSR çıkışı 64-bit dummy register'ı toggle eder
--   3. Dummy register çıkışı unused pad'lere bağlanır (veya tied)
--   4. Kripto aktifken de inaktifken de aynı güç tüketimi
--
-- Saldırı vektörü: Güç analizi (DPA/SPA) ile anahtar çıkarma
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity thermal_dummy is
  generic (
    -- LFSR polynomial (x^32 + x^22 + x^2 + x + 1)
    LFSR_POLY : std_logic_vector(31 downto 0) := x"80200003";
    -- Number of dummy toggle registers
    DUMMY_WIDTH : integer := 64
  );
  port (
    clk     : in  std_logic;
    rst_n   : in  std_logic;
    enable  : in  std_logic;  -- '1' to activate thermal load

    -- Dummy output (connect to unused pins or leave floating)
    dummy_out : out std_logic_vector(DUMMY_WIDTH-1 downto 0)
  );
end entity thermal_dummy;

architecture rtl of thermal_dummy is

  -- 32-bit Galois LFSR
  signal lfsr : std_logic_vector(31 downto 0) := x"DEADBEEF";

  -- Dummy toggle registers
  signal dummy_reg : std_logic_vector(DUMMY_WIDTH-1 downto 0) := (others => '0');

  -- Counter for controlled toggle rate
  signal toggle_counter : unsigned(3 downto 0) := (others => '0');

begin

  -- Galois LFSR: maximal-length sequence for pseudo-random toggling
  p_lfsr : process(clk, rst_n)
    variable feedback : std_logic;
  begin
    if rst_n = '0' then
      lfsr <= x"DEADBEEF";  -- Non-zero seed
    elsif rising_edge(clk) then
      if enable = '1' then
        feedback := lfsr(0);
        lfsr <= '0' & lfsr(31 downto 1);
        if feedback = '1' then
          lfsr <= ('0' & lfsr(31 downto 1)) xor LFSR_POLY;
        end if;
      end if;
    end if;
  end process p_lfsr;

  -- Dummy register toggle: XOR selected bits with LFSR output
  p_dummy : process(clk, rst_n)
  begin
    if rst_n = '0' then
      dummy_reg      <= (others => '0');
      toggle_counter <= (others => '0');
    elsif rising_edge(clk) then
      if enable = '1' then
        toggle_counter <= toggle_counter + 1;

        -- Toggle different sections of dummy register per cycle
        -- This creates constant switching activity regardless of crypto state
        case toggle_counter(1 downto 0) is
          when "00" =>
            dummy_reg(15 downto 0) <= dummy_reg(15 downto 0) xor lfsr(15 downto 0);
          when "01" =>
            dummy_reg(31 downto 16) <= dummy_reg(31 downto 16) xor lfsr(31 downto 16);
          when "10" =>
            dummy_reg(47 downto 32) <= dummy_reg(47 downto 32) xor lfsr(15 downto 0);
          when "11" =>
            dummy_reg(63 downto 48) <= dummy_reg(63 downto 48) xor lfsr(31 downto 16);
          when others =>
            null;
        end case;
      end if;
    end if;
  end process p_dummy;

  -- Output (active regardless of crypto operations)
  dummy_out <= dummy_reg;

end architecture rtl;
