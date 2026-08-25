--------------------------------------------------------------------------------
-- TB: aes_sbox_masked — Table Recomputation + Masked Lookup Verification
-- Tests: recomp FSM, masked table correctness, multiple mask values
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_aes_sbox_masked is
end tb_aes_sbox_masked;

architecture sim of tb_aes_sbox_masked is

    constant CLK_PERIOD : time := 20 ns;

    signal clk          : std_logic := '0';
    signal mask_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal recomp_start : std_logic := '0';
    signal recomp_done  : std_logic;
    signal addr         : std_logic_vector(7 downto 0) := (others => '0');
    signal dout         : std_logic_vector(7 downto 0);
    signal mask_out     : std_logic_vector(7 downto 0);

    signal sim_done : boolean := false;

    -- Reference AES S-Box
    type sbox_t is array (0 to 255) of std_logic_vector(7 downto 0);
    constant SBOX_REF : sbox_t := (
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

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    UUT: entity work.aes_sbox_masked
        port map (
            clk          => clk,
            mask_byte    => mask_byte,
            recomp_start => recomp_start,
            recomp_done  => recomp_done,
            addr         => addr,
            dout         => dout,
            mask_out     => mask_out
        );

    stim: process
        variable expected : std_logic_vector(7 downto 0);
        variable x_val    : integer;
        variable err_cnt  : integer;
    begin
        -----------------------------------------------------------------
        -- T1: Initial state -- recomp_done = 0
        -----------------------------------------------------------------
        report "T1: Initial state";
        wait for CLK_PERIOD * 3;
        assert recomp_done = '0'
            report "T1 FAIL: recomp_done should be 0" severity failure;
        report "T1 PASS";

        -----------------------------------------------------------------
        -- T2: Recompute with mask = 0x00 (identity)
        -- mt[a] = S[a XOR 0] XOR 0 = S[a]
        -----------------------------------------------------------------
        report "T2: Recomp with mask=0x00";
        mask_byte <= x"00";
        recomp_start <= '1';
        wait for CLK_PERIOD;
        recomp_start <= '0';

        -- Wait for recomp to complete (~260 cycles)
        for i in 0 to 300 loop
            wait for CLK_PERIOD;
            if recomp_done = '1' then
                exit;
            end if;
        end loop;

        assert recomp_done = '1'
            report "T2 FAIL: recomp not done after 300 cycles" severity failure;

        -- Verify: lookup(a) should equal S[a] for mask=0
        err_cnt := 0;
        for i in 0 to 255 loop
            addr <= std_logic_vector(to_unsigned(i, 8));
            wait for CLK_PERIOD * 2;  -- 1 cycle read latency + register

            expected := SBOX_REF(i);
            if dout /= expected then
                err_cnt := err_cnt + 1;
                if err_cnt <= 3 then
                    report "T2 MISMATCH: addr=" & integer'image(i) &
                           " got=" & integer'image(to_integer(unsigned(dout))) &
                           " exp=" & integer'image(to_integer(unsigned(expected)));
                end if;
            end if;
        end loop;

        assert err_cnt = 0
            report "T2 FAIL: " & integer'image(err_cnt) & " mismatches with mask=0x00" severity failure;
        report "T2 PASS: All 256 entries correct with mask=0x00";

        -----------------------------------------------------------------
        -- T3: Recompute with mask = 0xA5
        -- For input x, caller presents addr = x XOR m
        -- mt[x XOR m] = S[(x XOR m) XOR m] XOR m = S[x] XOR m
        -- So: lookup(x XOR m) XOR m = S[x]
        -----------------------------------------------------------------
        report "T3: Recomp with mask=0xA5";
        mask_byte <= x"A5";
        recomp_start <= '1';
        wait for CLK_PERIOD;
        recomp_start <= '0';

        for i in 0 to 300 loop
            wait for CLK_PERIOD;
            if recomp_done = '1' then
                exit;
            end if;
        end loop;

        assert recomp_done = '1'
            report "T3 FAIL: recomp not done" severity failure;

        -- Verify: for real input x, addr = x XOR 0xA5
        -- lookup(addr) = S[x] XOR 0xA5
        -- So: lookup(addr) XOR 0xA5 = S[x]
        err_cnt := 0;
        for x_val in 0 to 255 loop
            -- Present masked address
            addr <= std_logic_vector(to_unsigned(x_val, 8) xor to_unsigned(16#A5#, 8));
            wait for CLK_PERIOD * 2;

            -- Unmask output
            expected := SBOX_REF(x_val);
            if (dout xor x"A5") /= expected then
                err_cnt := err_cnt + 1;
                if err_cnt <= 3 then
                    report "T3 MISMATCH: x=" & integer'image(x_val) &
                           " got_unmasked=" & integer'image(to_integer(unsigned(dout xor x"A5"))) &
                           " exp=" & integer'image(to_integer(unsigned(expected)));
                end if;
            end if;
        end loop;

        assert err_cnt = 0
            report "T3 FAIL: " & integer'image(err_cnt) & " mismatches with mask=0xA5" severity failure;
        report "T3 PASS: All 256 entries correct with mask=0xA5";

        -----------------------------------------------------------------
        -- T4: mask_out reflects current mask
        -----------------------------------------------------------------
        report "T4: mask_out check";
        assert mask_out = x"A5"
            report "T4 FAIL: mask_out mismatch" severity failure;
        report "T4 PASS";

        -----------------------------------------------------------------
        report "ALL TESTS PASSED: tb_aes_sbox_masked";
        sim_done <= true;
        wait;
    end process;

end sim;
