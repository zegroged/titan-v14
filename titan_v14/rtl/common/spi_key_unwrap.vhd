--------------------------------------------------------------------------------
-- PROJECT TITAN V14.1: SPI Key Unwrap (Encrypted Key Transfer)
-- Module: AES-based Transport Key Protocol — Decrypt SPI key blob
--------------------------------------------------------------------------------
-- PROTOKOL (§3.9 Mimari Doküman):
--
--   1. Host → Nonce (128-bit rastgele)
--   2. FPGA: Session Key türetimi:
--        SK_hi = AES-ECB(Transport_Key, Nonce)
--        SK_lo = AES-ECB(Transport_Key, Nonce XOR x"01")
--        Session_Key = SK_hi & SK_lo (256-bit)
--   3. Host → Encrypted Key = AES-CTR(Session_Key, Real_Key)
--   4. FPGA: AES-CTR decrypt:
--        Key_hi = Enc_hi XOR AES-ECB(Session_Key, IV=x"00")
--        Key_lo = Enc_lo XOR AES-ECB(Session_Key, IV=x"01")
--        Plain_Key = Key_hi & Key_lo
--
-- KAYNAK: ~900 LUT (dedicated aes256_core instance)
-- LATENCY: ~4 × 400 cycle = ~1600 cycle (~32 µs @ 50 MHz)
--
-- GÜVENLİK:
--   - Transport Key asla SPI'da görünmez (eFUSE/constant)
--   - Session Key her transferde farklı (nonce-based)
--   - Plain key asla SPI'da görünmez
--   - kill_signal → tüm ara değerler anında silinir
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_key_unwrap is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        kill_signal     : in  std_logic;

        -- Transport Key (eFUSE'dan — constant placeholder)
        transport_key   : in  std_logic_vector(255 downto 0);

        -- TRNG mask for AES (byte-uniform)
        trng_mask       : in  std_logic_vector(127 downto 0);

        -- Nonce from SPI (Phase A)
        nonce_in        : in  std_logic_vector(127 downto 0);
        nonce_valid     : in  std_logic;

        -- Encrypted key from SPI (Phase B)
        enc_key_in      : in  std_logic_vector(255 downto 0);
        enc_key_valid   : in  std_logic;

        -- Decrypted key output
        plain_key_out   : out std_logic_vector(255 downto 0);
        key_ready       : out std_logic;

        -- Error output
        unwrap_fail     : out std_logic;

        -- Status
        busy            : out std_logic
    );
end entity spi_key_unwrap;

architecture rtl of spi_key_unwrap is

    ---------------------------------------------------------------------------
    -- FSM
    ---------------------------------------------------------------------------
    type unwrap_fsm_t is (
        UW_IDLE,
        -- Session Key derivation (2 AES operations)
        UW_SK_HI_LOAD_KEY,      -- Load Transport Key into AES
        UW_SK_HI_START,         -- AES-ECB(TK, Nonce) → SK upper
        UW_SK_HI_WAIT,          -- Wait for AES done
        UW_SK_LO_START,         -- AES-ECB(TK, Nonce XOR 0x01) → SK lower
        UW_SK_LO_WAIT,          -- Wait for AES done
        -- Key decryption (2 AES operations, key changes to SK)
        UW_DEC_WAIT_ENC,        -- Wait for encrypted key from SPI
        UW_DEC_LOAD_SK,         -- Load Session Key into AES
        UW_DEC_HI_START,        -- AES-ECB(SK, IV=0x00) → keystream hi
        UW_DEC_HI_WAIT,         -- Wait for AES done
        UW_DEC_LO_START,        -- AES-ECB(SK, IV=0x01) → keystream lo
        UW_DEC_LO_WAIT,         -- Wait for AES done
        UW_DONE,                -- Output ready
        UW_FAIL                 -- Timeout / error
    );
    signal fsm : unwrap_fsm_t;

    ---------------------------------------------------------------------------
    -- Internal registers
    ---------------------------------------------------------------------------
    signal nonce_reg    : std_logic_vector(127 downto 0);
    signal enc_key_reg  : std_logic_vector(255 downto 0);
    signal session_key  : std_logic_vector(255 downto 0);
    signal plain_key    : std_logic_vector(255 downto 0);

    -- AES interface signals
    signal aes_key_in    : std_logic_vector(255 downto 0);
    signal aes_key_load  : std_logic;
    signal aes_pt_in     : std_logic_vector(127 downto 0);
    signal aes_start     : std_logic;
    signal aes_ct_out    : std_logic_vector(127 downto 0);
    signal aes_done      : std_logic;
    signal aes_busy      : std_logic;
    signal aes_fault     : std_logic;

    -- Timeout counter (~10000 cycles = 200 µs max per operation)
    signal timeout_cnt   : unsigned(15 downto 0);
    constant TIMEOUT_MAX : unsigned(15 downto 0) := x"FFFF";  -- ~1.3 ms

    -- Keep attributes for security
    attribute dont_touch : string;
    attribute dont_touch of session_key : signal is "true";
    attribute dont_touch of plain_key   : signal is "true";
    attribute dont_touch of nonce_reg   : signal is "true";

begin

    ---------------------------------------------------------------------------
    -- Dedicated AES-256 Core Instance (ENCRYPT only)
    ---------------------------------------------------------------------------
    u_aes : entity work.aes256_core
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => kill_signal,
            key_in         => aes_key_in,
            key_load       => aes_key_load,
            plaintext      => aes_pt_in,
            start          => aes_start,
            ciphertext     => aes_ct_out,
            done           => aes_done,
            busy           => aes_busy,
            trng_mask      => trng_mask,
            fault_detected => aes_fault
        );

    ---------------------------------------------------------------------------
    -- Main FSM
    ---------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            -- ★ EMERGENCY ZEROIZE
            fsm          <= UW_IDLE;
            nonce_reg    <= (others => '0');
            enc_key_reg  <= (others => '0');
            session_key  <= (others => '0');
            plain_key    <= (others => '0');
            aes_key_load <= '0';
            aes_start    <= '0';
            aes_key_in   <= (others => '0');
            aes_pt_in    <= (others => '0');
            timeout_cnt  <= (others => '0');

        elsif rising_edge(clk) then
            if rst_n = '0' then
                fsm          <= UW_IDLE;
                nonce_reg    <= (others => '0');
                enc_key_reg  <= (others => '0');
                session_key  <= (others => '0');
                plain_key    <= (others => '0');
                aes_key_load <= '0';
                aes_start    <= '0';
                timeout_cnt  <= (others => '0');
            else
                -- Default: deassert one-shot signals
                aes_key_load <= '0';
                aes_start    <= '0';

                case fsm is

                    -- =============================================================
                    -- IDLE: Wait for nonce
                    -- =============================================================
                    when UW_IDLE =>
                        timeout_cnt <= (others => '0');
                        if nonce_valid = '1' then
                            nonce_reg <= nonce_in;
                            fsm       <= UW_SK_HI_LOAD_KEY;
                        end if;

                    -- =============================================================
                    -- SESSION KEY DERIVATION: SK = AES(TK, Nonce) & AES(TK, Nonce^1)
                    -- =============================================================

                    -- Load Transport Key into AES (key_load stores key, stays IDLE)
                    when UW_SK_HI_LOAD_KEY =>
                        aes_key_in   <= transport_key;
                        aes_key_load <= '1';
                        fsm          <= UW_SK_HI_START;
                        timeout_cnt  <= (others => '0');

                    -- Start: AES-ECB(TK, Nonce) → SK upper half
                    when UW_SK_HI_START =>
                        aes_pt_in   <= nonce_reg;
                        aes_start   <= '1';
                        fsm         <= UW_SK_HI_WAIT;
                        timeout_cnt <= (others => '0');

                    -- Wait for AES done
                    when UW_SK_HI_WAIT =>
                        timeout_cnt <= timeout_cnt + 1;
                        if aes_done = '1' then
                            session_key(255 downto 128) <= aes_ct_out;
                            fsm <= UW_SK_LO_START;
                            timeout_cnt <= (others => '0');
                        elsif aes_fault = '1' or timeout_cnt = TIMEOUT_MAX then
                            fsm <= UW_FAIL;
                        end if;

                    -- Start: AES-ECB(TK, Nonce XOR 0x01) → SK lower half
                    when UW_SK_LO_START =>
                        aes_pt_in   <= nonce_reg xor
                                       (127 downto 1 => '0') & '1';
                        aes_start   <= '1';
                        fsm         <= UW_SK_LO_WAIT;

                    -- Wait for AES done
                    when UW_SK_LO_WAIT =>
                        timeout_cnt <= timeout_cnt + 1;
                        if aes_done = '1' then
                            session_key(127 downto 0) <= aes_ct_out;
                            -- Now wait for encrypted key from SPI
                            fsm         <= UW_DEC_WAIT_ENC;
                            timeout_cnt <= (others => '0');
                        elsif aes_fault = '1' or timeout_cnt = TIMEOUT_MAX then
                            fsm <= UW_FAIL;
                        end if;

                    -- =============================================================
                    -- KEY DECRYPTION: Key = EncKey XOR AES-CTR(SK, IV)
                    -- =============================================================

                    -- Wait for encrypted key from SPI
                    when UW_DEC_WAIT_ENC =>
                        timeout_cnt <= timeout_cnt + 1;
                        if enc_key_valid = '1' then
                            enc_key_reg  <= enc_key_in;
                            fsm          <= UW_DEC_LOAD_SK;
                            timeout_cnt  <= (others => '0');
                        elsif timeout_cnt = TIMEOUT_MAX then
                            fsm <= UW_FAIL;
                        end if;

                    -- Load Session Key into AES (key_load stores key, stays IDLE)
                    when UW_DEC_LOAD_SK =>
                        aes_key_in   <= session_key;
                        aes_key_load <= '1';
                        fsm          <= UW_DEC_HI_START;

                    -- AES-ECB(SK, IV=0x00) → keystream hi
                    when UW_DEC_HI_START =>
                        aes_pt_in   <= (others => '0');  -- IV = 0
                        aes_start   <= '1';
                        fsm         <= UW_DEC_HI_WAIT;
                        timeout_cnt <= (others => '0');

                    when UW_DEC_HI_WAIT =>
                        timeout_cnt <= timeout_cnt + 1;
                        if aes_done = '1' then
                            -- XOR encrypted key with keystream
                            plain_key(255 downto 128) <=
                                enc_key_reg(255 downto 128) xor aes_ct_out;
                            fsm         <= UW_DEC_LO_START;
                            timeout_cnt <= (others => '0');
                        elsif aes_fault = '1' or timeout_cnt = TIMEOUT_MAX then
                            fsm <= UW_FAIL;
                        end if;

                    -- AES-ECB(SK, IV=0x01) → keystream lo
                    when UW_DEC_LO_START =>
                        aes_pt_in   <= (127 downto 1 => '0') & '1';  -- IV = 1
                        aes_start   <= '1';
                        fsm         <= UW_DEC_LO_WAIT;

                    when UW_DEC_LO_WAIT =>
                        timeout_cnt <= timeout_cnt + 1;
                        if aes_done = '1' then
                            plain_key(127 downto 0) <=
                                enc_key_reg(127 downto 0) xor aes_ct_out;
                            fsm <= UW_DONE;
                        elsif aes_fault = '1' or timeout_cnt = TIMEOUT_MAX then
                            fsm <= UW_FAIL;
                        end if;

                    -- =============================================================
                    -- DONE / FAIL
                    -- =============================================================
                    when UW_DONE =>
                        -- Stay here until next nonce restarts cycle
                        if nonce_valid = '1' then
                            nonce_reg   <= nonce_in;
                            session_key <= (others => '0');  -- Zeroize old SK
                            fsm         <= UW_SK_HI_LOAD_KEY;
                        end if;

                    when UW_FAIL =>
                        -- Zeroize everything on failure
                        session_key <= (others => '0');
                        plain_key   <= (others => '0');
                        enc_key_reg <= (others => '0');
                        -- Stay failed until explicit reset
                        null;

                end case;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- OUTPUT ASSIGNMENTS
    ---------------------------------------------------------------------------
    plain_key_out <= plain_key;
    key_ready     <= '1' when fsm = UW_DONE else '0';
    unwrap_fail   <= '1' when fsm = UW_FAIL else '0';
    busy          <= '0' when fsm = UW_IDLE or fsm = UW_DONE or fsm = UW_FAIL
                     else '1';

end architecture rtl;
