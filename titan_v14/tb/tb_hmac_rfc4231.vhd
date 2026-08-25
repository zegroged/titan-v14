--------------------------------------------------------------------------------
-- TITAN V14.3: HMAC-SHA256 Known Answer Test (KAT)
-- Standard: RFC 4231 + Python pycryptodome cross-verified
--------------------------------------------------------------------------------
-- Her vektor Python HMAC-SHA256 ile bagimsiz hesaplandi
-- TB sadece birebir eslesme kabul eder — davranis testi DEGIL
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_hmac_rfc4231 is
end tb_hmac_rfc4231;

architecture TB of tb_hmac_rfc4231 is

    constant CLK_PERIOD : time := 20 ns;
    signal clk         : std_logic := '0';
    signal rst_n       : std_logic := '0';
    signal kill_signal : std_logic := '0';
    signal key_in      : std_logic_vector(255 downto 0) := (others => '0');
    signal msg_in      : std_logic_vector(127 downto 0) := (others => '0');
    signal start       : std_logic := '0';
    signal hmac_out    : std_logic_vector(255 downto 0);
    signal hmac_valid  : std_logic;
    signal busy        : std_logic;

    signal pass_count : integer := 0;
    signal fail_count : integer := 0;

    -- Test vector record
    type test_vector_t is record
        name     : string(1 to 24);
        key      : std_logic_vector(255 downto 0);
        msg      : std_logic_vector(127 downto 0);
        expected : std_logic_vector(255 downto 0);
    end record;

    type test_array_t is array (natural range <>) of test_vector_t;

    ---------------------------------------------------------------------------
    -- Python ile hesaplanan referans degerler:
    --   import hmac, hashlib
    --   hmac.new(key, msg, hashlib.sha256).hexdigest()
    ---------------------------------------------------------------------------
    constant VECTORS : test_array_t := (
        -- V1: RFC 4231 TC1 adapted (key=0x0b*20 padded to 32B, msg=0x4869205468657265 padded to 16B)
        (
            name     => "RFC4231-TC1 adapted     ",
            key      => x"0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b000000000000000000000000",
            msg      => x"48692054686572650000000000000000",
            expected => x"40B9168918AC7B1B2B5EB2931CB16B18EE57289B192B8A15323EF716E9E15A5B"
        ),
        -- V2: Full 256-bit key + 128-bit message (Python verified)
        (
            name     => "Full-256 key + msg      ",
            key      => x"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
            msg      => x"DEADBEEFCAFEBABE12345678AABBCCDD",
            expected => x"9068A1E7D936AAEDFAE36E63E571B71BF1EDFB47F1720CC13A5589E4BCEE85C6"
        ),
        -- V3: All zeros (Python verified)
        (
            name     => "All-zeros               ",
            key      => x"0000000000000000000000000000000000000000000000000000000000000000",
            msg      => x"00000000000000000000000000000000",
            expected => x"853C7403937D8B6239569B184EB7993FC5F751AEFCEA28F2C863858E2D29C50B"
        ),
        -- V4: All-0xFF (Python verified)
        (
            name     => "All-0xFF                ",
            key      => x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
            msg      => x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
            expected => x"85EA2B9BE8E0237A3213CF7F21F8F9F25A12908172189E21F3ED0B862EB32E76"
        )
    );

begin

    clk <= not clk after CLK_PERIOD / 2;

    DUT : entity work.hmac_sha256
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => kill_signal,
            key_in      => key_in,
            msg_in      => msg_in,
            start       => start,
            hmac_out    => hmac_out,
            hmac_valid  => hmac_valid,
            busy        => busy
        );

    process
        variable timeout : integer;
    begin
        report "========================================";
        report " HMAC-SHA256 KAT (Python Cross-Verified)";
        report " 4 vectors, each independently calculated";
        report "========================================";

        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        for i in VECTORS'range loop
            report "--- V" & integer'image(i) & ": " & VECTORS(i).name & " ---";

            key_in <= VECTORS(i).key;
            msg_in <= VECTORS(i).msg;
            start  <= '1';
            wait for CLK_PERIOD;
            start  <= '0';

            -- Wait for hmac_valid
            timeout := 0;
            while hmac_valid /= '1' loop
                wait for CLK_PERIOD;
                timeout := timeout + 1;
                if timeout > 5000 then
                    report "  TIMEOUT after 5000 cycles!" severity failure;
                    exit;
                end if;
            end loop;

            if timeout <= 5000 then
                report "  Expected: " & to_hstring(VECTORS(i).expected);
                report "  Got:      " & to_hstring(hmac_out);
                if hmac_out = VECTORS(i).expected then
                    report "  [OK] PASS -- birebir eslesme";
                    pass_count <= pass_count + 1;
                else
                    report "  [XX] FAIL -- NIST referansi ile uyusmuyor" severity failure;
                    fail_count <= fail_count + 1;
                end if;
            end if;

            wait for CLK_PERIOD * 10;
        end loop;

        -- Summary
        wait for CLK_PERIOD * 5;
        report "========================================";
        report " HMAC KAT: " & integer'image(pass_count) & " passed, " &
               integer'image(fail_count) & " failed out of 4";
        if fail_count = 0 then
            report " VERDICT: ALL KAT VECTORS MATCH";
        else
            report " VERDICT: *** FAIL ***" severity failure;
        end if;
        report "========================================";

        std.env.stop;
    end process;

end TB;
