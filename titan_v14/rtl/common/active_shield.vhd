--------------------------------------------------------------------------------
-- ★ P6 #54: Active Shielding Mesh
--
-- FPGA I/O routing ile aktif mesh sinyal kontrol.
-- Mesh kopması = tamper detect → kill_protocol tetikle.
-- LFSR pattern checker: sürekli desen doğrulama.
--
-- Çalışma:
--   1. LFSR pattern_out → FPGA pad → harici mesh → FPGA pad → pattern_in
--   2. Her döngüde pattern_in == beklenen çıkış kontrol
--   3. Mismatch = mesh kopması (fiziksel müdahale)
--   4. N ardışık hata → kill sinyali
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity active_shield is
  generic (
    -- Number of mesh lines to monitor
    MESH_WIDTH     : integer := 4;
    -- Consecutive failures before kill
    FAIL_THRESHOLD : integer := 3
  );
  port (
    clk           : in  std_logic;
    rst_n         : in  std_logic;
    enable        : in  std_logic;

    -- Mesh I/O: pattern sent out, received back through physical mesh
    mesh_out      : out std_logic_vector(MESH_WIDTH-1 downto 0);
    mesh_in       : in  std_logic_vector(MESH_WIDTH-1 downto 0);

    -- Status
    mesh_ok       : out std_logic;  -- '1' = all mesh lines intact
    tamper_detect : out std_logic;  -- '1' = mesh breach confirmed
    kill_trigger  : out std_logic   -- '1' = kill protocol should fire
  );
end entity active_shield;

architecture rtl of active_shield is

  -- LFSR for pattern generation
  signal lfsr        : std_logic_vector(15 downto 0) := x"CAFE";
  signal expected    : std_logic_vector(MESH_WIDTH-1 downto 0);
  signal pattern_reg : std_logic_vector(MESH_WIDTH-1 downto 0);

  -- Failure tracking
  signal fail_count  : integer range 0 to FAIL_THRESHOLD := 0;
  signal mesh_good   : std_logic := '1';
  signal tamper_flag : std_logic := '0';
  signal kill_flag   : std_logic := '0';

  -- Pipeline delay (mesh propagation: 1-2 clocks)
  signal expected_d1 : std_logic_vector(MESH_WIDTH-1 downto 0);

begin

  -- LFSR pattern generator
  p_lfsr : process(clk, rst_n)
    variable fb : std_logic;
  begin
    if rst_n = '0' then
      lfsr <= x"CAFE";
    elsif rising_edge(clk) then
      if enable = '1' then
        fb := lfsr(0) xor lfsr(2) xor lfsr(3) xor lfsr(5);
        lfsr <= fb & lfsr(15 downto 1);
      end if;
    end if;
  end process p_lfsr;

  -- Drive mesh outputs with LFSR bits
  pattern_reg <= lfsr(MESH_WIDTH-1 downto 0);
  mesh_out    <= pattern_reg;

  -- Pipeline expected pattern (1-clock mesh delay)
  p_delay : process(clk, rst_n)
  begin
    if rst_n = '0' then
      expected_d1 <= (others => '0');
    elsif rising_edge(clk) then
      expected_d1 <= pattern_reg;
    end if;
  end process p_delay;

  -- Compare mesh_in with expected (delayed)
  p_check : process(clk, rst_n)
  begin
    if rst_n = '0' then
      fail_count  <= 0;
      mesh_good   <= '1';
      tamper_flag <= '0';
      kill_flag   <= '0';
    elsif rising_edge(clk) then
      if enable = '1' then
        if mesh_in = expected_d1 then
          -- Mesh intact
          mesh_good  <= '1';
          fail_count <= 0;
        else
          -- Mismatch: possible tampering
          mesh_good <= '0';

          if fail_count < FAIL_THRESHOLD then
            fail_count <= fail_count + 1;
          end if;

          if fail_count >= FAIL_THRESHOLD - 1 then
            tamper_flag <= '1';
            kill_flag   <= '1';  -- PERMANENT until reset
          end if;
        end if;
      end if;
    end if;
  end process p_check;

  mesh_ok       <= mesh_good;
  tamper_detect <= tamper_flag;
  kill_trigger  <= kill_flag;

end architecture rtl;
