--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Standalone AES-256 NIST KAT Testbench
-- FIPS 197 Appendix C.3 Test Vector
--------------------------------------------------------------------------------
-- AMAÇ: AES-256 core'un doğruluğunu NIST expected ciphertext ile doğrula.
--        Bağımsız test — comm_protocol veya wrapper olmadan.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes256_standalone_tb is
end aes256_standalone_tb;

architecture Behavioral of aes256_standalone_tb is

    constant CLK_PERIOD : time := 20 ns;  -- 50 MHz
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal sim_done     : boolean := false;

    -- AES Core signals
    signal key_in       : std_logic_vector(255 downto 0);
    signal key_load     : std_logic := '0';
    signal plaintext    : std_logic_vector(127 downto 0);
    signal start        : std_logic := '0';
    signal ciphertext   : std_logic_vector(127 downto 0);
    signal done         : std_logic;
    signal busy         : std_logic;
    signal fault        : std_logic;

    -- NIST FIPS 197 Appendix C.3 — AES-256
    constant NIST_KEY : std_logic_vector(255 downto 0) :=
        x"000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F";
    constant NIST_PT  : std_logic_vector(127 downto 0) :=
        x"00112233445566778899AABBCCDDEEFF";
    constant NIST_CT  : std_logic_vector(127 downto 0) :=
        x"8EA2B7CA516745BFEAFC49904B496089";

    -- Test state
    signal test_pass : boolean := false;

begin

    -- Clock generator
    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

    -- DUT
    dut : entity work.aes256_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => '0',
            key_in         => key_in,
            key_load       => key_load,
            plaintext      => plaintext,
            start          => start,
            ciphertext     => ciphertext,
            done           => done,
            busy           => busy,
            -- ★ FIX: trng_mask required by aes256_core (zero = no masking for KAT test)
            trng_mask      => (others => '0'),
            fault_detected => fault
        );

    -- Main test process
    process
        variable timeout_cnt : integer := 0;
    begin
        report "========================================" severity note;
        report " NIST AES-256 KAT Test (FIPS 197 C.3)" severity note;
        report "========================================" severity note;

        -- Reset
        rst_n <= '0';
        key_load <= '0';
        start <= '0';
        key_in <= NIST_KEY;
        plaintext <= NIST_PT;
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        -- Step 1: Load key
        report "STEP 1: Loading NIST key..." severity note;
        key_load <= '1';
        wait for CLK_PERIOD;
        key_load <= '0';
        wait for CLK_PERIOD * 3;

        -- Step 2: Start encryption
        report "STEP 2: Starting encryption..." severity note;
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';

        -- Step 3: Wait for done (with timeout)
        timeout_cnt := 0;
        while done /= '1' loop
            wait for CLK_PERIOD;
            timeout_cnt := timeout_cnt + 1;
            if timeout_cnt > 2000 then
                report "TIMEOUT: AES did not complete within 2000 cycles!" severity error;
                report "TEST RESULT: *** FAIL (TIMEOUT) ***" severity error;
                sim_done <= true;
                wait;
            end if;
        end loop;

        report "AES completed in " & integer'image(timeout_cnt) & " cycles" severity note;

        -- Step 4: Check fault
        if fault = '1' then
            report "FAULT DETECTED by AES core!" severity warning;
        end if;

        -- Step 5: Compare ciphertext
        report "STEP 3: Comparing ciphertext..." severity note;
        report "  Expected: " & to_hstring(NIST_CT) severity note;
        report "  Got:      " & to_hstring(ciphertext) severity note;

        if ciphertext = NIST_CT then
            report "========================================" severity note;
            report " TEST RESULT: *** PASS ***" severity note;
            report " AES-256 is NIST FIPS-197 compliant!" severity note;
            report "========================================" severity note;
            test_pass <= true;
        else
            report "========================================" severity error;
            report " TEST RESULT: *** FAIL ***" severity error;
            report " AES output does NOT match NIST vector!" severity error;
            report " BRAM timing bug CONFIRMED!" severity error;
            report "========================================" severity error;
            -- Show XOR diff
            report "  XOR diff: " & to_hstring(ciphertext xor NIST_CT) severity error;
        end if;

        wait for CLK_PERIOD * 5;
        sim_done <= true;
        wait;
    end process;

end Behavioral;
