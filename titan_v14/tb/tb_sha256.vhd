--------------------------------------------------------------------------------
-- PROJECT TITAN V14: SHA-256 Test Bench (NIST FIPS 180-4 Vectors)
--------------------------------------------------------------------------------
-- Test Vectors:
--   1. NIST 1-Block: "abc" (24 bits + padding)
--      Expected: ba7816bf 8f01cfea 414140de 5dae2223
--                b00361a3 96177a9c b410ff61 f20015ad
--
--   2. NIST 2-Block: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
--      Expected: 248d6a61 d20638b8 e5c02693 0c3e6039
--                a33ce459 64ff2167 f6ecedd4 19db06c1
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_sha256 is
end tb_sha256;

architecture Behavioral of tb_sha256 is

    signal clk         : std_logic := '0';
    signal rst_n       : std_logic := '0';
    signal kill_signal : std_logic := '0';
    signal start       : std_logic := '0';
    signal last_block  : std_logic := '0';
    signal data_in     : std_logic_vector(31 downto 0) := (others => '0');
    signal data_valid  : std_logic := '0';
    signal hash_out    : std_logic_vector(255 downto 0);
    signal hash_valid  : std_logic;
    signal busy        : std_logic;
    signal ready       : std_logic;

    constant CLK_PERIOD : time := 20 ns;

    signal pass_count : integer := 0;
    signal fail_count : integer := 0;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD / 2;

    -- DUT
    dut : entity work.sha256_core
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => kill_signal,
            start       => start,
            last_block  => last_block,
            data_in     => data_in,
            data_valid  => data_valid,
            hash_out    => hash_out,
            hash_valid  => hash_valid,
            busy        => busy,
            ready       => ready
        );

    -- Main test process
    process
        -- Helper: feed one 32-bit word
        procedure feed_word(w : std_logic_vector(31 downto 0);
                            is_last_blk : boolean := false) is
        begin
            wait until rising_edge(clk) and ready = '1';
            data_in    <= w;
            data_valid <= '1';
            if is_last_blk then
                last_block <= '1';
            end if;
            wait until rising_edge(clk);
            data_valid <= '0';
            last_block <= '0';
        end procedure;

        -- NIST 1-Block message: "abc" (padded to 512 bits)
        -- 0x61626380 00000000 00000000 00000000
        -- 00000000 00000000 00000000 00000000
        -- 00000000 00000000 00000000 00000000
        -- 00000000 00000000 00000000 00000018
        constant NIST1_EXPECTED : std_logic_vector(255 downto 0) :=
            x"ba7816bf8f01cfea414140de5dae2223" &
            x"b00361a396177a9cb410ff61f20015ad";

        -- NIST 2-Block message: 
        -- "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        -- Block 1 (words 0-15):
        -- 0x61626364 62636465 63646566 64656667
        -- 65666768 66676869 6768696a 68696a6b
        -- 696a6b6c 6a6b6c6d 6b6c6d6e 6c6d6e6f
        -- 6d6e6f70 6e6f7071 80000000 00000000
        -- Block 2 (words 0-15):
        -- 0x00000000 * 14 + 0x00000000 0x000001c0
        constant NIST2_EXPECTED : std_logic_vector(255 downto 0) :=
            x"248d6a61d20638b8e5c026930c3e6039" &
            x"a33ce45964ff2167f6ecedd419db06c1";

    begin
        report "========================================";
        report " SHA-256 NIST FIPS 180-4 Test Vectors";
        report "========================================";

        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 3;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        ---------------------------------------------------------------
        -- TEST 1: NIST 1-Block "abc"
        ---------------------------------------------------------------
        report "TEST 1: 1-block SHA-256 (abc)";
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- Feed 16 words (padded "abc")
        feed_word(x"61626380");  -- 'a','b','c', 0x80 padding
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000018", true);  -- Length = 24 bits, last block

        -- Wait for hash
        wait until hash_valid = '1' for 200 * CLK_PERIOD;

        if hash_valid = '1' then
            if hash_out = NIST1_EXPECTED then
                report "TEST 1 PASS: SHA-256(abc) matches NIST" severity note;
                pass_count <= pass_count + 1;
            else
                report "TEST 1 FAIL: hash mismatch" severity error;
                fail_count <= fail_count + 1;
            end if;
        else
            report "TEST 1 FAIL: timeout" severity error;
            fail_count <= fail_count + 1;
        end if;

        wait for CLK_PERIOD * 5;

        ---------------------------------------------------------------
        -- TEST 2: NIST 2-Block 448-bit message
        ---------------------------------------------------------------
        report "TEST 2: 2-block SHA-256 (448-bit message)";
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- Block 1: 16 words
        feed_word(x"61626364");
        feed_word(x"62636465");
        feed_word(x"63646566");
        feed_word(x"64656667");
        feed_word(x"65666768");
        feed_word(x"66676869");
        feed_word(x"6768696a");
        feed_word(x"68696a6b");
        feed_word(x"696a6b6c");
        feed_word(x"6a6b6c6d");
        feed_word(x"6b6c6d6e");
        feed_word(x"6c6d6e6f");
        feed_word(x"6d6e6f70");
        feed_word(x"6e6f7071");
        feed_word(x"80000000");
        feed_word(x"00000000");  -- End of block 1

        -- Wait for block 1 processing + ready for block 2
        wait until ready = '1' for 200 * CLK_PERIOD;

        -- Block 2: 16 words (padding + length)
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"00000000");
        feed_word(x"000001c0", true);  -- Length = 448 bits, last block

        -- Wait for hash
        wait until hash_valid = '1' for 300 * CLK_PERIOD;

        if hash_valid = '1' then
            if hash_out = NIST2_EXPECTED then
                report "TEST 2 PASS: SHA-256(2-block) matches NIST" severity note;
                pass_count <= pass_count + 1;
            else
                report "TEST 2 FAIL: hash mismatch" severity error;
                fail_count <= fail_count + 1;
            end if;
        else
            report "TEST 2 FAIL: timeout" severity error;
            fail_count <= fail_count + 1;
        end if;

        wait for CLK_PERIOD * 3;

        ---------------------------------------------------------------
        -- TEST 3: Kill signal zeroization
        ---------------------------------------------------------------
        report "TEST 3: Kill zeroization";
        kill_signal <= '1';
        wait for CLK_PERIOD * 2;
        kill_signal <= '0';
        wait for CLK_PERIOD;

        if hash_out = x"0000000000000000000000000000000000000000000000000000000000000000" then
            report "TEST 3 PASS: Hash zeroized after kill" severity note;
            pass_count <= pass_count + 1;
        else
            report "TEST 3 FAIL: Hash not zeroized" severity error;
            fail_count <= fail_count + 1;
        end if;

        ---------------------------------------------------------------
        -- SUMMARY
        ---------------------------------------------------------------
        wait for CLK_PERIOD * 2;
        report "========================================";
        report " SHA-256: " & integer'image(pass_count + 1) & " passed, "
               & integer'image(fail_count) & " failed";
        if fail_count = 0 then
            report " VERDICT: PASS" severity note;
        else
            report " VERDICT: FAIL" severity error;
        end if;
        report "========================================";

        wait;
    end process;

end Behavioral;
