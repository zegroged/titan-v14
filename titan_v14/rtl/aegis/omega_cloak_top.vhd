--------------------------------------------------------------------------------
-- AEGIS Phase 3.4: Omega Cloak Top Module -- DPA Protection Integration
--------------------------------------------------------------------------------
-- Wraps all three DPA countermeasures around the AES core:
--
--   ┌───────────── omega_cloak_top ──────────────────────────┐
--   │                                                         │
--   │  ┌──────────┐  chaos_byte   ┌─────────────┐           │
--   │  │ Chaotic  │──────────────►│ Clock Jitter │-> jitt_clk │
--   │  │ Dual PRNG│               │  Injector    │           │
--   │  └────┬─────┘               └─────────────┘           │
--   │       │ chaos_value                                     │
--   │       ▼                                                 │
--   │  ┌──────────┐  aes_stall   ┌──────────────┐           │
--   │  │ Dummy Op │◄────────────►│  AES Core    │           │
--   │  │ Injector │  round_start │  (external)  │           │
--   │  └──────────┘              └──────────────┘           │
--   │                                                         │
--   │  omega_enable -> master switch for all protections       │
--   └─────────────────────────────────────────────────────────┘
--
-- The AES core itself is NOT instantiated here (it's platform-specific).
-- Instead, this module provides control signals that wrap the existing
-- aes_core entity in the TITAN V13 design.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity omega_cloak_top is
    generic (
        MAX_DUMMIES     : integer := 3;
        WINDOW_SIZE     : integer := 4;
        MAX_PHASE_STEPS : integer := 108;
        SIM_MODE        : boolean := false
    );
    port (
        -- System
        sys_clk         : in  std_logic;
        rst_n           : in  std_logic;

        -- Master control
        omega_enable    : in  std_logic;   -- Arm all protections
        enable_jitter   : in  std_logic;   -- Individual jitter on/off
        enable_dummy    : in  std_logic;   -- Individual dummy on/off

        -- TRNG seed input (from TITAN Ring Oscillator TRNG)
        trng_seed       : in  std_logic_vector(31 downto 0);
        trng_seed_valid : in  std_logic;

        -- AES interface (directly connected to existing aes_core)
        aes_round_start : in  std_logic;   -- From AES: new round beginning
        aes_stall       : out std_logic;   -- To AES: stall pipeline

        -- Clock outputs (directly to clock tree)
        jittered_clk    : out std_logic;   -- Phase-shifted (to AES)
        sys_clk_buf     : out std_logic;   -- Clean (to rest of system)
        mmcm_locked     : out std_logic;

        -- Status and diagnostics
        chaos_out       : out std_logic_vector(31 downto 0);
        chaos_valid_out : out std_logic;
        dummy_active    : out std_logic;
        dummy_count     : out std_logic_vector(1 downto 0);
        stat_dummies    : out std_logic_vector(15 downto 0);
        stat_rounds     : out std_logic_vector(15 downto 0);

        -- PRNG control (runtime)
        prng_load_seed  : in  std_logic;
        prng_enable     : in  std_logic
    );
end entity omega_cloak_top;

architecture rtl of omega_cloak_top is

    -- Internal signals
    signal chaos_value_int  : std_logic_vector(31 downto 0);
    signal chaos_valid_int  : std_logic;
    signal chaos_byte_int   : std_logic_vector(7 downto 0);
    signal chaos_bit_int    : std_logic;

    -- Gated enables
    signal jitter_en_gated  : std_logic;
    signal dummy_en_gated   : std_logic;
    signal prng_en_gated    : std_logic;

    -- Default r parameter for Logistic Map
    constant R_DEFAULT      : std_logic_vector(31 downto 0) := x"03FD70A4";

begin

    -- ===== Gated enables =====
    jitter_en_gated <= omega_enable and enable_jitter;
    dummy_en_gated  <= omega_enable and enable_dummy;
    prng_en_gated   <= omega_enable and prng_enable;

    -- ===== Status outputs =====
    chaos_out       <= chaos_value_int;
    chaos_valid_out <= chaos_valid_int;

    -- ===== (1) Chaotic PRNG -- Dual Logistic Map Q8.24 =====
    u_prng : entity work.chaotic_prng
        port map (
            clk         => sys_clk,
            rst_n       => rst_n,
            seed        => trng_seed,
            r_param     => R_DEFAULT,
            load_seed   => prng_load_seed,
            enable      => prng_en_gated,
            chaos_out   => chaos_value_int,
            chaos_valid => chaos_valid_int,
            chaos_bit   => chaos_bit_int,
            chaos_byte  => chaos_byte_int,
            -- ★ B-1 FIX: 128-bit output (not used in omega_cloak)
            chaos_out_128   => open,
            chaos_128_valid => open,
            -- ★ UPGRADE: Cycle detection flag
            cycle_locked    => open
        );

    -- ===== (2) Clock Jitter Injector -- MMCM Phase Shift =====
    u_jitter : entity work.clock_jitter_injector
        generic map (
            MAX_PHASE_STEPS => MAX_PHASE_STEPS,
            SIM_MODE        => SIM_MODE
        )
        port map (
            sys_clk       => sys_clk,
            rst           => not rst_n,  -- Active-high reset for MMCM
            chaos_byte    => chaos_byte_int,
            chaos_valid   => chaos_valid_int,
            jitter_enable => jitter_en_gated,
            jittered_clk  => jittered_clk,
            sys_clk_buf   => sys_clk_buf,
            mmcm_locked   => mmcm_locked
        );

    -- ===== (3) Dummy Operation Injector -- Shadow AES Round =====
    u_dummy : entity work.dummy_op_injector
        generic map (MAX_DUMMIES => MAX_DUMMIES)
        port map (
            clk              => sys_clk,
            rst_n            => rst_n,
            aes_round_start  => aes_round_start,
            aes_stall        => aes_stall,
            chaos_value      => chaos_value_int,
            chaos_valid      => chaos_valid_int,
            dummy_enable     => dummy_en_gated,
            dummy_active     => dummy_active,
            dummy_count_out  => dummy_count,
            total_dummies    => stat_dummies,
            total_rounds     => stat_rounds
        );

end architecture rtl;
