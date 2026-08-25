--------------------------------------------------------------------------------
-- PROJECT TITAN V14.2: 2nd-Order Masked S-Box — Exhaustive Testbench
-- Verifies DOM (Domain-Oriented Masking) correctness for ALL 256 entries
-- across 5 independent mask pairs
--------------------------------------------------------------------------------
-- TEST METHODOLOGY:
--   For each mask pair (m_a, m_b):
--     1. Trigger recomputation (wait 518+margin cycles)
--     2. For each x in 0..255:
--        Feed din = x XOR m_a XOR m_b
--        dout XOR mask_out_a XOR mask_out_b must equal S[x]
--   Total: 5 * 256 = 1280 lookup checks
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_sbox_2nd_order is
end tb_sbox_2nd_order;

architecture sim of tb_sbox_2nd_order is

    signal clk          : std_logic := '0';
    signal mask_a       : std_logic_vector(7 downto 0) := (others => '0');
    signal mask_b       : std_logic_vector(7 downto 0) := (others => '0');
    signal recomp_start : std_logic := '0';
    signal recomp_done  : std_logic;
    signal din          : std_logic_vector(7 downto 0) := (others => '0');
    signal dout         : std_logic_vector(7 downto 0);
    signal mask_out_a   : std_logic_vector(7 downto 0);
    signal mask_out_b   : std_logic_vector(7 downto 0);

    constant CLK_PERIOD : time := 20 ns;
    signal test_done    : boolean := false;
    signal pass_count   : integer := 0;
    signal fail_count   : integer := 0;

    -- Reference AES S-Box (NIST FIPS 197 Table 4)
    type sbox_t is array (0 to 255) of std_logic_vector(7 downto 0);
    constant SBOX_REF : sbox_t := (
        x"63",x"7c",x"77",x"7b",x"f2",x"6b",x"6f",x"c5",x"30",x"01",x"67",x"2b",x"fe",x"d7",x"ab",x"76",
        x"ca",x"82",x"c9",x"7d",x"fa",x"59",x"47",x"f0",x"ad",x"d4",x"a2",x"af",x"9c",x"a4",x"72",x"c0",
        x"b7",x"fd",x"93",x"26",x"36",x"3f",x"f7",x"cc",x"34",x"a5",x"e5",x"f1",x"71",x"d8",x"31",x"15",
        x"04",x"c7",x"23",x"c3",x"18",x"96",x"05",x"9a",x"07",x"12",x"80",x"e2",x"eb",x"27",x"b2",x"75",
        x"09",x"83",x"2c",x"1a",x"1b",x"6e",x"5a",x"a0",x"52",x"3b",x"d6",x"b3",x"29",x"e3",x"2f",x"84",
        x"53",x"d1",x"00",x"ed",x"20",x"fc",x"b1",x"5b",x"6a",x"cb",x"be",x"39",x"4a",x"4c",x"58",x"cf",
        x"d0",x"ef",x"aa",x"fb",x"43",x"4d",x"33",x"85",x"45",x"f9",x"02",x"7f",x"50",x"3c",x"9f",x"a8",
        x"51",x"a3",x"40",x"8f",x"92",x"9d",x"38",x"f5",x"bc",x"b6",x"da",x"21",x"10",x"ff",x"f3",x"d2",
        x"cd",x"0c",x"13",x"ec",x"5f",x"97",x"44",x"17",x"c4",x"a7",x"7e",x"3d",x"64",x"5d",x"19",x"73",
        x"60",x"81",x"4f",x"dc",x"22",x"2a",x"90",x"88",x"46",x"ee",x"b8",x"14",x"de",x"5e",x"0b",x"db",
        x"e0",x"32",x"3a",x"0a",x"49",x"06",x"24",x"5c",x"c2",x"d3",x"ac",x"62",x"91",x"95",x"e4",x"79",
        x"e7",x"c8",x"37",x"6d",x"8d",x"d5",x"4e",x"a9",x"6c",x"56",x"f4",x"ea",x"65",x"7a",x"ae",x"08",
        x"ba",x"78",x"25",x"2e",x"1c",x"a6",x"b4",x"c6",x"e8",x"dd",x"74",x"1f",x"4b",x"bd",x"8b",x"8a",
        x"70",x"3e",x"b5",x"66",x"48",x"03",x"f6",x"0e",x"61",x"35",x"57",x"b9",x"86",x"c1",x"1d",x"9e",
        x"e1",x"f8",x"98",x"11",x"69",x"d9",x"8e",x"94",x"9b",x"1e",x"87",x"e9",x"ce",x"55",x"28",x"df",
        x"8c",x"a1",x"89",x"0d",x"bf",x"e6",x"42",x"68",x"41",x"99",x"2d",x"0f",x"b0",x"54",x"bb",x"16"
    );

    -- 5 test mask pairs (diverse bit patterns)
    type mask_pair_t is record
        ma : std_logic_vector(7 downto 0);
        mb : std_logic_vector(7 downto 0);
    end record;
    type mask_pairs_t is array (0 to 4) of mask_pair_t;
    constant MASK_PAIRS : mask_pairs_t := (
        (ma => x"3C", mb => x"A5"),   -- Mixed patterns
        (ma => x"FF", mb => x"00"),   -- Extreme: all-ones / all-zeros
        (ma => x"55", mb => x"AA"),   -- Alternating bits
        (ma => x"01", mb => x"FE"),   -- Near-boundary
        (ma => x"42", mb => x"BD")    -- Random-ish
    );

begin

    -- Clock generator
    clk <= not clk after CLK_PERIOD / 2 when not test_done else '0';

    -- DUT instantiation
    DUT: entity work.aes_sbox_masked_2nd
        port map (
            clk          => clk,
            mask_a       => mask_a,
            mask_b       => mask_b,
            recomp_start => recomp_start,
            recomp_done  => recomp_done,
            din          => din,
            dout         => dout,
            mask_out_a   => mask_out_a,
            mask_out_b   => mask_out_b
        );

    -- Main test process
    process
        variable expected : std_logic_vector(7 downto 0);
        variable unmasked : std_logic_vector(7 downto 0);
        variable masked_in: std_logic_vector(7 downto 0);
    begin
        report "========================================";
        report "TB_SBOX_2ND_ORDER: 2nd-Order DOM Masked S-Box Exhaustive Test";
        report "========================================";

        wait for CLK_PERIOD * 2;

        for mp in 0 to 4 loop
            report "--- Mask Pair " & integer'image(mp) &
                   ": m_a=0x" & to_hstring(MASK_PAIRS(mp).ma) &
                   ", m_b=0x" & to_hstring(MASK_PAIRS(mp).mb) & " ---";

            -- Set masks and trigger recomputation
            mask_a <= MASK_PAIRS(mp).ma;
            mask_b <= MASK_PAIRS(mp).mb;
            wait for CLK_PERIOD;

            recomp_start <= '1';
            wait for CLK_PERIOD;
            recomp_start <= '0';

            -- Wait for recomputation to complete (518 + margin)
            for i in 0 to 599 loop
                wait for CLK_PERIOD;
                if recomp_done = '1' then
                    exit;
                end if;
            end loop;

            assert recomp_done = '1'
                report "FAIL: Recomputation did not complete for mask pair " & integer'image(mp)
                severity error;

            -- Verify all 256 entries
            for x in 0 to 255 loop
                expected := SBOX_REF(x);

                -- Input: x XOR m_a XOR m_b (pre-masked value)
                masked_in := std_logic_vector(
                    unsigned(to_unsigned(x, 8)) xor
                    unsigned(MASK_PAIRS(mp).ma) xor
                    unsigned(MASK_PAIRS(mp).mb)
                );
                din <= masked_in;

                -- Wait pipeline: 2 cycles for registered output
                wait for CLK_PERIOD;
                wait for CLK_PERIOD;
                wait for CLK_PERIOD;

                -- Unmask: dout XOR mask_out_a XOR mask_out_b should equal S[x]
                unmasked := dout xor mask_out_a xor mask_out_b;

                if unmasked = expected then
                    pass_count <= pass_count + 1;
                else
                    fail_count <= fail_count + 1;
                    report "FAIL: x=" & integer'image(x) &
                           " expected=0x" & to_hstring(expected) &
                           " got=0x" & to_hstring(unmasked) &
                           " (dout=0x" & to_hstring(dout) &
                           " moa=0x" & to_hstring(mask_out_a) &
                           " mob=0x" & to_hstring(mask_out_b) & ")"
                        severity error;
                end if;
            end loop;

            report "Mask pair " & integer'image(mp) & " complete.";
        end loop;

        report "========================================";
        report "RESULTS: PASS=" & integer'image(pass_count) &
               " FAIL=" & integer'image(fail_count) &
               " / 1280 total";

        if fail_count = 0 then
            report "*** TB_SBOX_2ND_ORDER: ALL TESTS PASSED ***";
        else
            report "*** TB_SBOX_2ND_ORDER: " & integer'image(fail_count) & " FAILURES ***"
                severity failure;
        end if;
        report "========================================";

        test_done <= true;
        wait;
    end process;

end sim;
