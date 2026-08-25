--------------------------------------------------------------------------------
-- PROJECT OMEGA: Chaos Node (Minimal Entity for Liquid Reservoir)
-- Module: Single node in a combinatorial chaos network
--------------------------------------------------------------------------------
-- PURPOSE: Each chaos_node receives 3 inputs from other nodes in the
--          reservoir, XORs them together, and optionally injects a
--          plaintext bit. The output feeds back into the network.
--
-- NOTE: This is a COMBINATORIAL module — no clock, no registers.
--       The liquid_reservoir.vhd instantiates 128 of these nodes
--       in a randomly-connected network with feedback loops.
--
-- ⚠️ SIMULATION ONLY: Combinatorial loops are intentional.
--    Vivado: set_property ALLOW_COMBINATORIAL_LOOPS TRUE
--    GHDL:   Handled via delta cycle iteration
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity chaos_node is
    port (
        inputs : in  std_logic_vector(2 downto 0);  -- 3 inputs from neighbors
        inject : in  std_logic;                      -- Plaintext bit injection
        output : out std_logic                       -- Node output
    );
end chaos_node;

architecture rtl of chaos_node is
    -- Synthesis protection
    attribute dont_touch : string;
    attribute dont_touch of output : signal is "true";
begin
    -- Combinatorial: XOR all inputs + injection
    -- Nonlinearity comes from network topology, not gate type
    output <= inputs(0) xor inputs(1) xor inputs(2) xor inject;
end rtl;
