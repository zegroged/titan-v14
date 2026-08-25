--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES-256 Multi-Vector Independent Verification
-- Purpose: Prove the fix is real — not accidental single-vector match
--------------------------------------------------------------------------------
-- 3 Independent NIST test vectors from different sources:
--   Vector 1: FIPS-197 Appendix C.3
--   Vector 2: NIST SP 800-38A (ECB mode)
--   Vector 3: All-zeros key + all-zeros plaintext
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes256_multi_vector_tb is
end aes256_multi_vector_tb;

architecture Behavioral of aes256_multi_vector_tb is

    constant CLK_PERIOD : time := 20 ns;
    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';
    signal sim_done : boolean := false;

    signal key_in      : std_logic_vector(255 downto 0);
    signal key_load    : std_logic := '0';
    signal plaintext   : std_logic_vector(127 downto 0);
    signal start       : std_logic := '0';
    signal ciphertext  : std_logic_vector(127 downto 0);
    signal done        : std_logic;
    signal busy        : std_logic;
    signal fault       : std_logic;

    -- Test vectors
    type test_vector_t is record
        name     : string(1 to 20);
        key      : std_logic_vector(255 downto 0);
        pt       : std_logic_vector(127 downto 0);
        expected : std_logic_vector(127 downto 0);
    end record;

    type test_array_t is array (natural range <>) of test_vector_t;

    constant TESTS : test_array_t := (
        -- Vector 1: FIPS-197 C.3
        (
            name     => "FIPS-197 C.3        ",
            key      => x"000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F",
            pt       => x"00112233445566778899AABBCCDDEEFF",
            expected => x"8EA2B7CA516745BFEAFC49904B496089"
        ),
        -- Vector 2: NIST SP 800-38A ECB
        (
            name     => "SP800-38A ECB       ",
            key      => x"603DEB1015CA71BE2B73AEF0857D77811F352C073B6108D72D9810A30914DFF4",
            pt       => x"6BC1BEE22E409F96E93D7E117393172A",
            expected => x"F3EED1BDB5D2A03C064B5A7E3DB181F8"
        ),
        -- Vector 3: All-zero key, all-zero plaintext (from pycryptodome verified)
        (
            name     => "All-zeros           ",
            key      => x"0000000000000000000000000000000000000000000000000000000000000000",
            pt       => x"00000000000000000000000000000000",
            expected => x"DC95C078A2408989AD48A21492842087"
        )
    );

    signal pass_count : integer := 0;
    signal fail_count : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

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

    process
        variable timeout : integer;
    begin
        report "============================================" severity note;
        report " MULTI-VECTOR AES-256 INDEPENDENT VERIFY" severity note;
        report " 3 vectors from 3 different NIST sources" severity note;
        report "============================================" severity note;

        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        for i in TESTS'range loop
            report "--- Vector " & integer'image(i) & ": " & TESTS(i).name & " ---" severity note;

            -- Load key
            key_in <= TESTS(i).key;
            key_load <= '1';
            wait for CLK_PERIOD;
            key_load <= '0';
            wait for CLK_PERIOD * 3;

            -- Start encryption
            plaintext <= TESTS(i).pt;
            start <= '1';
            wait for CLK_PERIOD;
            start <= '0';

            -- Wait for done
            timeout := 0;
            while done /= '1' loop
                wait for CLK_PERIOD;
                timeout := timeout + 1;
                if timeout > 2000 then
                    report "  TIMEOUT!" severity error;
                    fail_count <= fail_count + 1;
                    exit;
                end if;
            end loop;

            if timeout <= 2000 then
                report "  Expected: " & to_hstring(TESTS(i).expected) severity note;
                report "  Got:      " & to_hstring(ciphertext) severity note;
                if ciphertext = TESTS(i).expected then
                    report "  [OK] PASS" severity note;
                    pass_count <= pass_count + 1;
                else
                    report "  [XX] FAIL" severity error;
                    report "  XOR diff: " & to_hstring(ciphertext xor TESTS(i).expected) severity error;
                    fail_count <= fail_count + 1;
                end if;
            end if;

            wait for CLK_PERIOD * 5;
        end loop;

        wait for CLK_PERIOD * 5;
        report "============================================" severity note;
        report " RESULTS: " & integer'image(pass_count) & " passed, " &
               integer'image(fail_count) & " failed out of 3" severity note;

        if fail_count = 0 then
            report " VERDICT: AES-256 INDEPENDENTLY VERIFIED" severity note;
        else
            report " VERDICT: AES-256 STILL HAS BUGS!" severity error;
        end if;
        report "============================================" severity note;

        sim_done <= true;
        wait;
    end process;

end Behavioral;
