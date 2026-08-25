--------------------------------------------------------------------------------
-- PROJECT TITAN V14: HMAC-SHA256 (RFC 2104 + FIPS 198-1)
-- Module: Keyed-Hash Message Authentication Code using SHA-256
--------------------------------------------------------------------------------
--
-- KİMSEYE GÜVENME: Heartbeat artık bir toggle değil.
-- Her heartbeat HMAC(key, nonce||counter) ile doğrulanır.
-- Replay saldırısı: counter monotonically artar.
--
-- HMAC(K, m) = H((K ^ opad) || H((K ^ ipad) || m))
--   K = 256-bit key (SHA-256 block = 512 bit = 64 byte → K padded with 0)
--   ipad = 0x36 x 64 bytes
--   opad = 0x5c x 64 bytes
--
-- TIMING: ~400 cycle total (4 SHA-256 blocks: ipad+msg, opad+hash)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity hmac_sha256 is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        kill_signal  : in  std_logic;

        -- Key (256-bit)
        key_in       : in  std_logic_vector(255 downto 0);

        -- Message (128-bit: nonce || counter)
        msg_in       : in  std_logic_vector(127 downto 0);

        -- Control
        start        : in  std_logic;

        -- Output: 256-bit HMAC tag
        hmac_out     : out std_logic_vector(255 downto 0);
        hmac_valid   : out std_logic;
        busy         : out std_logic
    );
end hmac_sha256;

architecture Behavioral of hmac_sha256 is

    -------------------------------------------------------------------------
    -- FSM — Simplified 2-phase approach
    -- Each "FEED" state: set data_valid for 1 cycle, then advance word index
    -------------------------------------------------------------------------
    type hmac_state_t is (
        H_IDLE,
        H_PREP,            -- Compute K^ipad, K^opad, start SHA
        H_WAIT_READY,      -- Wait for SHA ready
        H_FEED,            -- Feed one word (data_valid pulse)
        H_FEED_NEXT,       -- Advance index, decide what's next
        H_WAIT_HASH,       -- Wait for SHA hash_valid
        H_DONE
    );
    signal state : hmac_state_t := H_IDLE;

    -- Which phase are we in?
    type phase_t is (PHASE_INNER, PHASE_OUTER);
    signal phase : phase_t := PHASE_INNER;

    -- Which part of the block are we feeding?
    type feed_part_t is (PART_PAD, PART_MSG, PART_PADDING);
    signal feed_part : feed_part_t := PART_PAD;

    -------------------------------------------------------------------------
    -- SHA-256 Core Interface
    -------------------------------------------------------------------------
    signal sha_start      : std_logic := '0';
    signal sha_last_block : std_logic := '0';
    signal sha_data_in    : std_logic_vector(31 downto 0) := (others => '0');
    signal sha_data_valid : std_logic := '0';
    signal sha_hash_out   : std_logic_vector(255 downto 0);
    signal sha_hash_valid : std_logic;
    signal sha_busy       : std_logic;
    signal sha_ready      : std_logic;

    -------------------------------------------------------------------------
    -- Key pads (64 bytes = 16 words each)
    -------------------------------------------------------------------------
    type words16_t is array (0 to 15) of std_logic_vector(31 downto 0);
    signal k_ipad : words16_t := (others => (others => '0'));
    signal k_opad : words16_t := (others => (others => '0'));

    -------------------------------------------------------------------------
    -- Internal state
    -------------------------------------------------------------------------
    signal word_idx      : integer range 0 to 15 := 0;
    signal block_word_cnt: integer range 0 to 15 := 0; -- total words fed in current block
    signal inner_hash    : std_logic_vector(255 downto 0) := (others => '0');
    signal msg_latched   : std_logic_vector(127 downto 0) := (others => '0');
    signal busy_int      : std_logic := '0';
    signal is_block2     : std_logic := '0';  -- Are we on block 2?

    -- Sentez koruması
    attribute dont_touch : string;
    attribute dont_touch of inner_hash : signal is "true";

begin

    busy <= busy_int;

    -------------------------------------------------------------------------
    -- SHA-256 Core Instance
    -------------------------------------------------------------------------
    sha_inst : entity work.sha256_core
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => kill_signal,
            start       => sha_start,
            last_block  => sha_last_block,
            data_in     => sha_data_in,
            data_valid  => sha_data_valid,
            hash_out    => sha_hash_out,
            hash_valid  => sha_hash_valid,
            busy        => sha_busy,
            ready       => sha_ready
        );

    -------------------------------------------------------------------------
    -- Word data mux — determines what word to feed based on phase/part/index
    -------------------------------------------------------------------------
    process(phase, feed_part, word_idx, k_ipad, k_opad, msg_latched, inner_hash, block_word_cnt)
    begin
        sha_data_in <= (others => '0');  -- default

        if phase = PHASE_INNER then
            if feed_part = PART_PAD then
                -- Block 1: K ^ ipad (16 words)
                sha_data_in <= k_ipad(word_idx);
            elsif feed_part = PART_MSG then
                -- Block 2 words 0-3: message
                case word_idx is
                    when 0 => sha_data_in <= msg_latched(127 downto 96);
                    when 1 => sha_data_in <= msg_latched(95 downto 64);
                    when 2 => sha_data_in <= msg_latched(63 downto 32);
                    when 3 => sha_data_in <= msg_latched(31 downto 0);
                    when others => sha_data_in <= (others => '0');
                end case;
            elsif feed_part = PART_PADDING then
                -- Block 2 words 4-15: padding
                case word_idx is
                    when 0  => sha_data_in <= x"80000000";  -- padding bit
                    when 10 => sha_data_in <= x"00000000";  -- length hi
                    when 11 => sha_data_in <= x"00000280";  -- length = 640 bits
                    when others => sha_data_in <= x"00000000";
                end case;
            end if;
        else  -- PHASE_OUTER
            if feed_part = PART_PAD then
                -- Block 1: K ^ opad (16 words)
                sha_data_in <= k_opad(word_idx);
            elsif feed_part = PART_MSG then
                -- Block 2 words 0-7: inner hash
                if word_idx < 8 then
                    sha_data_in <= inner_hash(255 - word_idx*32 downto 224 - word_idx*32);
                end if;
            elsif feed_part = PART_PADDING then
                -- Block 2 words 8-15: padding
                case word_idx is
                    when 0  => sha_data_in <= x"80000000";
                    when 6  => sha_data_in <= x"00000000";  -- length hi
                    when 7  => sha_data_in <= x"00000300";  -- length = 768 bits
                    when others => sha_data_in <= x"00000000";
                end case;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- Main FSM — clean 2-phase word transfer
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' or kill_signal = '1' then
                state          <= H_IDLE;
                busy_int       <= '0';
                hmac_valid     <= '0';
                hmac_out       <= (others => '0');
                inner_hash     <= (others => '0');
                sha_start      <= '0';
                sha_data_valid <= '0';
                sha_last_block <= '0';
                word_idx       <= 0;
                block_word_cnt <= 0;
                is_block2      <= '0';
                phase          <= PHASE_INNER;
                feed_part      <= PART_PAD;
            else
                -- Default pulses
                sha_start      <= '0';
                sha_data_valid <= '0';
                sha_last_block <= '0';
                hmac_valid     <= '0';

                case state is
                    -----------------------------------------------------------
                    -- IDLE
                    -----------------------------------------------------------
                    when H_IDLE =>
                        busy_int <= '0';
                        if start = '1' then
                            busy_int    <= '1';
                            msg_latched <= msg_in;
                            phase       <= PHASE_INNER;
                            feed_part   <= PART_PAD;
                            is_block2   <= '0';

                            -- Compute K^ipad and K^opad
                            for i in 0 to 7 loop
                                k_ipad(i) <= key_in(255-i*32 downto 224-i*32) xor x"36363636";
                                k_opad(i) <= key_in(255-i*32 downto 224-i*32) xor x"5c5c5c5c";
                            end loop;
                            for i in 8 to 15 loop
                                k_ipad(i) <= x"36363636";
                                k_opad(i) <= x"5c5c5c5c";
                            end loop;

                            state <= H_PREP;
                        end if;

                    -----------------------------------------------------------
                    -- PREP: Start SHA-256
                    -----------------------------------------------------------
                    when H_PREP =>
                        sha_start      <= '1';
                        word_idx       <= 0;
                        block_word_cnt <= 0;
                        state          <= H_WAIT_READY;

                    -----------------------------------------------------------
                    -- WAIT_READY: Wait for SHA core to be ready
                    -----------------------------------------------------------
                    when H_WAIT_READY =>
                        if sha_ready = '1' then
                            state <= H_FEED;
                        end if;

                    -----------------------------------------------------------
                    -- FEED: Assert data_valid for one clock cycle
                    -----------------------------------------------------------
                    when H_FEED =>
                        sha_data_valid <= '1';
                        -- Set last_block on final word of final block
                        if block_word_cnt = 15 and is_block2 = '1' then
                            sha_last_block <= '1';
                        end if;
                        state <= H_FEED_NEXT;

                    -----------------------------------------------------------
                    -- FEED_NEXT: Advance counters, route to next action
                    -----------------------------------------------------------
                    when H_FEED_NEXT =>
                        if block_word_cnt = 15 then
                            -- Block complete
                            block_word_cnt <= 0;

                            if is_block2 = '1' then
                                -- Block 2 done → wait for hash
                                state <= H_WAIT_HASH;
                            else
                                -- Block 1 done → prepare block 2
                                is_block2 <= '1';
                                word_idx  <= 0;
                                if phase = PHASE_INNER then
                                    feed_part <= PART_MSG;
                                else
                                    feed_part <= PART_MSG;
                                end if;
                                -- SHA is processing block 1, wait for ready
                                state <= H_WAIT_READY;
                            end if;
                        else
                            -- More words in current block
                            block_word_cnt <= block_word_cnt + 1;
                            word_idx       <= word_idx + 1;

                            -- Check if we need to transition feed_part
                            if is_block2 = '1' then
                                if phase = PHASE_INNER then
                                    -- Inner block 2: 4 MSG + 12 PAD
                                    if feed_part = PART_MSG and word_idx = 3 then
                                        feed_part <= PART_PADDING;
                                        word_idx  <= 0;
                                    end if;
                                else
                                    -- Outer block 2: 8 HASH + 8 PAD
                                    if feed_part = PART_MSG and word_idx = 7 then
                                        feed_part <= PART_PADDING;
                                        word_idx  <= 0;
                                    end if;
                                end if;
                            end if;

                            -- Wait for SHA ready before feeding next word
                            state <= H_WAIT_READY;
                        end if;

                    -----------------------------------------------------------
                    -- WAIT_HASH: Wait for SHA hash_valid
                    -----------------------------------------------------------
                    when H_WAIT_HASH =>
                        if sha_hash_valid = '1' then
                            if phase = PHASE_INNER then
                                -- Store inner hash, switch to outer
                                inner_hash <= sha_hash_out;
                                phase      <= PHASE_OUTER;
                                feed_part  <= PART_PAD;
                                is_block2  <= '0';
                                word_idx   <= 0;
                                state      <= H_PREP;
                            else
                                -- Outer hash = HMAC result
                                hmac_out   <= sha_hash_out;
                                hmac_valid <= '1';
                                state      <= H_DONE;
                            end if;
                        end if;

                    -----------------------------------------------------------
                    -- DONE
                    -----------------------------------------------------------
                    when H_DONE =>
                        busy_int <= '0';
                        state    <= H_IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
