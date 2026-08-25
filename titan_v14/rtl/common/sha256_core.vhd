--------------------------------------------------------------------------------
-- PROJECT TITAN V14: SHA-256 Core (NIST FIPS 180-4)
-- Module: Iterative 64-Round SHA-256 Hash Engine
--------------------------------------------------------------------------------
--
-- KİMSEYE GÜVENME PLANI: Bu modül firmware integrity (P3-11) ve
-- HMAC-SHA256 heartbeat (P3-9) için temel bağımlılıktır.
--
-- SPEC:  NIST FIPS 180-4, Section 6.2 (SHA-256)
-- AREA:  ~800 LUT (iterative, 1 round/cycle)
-- SPEED: 64 cycles/block + overhead
--
-- INTERFACE (Streaming):
--   1. Assert 'start' → core initializes H values
--   2. Feed 32-bit words via data_in/data_valid (16 words = 512-bit block)
--   3. Assert 'last_block' with final block (padding must be done externally)
--   4. Wait for hash_valid → hash_out contains 256-bit digest
--
-- GÜVENLİK:
--   - Sabit zamanlı hesaplama (no early exit)
--   - dont_touch sentez koruması
--   - Zeroize on kill_signal
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sha256_core is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        kill_signal  : in  std_logic;  -- Zeroize everything

        -- Control
        start        : in  std_logic;  -- Begin new hash (resets H to IV)
        last_block   : in  std_logic;  -- Current block is final

        -- Data input (32-bit words, 16 per block)
        data_in      : in  std_logic_vector(31 downto 0);
        data_valid   : in  std_logic;

        -- Hash output
        hash_out     : out std_logic_vector(255 downto 0);
        hash_valid   : out std_logic;

        -- Status
        busy         : out std_logic;
        ready        : out std_logic   -- Ready to accept data_in
    );
end sha256_core;

architecture Behavioral of sha256_core is

    -------------------------------------------------------------------------
    -- NIST FIPS 180-4, Section 4.2.2: SHA-256 Constants K0..K63
    -------------------------------------------------------------------------
    type k_rom_t is array (0 to 63) of std_logic_vector(31 downto 0);
    constant K_ROM : k_rom_t := (
        x"428a2f98", x"71374491", x"b5c0fbcf", x"e9b5dba5",
        x"3956c25b", x"59f111f1", x"923f82a4", x"ab1c5ed5",
        x"d807aa98", x"12835b01", x"243185be", x"550c7dc3",
        x"72be5d74", x"80deb1fe", x"9bdc06a7", x"c19bf174",
        x"e49b69c1", x"efbe4786", x"0fc19dc6", x"240ca1cc",
        x"2de92c6f", x"4a7484aa", x"5cb0a9dc", x"76f988da",
        x"983e5152", x"a831c66d", x"b00327c8", x"bf597fc7",
        x"c6e00bf3", x"d5a79147", x"06ca6351", x"14292967",
        x"27b70a85", x"2e1b2138", x"4d2c6dfc", x"53380d13",
        x"650a7354", x"766a0abb", x"81c2c92e", x"92722c85",
        x"a2bfe8a1", x"a81a664b", x"c24b8b70", x"c76c51a3",
        x"d192e819", x"d6990624", x"f40e3585", x"106aa070",
        x"19a4c116", x"1e376c08", x"2748774c", x"34b0bcb5",
        x"391c0cb3", x"4ed8aa4a", x"5b9cca4f", x"682e6ff3",
        x"748f82ee", x"78a5636f", x"84c87814", x"8cc70208",
        x"90befffa", x"a4506ceb", x"bef9a3f7", x"c67178f2"
    );

    -------------------------------------------------------------------------
    -- NIST FIPS 180-4, Section 5.3.3: Initial Hash Values H0
    -------------------------------------------------------------------------
    constant H0_INIT : std_logic_vector(31 downto 0) := x"6a09e667";
    constant H1_INIT : std_logic_vector(31 downto 0) := x"bb67ae85";
    constant H2_INIT : std_logic_vector(31 downto 0) := x"3c6ef372";
    constant H3_INIT : std_logic_vector(31 downto 0) := x"a54ff53a";
    constant H4_INIT : std_logic_vector(31 downto 0) := x"510e527f";
    constant H5_INIT : std_logic_vector(31 downto 0) := x"9b05688c";
    constant H6_INIT : std_logic_vector(31 downto 0) := x"1f83d9ab";
    constant H7_INIT : std_logic_vector(31 downto 0) := x"5be0cd19";

    -------------------------------------------------------------------------
    -- FSM
    -------------------------------------------------------------------------
    type state_t is (
        S_IDLE,        -- Bekle
        S_LOAD_MSG,    -- 16 word yükle (W0..W15)
        S_EXPAND,      -- W16..W63 genişlet
        S_COMPRESS,    -- 64 round sıkıştır
        S_UPDATE,      -- H += a,b,c,d,e,f,g,h
        S_DONE         -- hash_valid assert
    );
    signal state : state_t := S_IDLE;

    -------------------------------------------------------------------------
    -- Message Schedule W[0..63]
    -------------------------------------------------------------------------
    type w_mem_t is array (0 to 63) of std_logic_vector(31 downto 0);
    signal W : w_mem_t := (others => (others => '0'));
    signal w_idx : integer range 0 to 63 := 0;

    -------------------------------------------------------------------------
    -- Working Variables (a,b,c,d,e,f,g,h)
    -------------------------------------------------------------------------
    signal a, b, c, d, e, f, g, h : std_logic_vector(31 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- Hash State H0..H7 (accumulated across blocks)
    -------------------------------------------------------------------------
    signal H0, H1, H2, H3, H4, H5, H6, H7 : std_logic_vector(31 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- Internal signals
    -------------------------------------------------------------------------
    signal round_cnt   : integer range 0 to 63 := 0;
    signal word_cnt    : integer range 0 to 15 := 0;
    signal is_last     : std_logic := '0';
    signal expand_idx  : integer range 16 to 63 := 16;

    -------------------------------------------------------------------------
    -- Synthesis protection
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of a : signal is "true";
    attribute dont_touch of b : signal is "true";
    attribute dont_touch of c : signal is "true";
    attribute dont_touch of d : signal is "true";
    attribute dont_touch of e : signal is "true";
    attribute dont_touch of f : signal is "true";
    attribute dont_touch of g : signal is "true";
    attribute dont_touch of h : signal is "true";
    attribute dont_touch of H0 : signal is "true";
    attribute dont_touch of H7 : signal is "true";

    -------------------------------------------------------------------------
    -- SHA-256 Functions (FIPS 180-4, Section 4.1.2)
    -------------------------------------------------------------------------
    -- Right rotate
    function ROTR(x : std_logic_vector(31 downto 0); n : integer)
        return std_logic_vector is
    begin
        return x(n-1 downto 0) & x(31 downto n);
    end function;

    -- Right shift
    function SHR(x : std_logic_vector(31 downto 0); n : integer)
        return std_logic_vector is
    begin
        return (n-1 downto 0 => '0') & x(31 downto n);
    end function;

    -- Σ0 (big sigma 0): ROTR(2) XOR ROTR(13) XOR ROTR(22)
    function BSIG0(x : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return ROTR(x, 2) xor ROTR(x, 13) xor ROTR(x, 22);
    end function;

    -- Σ1 (big sigma 1): ROTR(6) XOR ROTR(11) XOR ROTR(25)
    function BSIG1(x : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return ROTR(x, 6) xor ROTR(x, 11) xor ROTR(x, 25);
    end function;

    -- σ0 (small sigma 0): ROTR(7) XOR ROTR(18) XOR SHR(3)
    function SSIG0(x : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return ROTR(x, 7) xor ROTR(x, 18) xor SHR(x, 3);
    end function;

    -- σ1 (small sigma 1): ROTR(17) XOR ROTR(19) XOR SHR(10)
    function SSIG1(x : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return ROTR(x, 17) xor ROTR(x, 19) xor SHR(x, 10);
    end function;

    -- Ch(e,f,g) = (e AND f) XOR (NOT e AND g)
    function CH(e_in, f_in, g_in : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return (e_in and f_in) xor ((not e_in) and g_in);
    end function;

    -- Maj(a,b,c) = (a AND b) XOR (a AND c) XOR (b AND c)
    function MAJ(a_in, b_in, c_in : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return (a_in and b_in) xor (a_in and c_in) xor (b_in and c_in);
    end function;

    -- 32-bit addition (modular)
    function ADD32(x, y : std_logic_vector(31 downto 0))
        return std_logic_vector is
    begin
        return std_logic_vector(unsigned(x) + unsigned(y));
    end function;

begin

    -------------------------------------------------------------------------
    -- Output assignments
    -------------------------------------------------------------------------
    hash_out <= H0 & H1 & H2 & H3 & H4 & H5 & H6 & H7;

    -------------------------------------------------------------------------
    -- Main FSM
    -------------------------------------------------------------------------
    process(clk)
        variable T1, T2 : std_logic_vector(31 downto 0);
        variable w_new  : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rst_n = '0' or kill_signal = '1' then
                -- ★ ZEROIZE: Kill signal → tüm state sıfırla
                state      <= S_IDLE;
                a <= (others => '0'); b <= (others => '0');
                c <= (others => '0'); d <= (others => '0');
                e <= (others => '0'); f <= (others => '0');
                g <= (others => '0'); h <= (others => '0');
                H0 <= (others => '0'); H1 <= (others => '0');
                H2 <= (others => '0'); H3 <= (others => '0');
                H4 <= (others => '0'); H5 <= (others => '0');
                H6 <= (others => '0'); H7 <= (others => '0');
                hash_valid <= '0';
                busy       <= '0';
                ready      <= '0';
                round_cnt  <= 0;
                word_cnt   <= 0;
                is_last    <= '0';
                expand_idx <= 16;
            else
                -- Default: clear single-cycle pulses
                hash_valid <= '0';

                case state is
                    -----------------------------------------------------------
                    -- IDLE: Wait for start
                    -----------------------------------------------------------
                    when S_IDLE =>
                        busy  <= '0';
                        ready <= '0';
                        if start = '1' then
                            -- Initialize H to IV (FIPS 180-4, §5.3.3)
                            H0 <= H0_INIT; H1 <= H1_INIT;
                            H2 <= H2_INIT; H3 <= H3_INIT;
                            H4 <= H4_INIT; H5 <= H5_INIT;
                            H6 <= H6_INIT; H7 <= H7_INIT;
                            busy     <= '1';
                            ready    <= '1';  -- Ready for W[0]
                            word_cnt <= 0;
                            is_last  <= '0';
                            state    <= S_LOAD_MSG;
                        end if;

                    -----------------------------------------------------------
                    -- LOAD_MSG: Receive 16 x 32-bit words (512-bit block)
                    -----------------------------------------------------------
                    when S_LOAD_MSG =>
                        ready <= '1';
                        if data_valid = '1' then
                            W(word_cnt) <= data_in;
                            if last_block = '1' then
                                is_last <= '1';
                            end if;
                            if word_cnt = 15 then
                                ready      <= '0';
                                expand_idx <= 16;
                                state      <= S_EXPAND;
                            else
                                word_cnt <= word_cnt + 1;
                            end if;
                        end if;

                    -----------------------------------------------------------
                    -- EXPAND: Compute W[16..63]
                    -- W[t] = σ1(W[t-2]) + W[t-7] + σ0(W[t-15]) + W[t-16]
                    -----------------------------------------------------------
                    when S_EXPAND =>
                        w_new := ADD32(
                                    ADD32(SSIG1(W(expand_idx-2)), W(expand_idx-7)),
                                    ADD32(SSIG0(W(expand_idx-15)), W(expand_idx-16))
                                 );
                        W(expand_idx) <= w_new;

                        if expand_idx = 63 then
                            -- Initialize working variables
                            a <= H0; b <= H1; c <= H2; d <= H3;
                            e <= H4; f <= H5; g <= H6; h <= H7;
                            round_cnt <= 0;
                            state     <= S_COMPRESS;
                        else
                            expand_idx <= expand_idx + 1;
                        end if;

                    -----------------------------------------------------------
                    -- COMPRESS: 64 rounds (FIPS 180-4, §6.2.2 step 3)
                    -- T1 = h + Σ1(e) + Ch(e,f,g) + K[t] + W[t]
                    -- T2 = Σ0(a) + Maj(a,b,c)
                    -- h=g, g=f, f=e, e=d+T1, d=c, c=b, b=a, a=T1+T2
                    -----------------------------------------------------------
                    when S_COMPRESS =>
                        T1 := ADD32(h,
                               ADD32(BSIG1(e),
                               ADD32(CH(e, f, g),
                               ADD32(K_ROM(round_cnt), W(round_cnt)))));
                        T2 := ADD32(BSIG0(a), MAJ(a, b, c));

                        h <= g;
                        g <= f;
                        f <= e;
                        e <= ADD32(d, T1);
                        d <= c;
                        c <= b;
                        b <= a;
                        a <= ADD32(T1, T2);

                        if round_cnt = 63 then
                            state <= S_UPDATE;
                        else
                            round_cnt <= round_cnt + 1;
                        end if;

                    -----------------------------------------------------------
                    -- UPDATE: H += working variables (FIPS 180-4, §6.2.2 step 4)
                    -----------------------------------------------------------
                    when S_UPDATE =>
                        H0 <= ADD32(H0, a); H1 <= ADD32(H1, b);
                        H2 <= ADD32(H2, c); H3 <= ADD32(H3, d);
                        H4 <= ADD32(H4, e); H5 <= ADD32(H5, f);
                        H6 <= ADD32(H6, g); H7 <= ADD32(H7, h);

                        if is_last = '1' then
                            state <= S_DONE;
                        else
                            -- More blocks: ready for next data
                            word_cnt <= 0;
                            ready    <= '1';
                            state    <= S_LOAD_MSG;
                        end if;

                    -----------------------------------------------------------
                    -- DONE: Hash complete
                    -----------------------------------------------------------
                    when S_DONE =>
                        hash_valid <= '1';
                        busy       <= '0';
                        state      <= S_IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
