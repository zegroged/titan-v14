--------------------------------------------------------------------------------
-- AEGIS Phase 2.4: Testbench for ESN Readout Layer
--------------------------------------------------------------------------------
-- Tests: weight loading, prediction, bank swap, new weights prediction.
-- Verifies double-buffering safety and ±1 LSB prediction accuracy.
-- Values from generate_readout_vectors.py (seed=123).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.esn_weight_pkg.all;

entity tb_esn_readout is
end entity tb_esn_readout;

architecture sim of tb_esn_readout is

    constant CLK_P : time := 20 ns;
    constant AB    : integer := 3;

    signal clk         : std_logic := '0';
    signal rst_n       : std_logic := '0';
    signal state_vec   : std_logic_vector(ESN_N*16-1 downto 0) := (others => '0');
    signal state_valid : std_logic := '0';
    signal wr_data     : std_logic_vector(15 downto 0) := (others => '0');
    signal wr_addr     : std_logic_vector(AB-1 downto 0) := (others => '0');
    signal wr_en       : std_logic := '0';
    signal swap_sig    : std_logic := '0';
    signal prediction  : std_logic_vector(15 downto 0);
    signal pred_valid  : std_logic;
    signal running     : boolean := true;

    -- Weight banks from CSV (exact hex values)
    type w_arr is array (0 to ESN_N-1) of std_logic_vector(15 downto 0);
    constant WB0 : w_arr := (
        x"005D", x"FF1C", x"FF71", x"FF5E",
        x"FF5A", x"00A0", x"00D9", x"FF8E"
    );
    constant WB1 : w_arr := (
        x"0052", x"0064", x"0003", x"FFBF",
        x"0053", x"FFB7", x"003E", x"0021"
    );

    -- State vectors from CSV: s7 & s6 & s5 & s4 & s3 & s2 & s1 & s0 (MSB first)
    -- CSV order: s0,s1,s2,s3,s4,s5,s6,s7 -> VHDL bus: s7&s6&...&s0
    type sv_arr is array (0 to 4) of std_logic_vector(ESN_N*16-1 downto 0);
    constant TSV : sv_arr := (
        -- Step 0: s7=0015 s6=FFFF s5=FFAA s4=FFBB s3=0005 s2=004D s1=FFBB s0=006D
        x"0015FFFFFFAAFFBB0005004DFFBB006D",
        -- Step 1: s7=005D s6=006B s5=0020 s4=006B s3=003A s2=FFF9 s1=FF84 s0=FFAF
        x"005D006B0020006B003AFFF9FF84FFAF",
        -- Step 2: s7=0007 s6=FFCD s5=005D s4=004C s3=FFC7 s2=003B s1=005E s0=FFB8
        x"0007FFCD005D004CFFC7003B005EFFB8",
        -- Step 3: s7=FF88 s6=FF84 s5=FFD0 s4=FFAC s3=0044 s2=FFBD s1=0015 s0=FF92
        x"FF88FF84FFD0FFAC0044FFBD0015FF92",
        -- Step 4: s7=FFED s6=0013 s5=FFE2 s4=FF81 s3=FFC2 s2=FFA1 s1=FFF8 s0=FFFF
        x"FFED0013FFE2FF81FFC2FFA1FFF8FFFF"
    );

    -- Expected predictions from CSV
    type exp_arr is array (0 to 4) of std_logic_vector(15 downto 0);
    constant EXP : exp_arr := (
        x"0023", x"0030", x"FF70", x"FF98", x"FFED"
    );

    function slv_hex(v : std_logic_vector(15 downto 0)) return string is
        variable r : string(1 to 4);
        variable n : integer;
        constant H : string := "0123456789ABCDEF";
    begin
        for i in 0 to 3 loop
            n := to_integer(unsigned(v(15-4*i downto 12-4*i)));
            r(i+1) := H(n+1);
        end loop;
        return r;
    end function;

begin

    clk_gen : process
    begin
        while running loop
            clk <= '0'; wait for CLK_P/2;
            clk <= '1'; wait for CLK_P/2;
        end loop;
        wait;
    end process;

    dut : entity work.esn_readout
        generic map (ADDR_BITS => AB)
        port map (
            clk              => clk,
            rst_n            => rst_n,
            state_vector     => state_vec,
            state_valid      => state_valid,
            weights_wr_data  => wr_data,
            weights_wr_addr  => wr_addr,
            weights_wr_en    => wr_en,
            weights_swap     => swap_sig,
            prediction       => prediction,
            prediction_valid => pred_valid
        );

    stim : process
        variable pc : integer := 0;
        variable fc : integer := 0;
        variable wc : integer;
        variable df : integer;
    begin
        rst_n <= '0';
        wait for CLK_P * 5;
        rst_n <= '1';
        wait for CLK_P * 2;

        -- Load bank 0 weights into shadow bank
        report "Loading bank 0 weights..." severity note;
        for i in 0 to ESN_N-1 loop
            wr_data <= WB0(i);
            wr_addr <= std_logic_vector(to_unsigned(i, AB));
            wr_en   <= '1';
            wait for CLK_P;
        end loop;
        wr_en <= '0';
        wait for CLK_P;

        -- Swap to make bank 0 active
        swap_sig <= '1'; wait for CLK_P;
        swap_sig <= '0'; wait for CLK_P;

        -- Test steps 0-2 with bank 0
        for step in 0 to 2 loop
            state_vec   <= TSV(step);
            state_valid <= '1';
            wait for CLK_P;
            state_valid <= '0';

            wc := 0;
            while pred_valid /= '1' and wc < 50 loop
                wait for CLK_P;
                wc := wc + 1;
            end loop;

            df := abs(to_integer(signed(prediction)) -
                      to_integer(signed(EXP(step))));
            if df <= 1 then
                pc := pc + 1;
                report "PASS step " & integer'image(step) &
                       " pred=0x" & slv_hex(prediction) &
                       " cyc=" & integer'image(wc) severity note;
            else
                fc := fc + 1;
                report "FAIL step " & integer'image(step) &
                       " exp=0x" & slv_hex(EXP(step)) &
                       " got=0x" & slv_hex(prediction) severity error;
            end if;
            wait for CLK_P * 2;
        end loop;

        -- Load bank 1 weights into (new) shadow
        report "Loading bank 1 weights to shadow..." severity note;
        for i in 0 to ESN_N-1 loop
            wr_data <= WB1(i);
            wr_addr <= std_logic_vector(to_unsigned(i, AB));
            wr_en   <= '1';
            wait for CLK_P;
        end loop;
        wr_en <= '0';
        wait for CLK_P;

        -- Swap
        swap_sig <= '1'; wait for CLK_P;
        swap_sig <= '0'; wait for CLK_P;

        -- Test steps 3-4 with bank 1
        for step in 3 to 4 loop
            state_vec   <= TSV(step);
            state_valid <= '1';
            wait for CLK_P;
            state_valid <= '0';

            wc := 0;
            while pred_valid /= '1' and wc < 50 loop
                wait for CLK_P;
                wc := wc + 1;
            end loop;

            df := abs(to_integer(signed(prediction)) -
                      to_integer(signed(EXP(step))));
            if df <= 1 then
                pc := pc + 1;
                report "PASS step " & integer'image(step) &
                       " pred=0x" & slv_hex(prediction) severity note;
            else
                fc := fc + 1;
                report "FAIL step " & integer'image(step) &
                       " exp=0x" & slv_hex(EXP(step)) &
                       " got=0x" & slv_hex(prediction) severity error;
            end if;
            wait for CLK_P * 2;
        end loop;

        report "========================================" severity note;
        report " READOUT TEST: 5 predictions" severity note;
        report "   PASS: " & integer'image(pc) severity note;
        report "   FAIL: " & integer'image(fc) severity note;
        report "========================================" severity note;

        if fc = 0 then
            report "ALL TESTS PASSED!" severity note;
        else
            report "SOME TESTS FAILED!" severity error;
        end if;

        running <= false;
        wait;
    end process;

end architecture sim;
