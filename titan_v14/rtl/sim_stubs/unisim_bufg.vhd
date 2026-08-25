--------------------------------------------------------------------------------
-- BUFG behavioral model for GHDL simulation
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

library unisim;

entity BUFG is
    port (
        I : in  std_logic;
        O : out std_logic
    );
end entity BUFG;

architecture sim of BUFG is
begin
    -- Simple passthrough (no delay in simulation)
    O <= I;
end architecture sim;
