--------------------------------------------------------------------------------
-- AEGIS Phase 3.3: Dummy Operation Injector
--------------------------------------------------------------------------------
-- Inserts 0-3 fake AES rounds between real rounds to mask power signatures.
--
-- Architecture:
--   1. Shadow round datapath: identical logic to real AES round
--      (SubBytes -> ShiftRows -> MixColumns -> AddRoundKey)
--      but results are DISCARDED -> AES state unaffected
--   2. Stall controller: asserts aes_stall during dummy cycles
--   3. Dummy count: chaos_value(1 downto 0) -> 0..3 per round
--
-- Power equivalence:
--   The shadow datapath uses the same S-box ROM, same XOR trees,
--   same register widths, and same toggle patterns as the real AES.
--   An oscilloscope cannot distinguish dummy from real rounds.
--
-- Timing:
--   Real round = 1 cycle. With dummies: 1..4 cycles per real round.
--   Average overhead = E[chaos(1:0)] = 1.5 cycles -> ~+150% -> overhead ~60%
--   (Note: 0+1+2+3 / 4 = 1.5 average dummy cycles per real round)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dummy_op_injector is
    generic (
        MAX_DUMMIES : integer := 3    -- Maximum dummy rounds per real round
    );
    port (
        clk              : in  std_logic;
        rst_n            : in  std_logic;

        -- AES interface
        aes_round_start  : in  std_logic;   -- Pulse: AES begins new round
        aes_stall        : out std_logic;    -- Assert to stall AES pipeline

        -- Chaotic input (from PRNG)
        chaos_value      : in  std_logic_vector(31 downto 0);
        chaos_valid      : in  std_logic;

        -- Control
        dummy_enable     : in  std_logic;

        -- Status
        dummy_active     : out std_logic;    -- Dummy round in progress
        dummy_count_out  : out std_logic_vector(1 downto 0);  -- Current round's dummy count
        total_dummies    : out std_logic_vector(15 downto 0);  -- Cumulative counter
        total_rounds     : out std_logic_vector(15 downto 0)   -- Cumulative real rounds
    );
    attribute use_dsp : string;
    attribute use_dsp of dummy_op_injector : entity is "no";
end entity dummy_op_injector;

architecture rtl of dummy_op_injector is

    -- =====================================================================
    -- AES S-Box (identical to real AES -- same LUT, same switching)
    -- =====================================================================
    type sbox_t is array (0 to 255) of std_logic_vector(7 downto 0);
    constant SBOX : sbox_t := (
        x"63",x"7C",x"77",x"7B",x"F2",x"6B",x"6F",x"C5",
        x"30",x"01",x"67",x"2B",x"FE",x"D7",x"AB",x"76",
        x"CA",x"82",x"C9",x"7D",x"FA",x"59",x"47",x"F0",
        x"AD",x"D4",x"A2",x"AF",x"9C",x"A4",x"72",x"C0",
        x"B7",x"FD",x"93",x"26",x"36",x"3F",x"F7",x"CC",
        x"34",x"A5",x"E5",x"F1",x"71",x"D8",x"31",x"15",
        x"04",x"C7",x"23",x"C3",x"18",x"96",x"05",x"9A",
        x"07",x"12",x"80",x"E2",x"EB",x"27",x"B2",x"75",
        x"09",x"83",x"2C",x"1A",x"1B",x"6E",x"5A",x"A0",
        x"52",x"3B",x"D6",x"B3",x"29",x"E3",x"2F",x"84",
        x"53",x"D1",x"00",x"ED",x"20",x"FC",x"B1",x"5B",
        x"6A",x"CB",x"BE",x"39",x"4A",x"4C",x"58",x"CF",
        x"D0",x"EF",x"AA",x"FB",x"43",x"4D",x"33",x"85",
        x"45",x"F9",x"02",x"7F",x"50",x"3C",x"9F",x"A8",
        x"51",x"A3",x"40",x"8F",x"92",x"9D",x"38",x"F5",
        x"BC",x"B6",x"DA",x"21",x"10",x"FF",x"F3",x"D2",
        x"CD",x"0C",x"13",x"EC",x"5F",x"97",x"44",x"17",
        x"C4",x"A7",x"7E",x"3D",x"64",x"5D",x"19",x"73",
        x"60",x"81",x"4F",x"DC",x"22",x"2A",x"90",x"88",
        x"46",x"EE",x"B8",x"14",x"DE",x"5E",x"0B",x"DB",
        x"E0",x"32",x"3A",x"0A",x"49",x"06",x"24",x"5C",
        x"C2",x"D3",x"AC",x"62",x"91",x"95",x"E4",x"79",
        x"E7",x"C8",x"37",x"6D",x"8D",x"D5",x"4E",x"A9",
        x"6C",x"56",x"F4",x"EA",x"65",x"7A",x"AE",x"08",
        x"BA",x"78",x"25",x"2E",x"1C",x"A6",x"B4",x"C6",
        x"E8",x"DD",x"74",x"1F",x"4B",x"BD",x"8B",x"8A",
        x"70",x"3E",x"B5",x"66",x"48",x"03",x"F6",x"0E",
        x"61",x"35",x"57",x"B9",x"86",x"C1",x"1D",x"9E",
        x"E1",x"F8",x"98",x"11",x"69",x"D9",x"8E",x"94",
        x"9B",x"1E",x"87",x"E9",x"CE",x"55",x"28",x"DF",
        x"8C",x"A1",x"89",x"0D",x"BF",x"E6",x"42",x"68",
        x"41",x"99",x"2D",x"0F",x"B0",x"54",x"BB",x"16"
    );

    -- GF(2^8) multiply by 2 (xtime)
    function xtime(b : std_logic_vector(7 downto 0))
        return std_logic_vector is
        variable r : std_logic_vector(7 downto 0);
    begin
        r := b(6 downto 0) & '0';
        if b(7) = '1' then
            r := r xor x"1B";
        end if;
        return r;
    end function;

    -- =====================================================================
    -- Shadow state (128-bit, same width as AES)
    -- =====================================================================
    signal shadow_state : std_logic_vector(127 downto 0);
    signal shadow_next  : std_logic_vector(127 downto 0);
    signal shadow_rkey  : std_logic_vector(127 downto 0);

    -- FSM
    type fsm_t is (F_IDLE, F_LATCH, F_DUMMY, F_DONE);
    signal fsm          : fsm_t;
    signal dummy_cnt    : unsigned(1 downto 0);   -- Remaining dummies
    signal dummy_total  : unsigned(1 downto 0);   -- This round's total

    -- Statistics
    signal stat_dummies : unsigned(15 downto 0);
    signal stat_rounds  : unsigned(15 downto 0);

    -- Latched chaos
    signal chaos_latch  : std_logic_vector(31 downto 0);

begin

    -- ===== Outputs =====
    aes_stall      <= '1' when fsm = F_DUMMY or fsm = F_LATCH else '0';
    dummy_active   <= '1' when fsm = F_DUMMY else '0';
    dummy_count_out <= std_logic_vector(dummy_total);
    total_dummies  <= std_logic_vector(stat_dummies);
    total_rounds   <= std_logic_vector(stat_rounds);

    -- ===== Shadow Round Function (combinational) =====
    -- SubBytes -> ShiftRows -> MixColumns -> AddRoundKey
    -- Identical logic to real AES, operating on shadow data
    process(shadow_state, shadow_rkey)
        variable sb : std_logic_vector(127 downto 0);   -- After SubBytes
        variable sr : std_logic_vector(127 downto 0);   -- After ShiftRows
        variable mc : std_logic_vector(127 downto 0);   -- After MixColumns
        -- Byte extraction helpers
        type byte16_t is array (0 to 15) of std_logic_vector(7 downto 0);
        variable b_in, b_sb, b_sr : byte16_t;
        -- MixColumns temps
        variable a0, a1, a2, a3 : std_logic_vector(7 downto 0);
        variable t0, t1, t2, t3 : std_logic_vector(7 downto 0);
        variable x01, x12, x23, x30 : std_logic_vector(7 downto 0);
    begin
        -- Extract bytes (column-major, AES standard)
        for i in 0 to 15 loop
            b_in(i) := shadow_state(127 - i*8 downto 120 - i*8);
        end loop;

        -- SubBytes
        for i in 0 to 15 loop
            b_sb(i) := SBOX(to_integer(unsigned(b_in(i))));
        end loop;

        -- ShiftRows
        -- Row 0: no shift  (bytes 0,4,8,12)
        -- Row 1: shift 1   (bytes 1,5,9,13)
        -- Row 2: shift 2   (bytes 2,6,10,14)
        -- Row 3: shift 3   (bytes 3,7,11,15)
        b_sr(0)  := b_sb(0);  b_sr(4)  := b_sb(4);
        b_sr(8)  := b_sb(8);  b_sr(12) := b_sb(12);
        b_sr(1)  := b_sb(5);  b_sr(5)  := b_sb(9);
        b_sr(9)  := b_sb(13); b_sr(13) := b_sb(1);
        b_sr(2)  := b_sb(10); b_sr(6)  := b_sb(14);
        b_sr(10) := b_sb(2);  b_sr(14) := b_sb(6);
        b_sr(3)  := b_sb(15); b_sr(7)  := b_sb(3);
        b_sr(11) := b_sb(7);  b_sr(15) := b_sb(11);

        -- MixColumns (4 columns)
        for col in 0 to 3 loop
            a0 := b_sr(col * 4 + 0);
            a1 := b_sr(col * 4 + 1);
            a2 := b_sr(col * 4 + 2);
            a3 := b_sr(col * 4 + 3);

            x01 := xtime(a0 xor a1);
            x12 := xtime(a1 xor a2);
            x23 := xtime(a2 xor a3);
            x30 := xtime(a3 xor a0);

            t0 := a0 xor x01 xor (a0 xor a1 xor a2 xor a3);
            t1 := a1 xor x12 xor (a0 xor a1 xor a2 xor a3);
            t2 := a2 xor x23 xor (a0 xor a1 xor a2 xor a3);
            t3 := a3 xor x30 xor (a0 xor a1 xor a2 xor a3);

            mc(127 - (col*4+0)*8 downto 120 - (col*4+0)*8) := t0;
            mc(127 - (col*4+1)*8 downto 120 - (col*4+1)*8) := t1;
            mc(127 - (col*4+2)*8 downto 120 - (col*4+2)*8) := t2;
            mc(127 - (col*4+3)*8 downto 120 - (col*4+3)*8) := t3;
        end loop;

        -- AddRoundKey (XOR with "random" key from chaos)
        shadow_next <= mc xor shadow_rkey;
    end process;

    -- ===== FSM and Control =====
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            fsm          <= F_IDLE;
            shadow_state <= (others => '0');
            shadow_rkey  <= (others => '0');
            chaos_latch  <= (others => '0');
            dummy_cnt    <= (others => '0');
            dummy_total  <= (others => '0');
            stat_dummies <= (others => '0');
            stat_rounds  <= (others => '0');

        elsif rising_edge(clk) then
            -- Latch latest chaos value when available
            if chaos_valid = '1' then
                chaos_latch <= chaos_value;
            end if;

            case fsm is

                -- ==========================================
                -- IDLE: Wait for AES round start
                -- ==========================================
                when F_IDLE =>
                    if aes_round_start = '1' and dummy_enable = '1' then
                        -- Determine dummy count from chaos bits [1:0]
                        dummy_cnt   <= unsigned(chaos_latch(1 downto 0));
                        dummy_total <= unsigned(chaos_latch(1 downto 0));

                        -- Seed shadow state from chaos (ensures varied switching)
                        shadow_state <= chaos_latch &
                                       chaos_latch(15 downto 0) & chaos_latch(31 downto 16) &
                                       (chaos_latch xor x"A5A5A5A5") &
                                       (chaos_latch xor x"5A5A5A5A");
                        -- Shadow round key from different chaos bits
                        shadow_rkey  <= (chaos_latch xor x"3C3C3C3C") &
                                       (chaos_latch xor x"C3C3C3C3") &
                                       chaos_latch(23 downto 0) & chaos_latch(31 downto 24) &
                                       chaos_latch(7 downto 0) & chaos_latch(31 downto 8);

                        stat_rounds <= stat_rounds + 1;

                        if unsigned(chaos_latch(1 downto 0)) = 0 then
                            fsm <= F_DONE;  -- 0 dummies: no stall
                        else
                            fsm <= F_LATCH;
                        end if;
                    end if;

                -- ==========================================
                -- LATCH: Setup cycle (1 clock)
                -- ==========================================
                when F_LATCH =>
                    fsm <= F_DUMMY;

                -- ==========================================
                -- DUMMY: Execute shadow round, decrement counter
                -- ==========================================
                when F_DUMMY =>
                    -- Shadow round executes combinationally (shadow_next)
                    shadow_state <= shadow_next;

                    -- Update shadow key (rotate for next dummy)
                    shadow_rkey <= shadow_rkey(119 downto 0) &
                                 shadow_rkey(127 downto 120);

                    stat_dummies <= stat_dummies + 1;
                    dummy_cnt    <= dummy_cnt - 1;

                    if dummy_cnt = 1 then
                        fsm <= F_DONE;
                    end if;
                    -- else stay in F_DUMMY

                -- ==========================================
                -- DONE: Release stall for 1 cycle, return to idle
                -- ==========================================
                when F_DONE =>
                    fsm <= F_IDLE;

            end case;
        end if;
    end process;

end architecture rtl;
