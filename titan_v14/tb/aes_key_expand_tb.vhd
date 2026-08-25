--------------------------------------------------------------------------------
-- DEBUG: AES-256 Key Expansion Standalone Test
-- Dumps all 15 round keys for NIST FIPS-197 Appendix A.3 verification
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes_key_expand_tb is
end aes_key_expand_tb;

architecture Behavioral of aes_key_expand_tb is

    constant CLK_PERIOD : time := 20 ns;
    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';
    signal sim_done : boolean := false;

    signal key_in      : std_logic_vector(255 downto 0);
    signal key_load    : std_logic := '0';
    signal key_start   : std_logic := '0';
    signal round_key   : std_logic_vector(127 downto 0);
    signal round_valid : std_logic;
    signal expand_done : std_logic;

    -- NIST FIPS-197 Appendix A.3 — AES-256
    constant NIST_KEY : std_logic_vector(255 downto 0) :=
        x"000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F";

    -- NIST expected round keys (from FIPS-197 Appendix A.3)
    type rk_array_t is array (0 to 14) of std_logic_vector(127 downto 0);
    constant NIST_RK : rk_array_t := (
        -- RK0 = W[0..3]
        x"000102030405060708090A0B0C0D0E0F",
        -- RK1 = W[4..7]
        x"101112131415161718191A1B1C1D1E1F",
        -- RK2 = W[8..11]
        x"A573C29FA176C498A97FCE93A572C09C",
        -- RK3 = W[12..15]
        x"1651A8CD0244BEDA1A5DA4C10640BADE",
        -- RK4 = W[16..19]
        x"AE87DFF00FF11B68A68ED5FB03FC1567",
        -- RK5 = W[20..23]
        x"6DE1F1486FA54F9275F8EB5373B8518D",
        -- RK6 = W[24..27]
        x"C656827FC9A799176F294CEC6CD5598B",
        -- RK7 = W[28..31]
        x"3DE23A75524775E727BF9EB45407CF39",
        -- RK8 = W[32..35]
        x"0BDC905FC27B0948AD5245A4C1871C2F",
        -- RK9 = W[36..39]
        x"45F5A66017B2D387300D4D33640A820A",
        -- RK10 = W[40..43]
        x"7CCFF71CBEB4FE5413E6BBF0D261A7DF",
        -- RK11 = W[44..47]
        x"F01AFAFEE7A82979D7A5644AB3AFE640",
        -- RK12 = W[48..51]
        x"2541FE719BF500258813BBD55A721C0A",
        -- RK13 = W[52..55]
        x"4E5A6699A9F24FE07E572BAACDF8CDEA",
        -- RK14 = W[56..59]
        x"24FC79CCBF0979E9371AC23C6D68DE36"
    );

    signal rk_count : integer := 0;
    signal all_pass : boolean := true;

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

    dut : entity work.aes_key_expand
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => '0',
            key_in      => NIST_KEY,
            key_load    => key_load,
            key_start   => key_start,
            round_key   => round_key,
            round_valid => round_valid,
            expand_done => expand_done
        );

    process
        variable timeout_cnt : integer := 0;
    begin
        report "========================================" severity note;
        report " AES-256 Key Expansion Test" severity note;
        report " NIST FIPS-197 Appendix A.3" severity note;
        report "========================================" severity note;

        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 3;

        -- Load key
        key_load <= '1';
        wait for CLK_PERIOD;
        key_load <= '0';
        wait for CLK_PERIOD * 3;

        -- Start expansion
        key_start <= '1';
        wait for CLK_PERIOD;
        key_start <= '0';

        -- Collect round keys
        timeout_cnt := 0;
        while expand_done /= '1' and timeout_cnt < 2000 loop
            wait for CLK_PERIOD;
            timeout_cnt := timeout_cnt + 1;

            if round_valid = '1' then
                report "RK" & integer'image(rk_count) & ":" severity note;
                report "  Got:      " & to_hstring(round_key) severity note;
                report "  Expected: " & to_hstring(NIST_RK(rk_count)) severity note;
                if round_key = NIST_RK(rk_count) then
                    report "  => MATCH" severity note;
                else
                    report "  => MISMATCH!" severity error;
                    report "  XOR diff: " & to_hstring(round_key xor NIST_RK(rk_count)) severity error;
                    all_pass <= false;
                end if;
                rk_count <= rk_count + 1;
            end if;
        end loop;

        -- wait one extra cycle to catch the last round_valid
        wait for CLK_PERIOD;
        if round_valid = '1' then
            report "RK" & integer'image(rk_count) & ":" severity note;
            report "  Got:      " & to_hstring(round_key) severity note;
            report "  Expected: " & to_hstring(NIST_RK(rk_count)) severity note;
            if round_key = NIST_RK(rk_count) then
                report "  => MATCH" severity note;
            else
                report "  => MISMATCH!" severity error;
                all_pass <= false;
            end if;
        end if;

        wait for CLK_PERIOD * 5;

        if all_pass then
            report "========================================" severity note;
            report " ALL ROUND KEYS MATCH NIST SPEC!" severity note;
            report "========================================" severity note;
        else
            report "========================================" severity error;
            report " KEY EXPANSION DOES NOT MATCH NIST!" severity error;
            report "========================================" severity error;
        end if;

        sim_done <= true;
        wait;
    end process;

end Behavioral;
