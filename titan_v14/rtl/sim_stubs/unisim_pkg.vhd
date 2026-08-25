--------------------------------------------------------------------------------
-- UNISIM Simulation Stubs for GHDL
-- Provides behavioral models of Xilinx primitives used in TITAN V14
-- These are NOT synthesizable -- simulation only!
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package vcomponents is

    -- ===== BUFG =====
    component BUFG
        port (
            I : in  std_logic;
            O : out std_logic
        );
    end component;

    -- ===== MMCME2_ADV =====
    component MMCME2_ADV
        generic (
            BANDWIDTH          : string  := "OPTIMIZED";
            CLKFBOUT_MULT_F    : real    := 5.0;
            CLKOUT0_DIVIDE_F   : real    := 1.0;
            CLKOUT1_DIVIDE     : integer := 1;
            CLKOUT0_PHASE      : real    := 0.0;
            CLKOUT1_PHASE      : real    := 0.0;
            DIVCLK_DIVIDE      : integer := 1;
            CLKIN1_PERIOD       : real   := 10.0;
            CLKOUT0_USE_FINE_PS : boolean := FALSE;
            STARTUP_WAIT        : boolean := FALSE
        );
        port (
            CLKIN1    : in  std_logic;
            CLKIN2    : in  std_logic;
            CLKINSEL  : in  std_logic;
            CLKFBOUT  : out std_logic;
            CLKFBIN   : in  std_logic;
            CLKOUT0   : out std_logic;
            CLKOUT1   : out std_logic;
            CLKOUT2   : out std_logic;
            CLKOUT3   : out std_logic;
            CLKOUT4   : out std_logic;
            CLKOUT5   : out std_logic;
            CLKOUT6   : out std_logic;
            CLKOUT0B  : out std_logic;
            CLKOUT1B  : out std_logic;
            CLKOUT2B  : out std_logic;
            CLKOUT3B  : out std_logic;
            CLKFBOUTB : out std_logic;
            PSCLK     : in  std_logic;
            PSEN      : in  std_logic;
            PSINCDEC  : in  std_logic;
            PSDONE    : out std_logic;
            LOCKED    : out std_logic;
            RST       : in  std_logic;
            PWRDWN    : in  std_logic;
            DADDR     : in  std_logic_vector(6 downto 0);
            DI        : in  std_logic_vector(15 downto 0);
            DWE       : in  std_logic;
            DEN       : in  std_logic;
            DCLK      : in  std_logic;
            DO        : out std_logic_vector(15 downto 0);
            DRDY      : out std_logic
        );
    end component;

end package vcomponents;
