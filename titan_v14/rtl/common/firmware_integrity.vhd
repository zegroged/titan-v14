--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Firmware Integrity Guard — SHA-256 Implementation
-- Module: Bitstream/Config Integrity Verification Against eFuse Golden Hash
--------------------------------------------------------------------------------
--
-- P3-11 UPGRADE: CRC-32 → SHA-256 (NIST FIPS 180-4)
--
-- KİMSEYE GÜVENME:
--   CRC-32 sadece iletim hatası tespitiydi.
--   SHA-256 kriptografik hash → kasıtlı tamper tespiti.
--   Golden hash eFuse'a yakılır — değiştirilemez.
--
-- YÖNTEM:
--   1. Config belleğinden HASH_WORDS adet 32-bit word oku
--   2. Her word'ü SHA-256'ya besle: SHA(addr[0] || data[0] || addr[1] || data[1] || ...)
--   3. Son word'ten sonra SHA-256 padding tamamla
--   4. hash_out vs golden_hash: sabit zamanlı karşılaştırma
--
-- GÜVENLİK:
--   - fail_latch rst_n ile bile temizlenemez (kalıcı fail)
--   - Adres dahil edilerek config reorder saldırısına karşı koruma
--   - 256-bit hash → 2^128 collision resistance
--   - Sabit zamanlı karşılaştırma (timing side-channel koruması)
--   - dont_touch sentez koruması
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity firmware_integrity is
    generic (
        HASH_WORDS : integer := 256  -- Kontrol edilecek word sayısı
    );
    port (
        clk              : in  std_logic;
        rst_n            : in  std_logic;

        -- Kontrol
        start            : in  std_logic;    -- POST'tan tetik

        -- eFuse golden hash (SHA-256, manufacturing sırasında yakılır)
        golden_hash      : in  std_logic_vector(255 downto 0);

        -- Config bellek arayüzü (ICAP/MCAP)
        cfg_addr         : out std_logic_vector(15 downto 0);
        cfg_data         : in  std_logic_vector(31 downto 0);
        cfg_valid        : in  std_logic;
        cfg_read_req     : out std_logic;

        -- Sonuç
        integrity_pass   : out std_logic;    -- '1' = Hash eşleşti
        integrity_fail   : out std_logic;    -- '1' = TAMPER (latched!)
        busy             : out std_logic     -- '1' = Hesaplama devam ediyor
    );
end firmware_integrity;

architecture Behavioral of firmware_integrity is

    -------------------------------------------------------------------------
    -- FSM
    -------------------------------------------------------------------------
    type state_t is (
        IDLE,
        HASH_INIT,       -- SHA-256 core'u başlat (start pulse)
        HASH_READ,       -- Config belleğinden okuma talebi
        HASH_WAIT,       -- Config bellek cevabını bekle
        HASH_FEED_ADDR,  -- Adres word'ünü SHA'ya besle
        HASH_FEED_DATA,  -- Data word'ünü SHA'ya besle
        HASH_FEED_ACK,   -- SHA'nın word'ü kabul etmesini bekle
        HASH_PAD_PREP,   -- Son blok padding hazırlığı
        HASH_PAD_FEED,   -- Padding word'lerini besle
        HASH_PAD_ACK,    -- SHA padding ACK bekle
        HASH_WAIT_DONE,  -- SHA hash_valid bekle
        HASH_COMPARE,    -- Golden hash ile karşılaştır
        PASS_STATE,
        FAIL_STATE
    );
    signal state : state_t := IDLE;

    -------------------------------------------------------------------------
    -- Counters
    -------------------------------------------------------------------------
    signal word_counter  : integer range 0 to HASH_WORDS := 0;
    signal addr_counter  : unsigned(15 downto 0) := (others => '0');
    signal fail_latch    : std_logic := '0';

    -- Padding state
    signal block_word_cnt : integer range 0 to 15 := 0;  -- 16 words per SHA block
    signal total_words    : integer range 0 to 2048 := 0; -- Total words fed to SHA
    signal pad_idx        : integer range 0 to 31 := 0;  -- V14.3 FIX: was 0-15, overflow on large blocks
    signal is_last_block  : std_logic := '0';

    -- Data latch
    signal data_latched  : std_logic_vector(31 downto 0) := (others => '0');

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
    -- Sentez koruması
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of fail_latch : signal is "true";

begin

    integrity_fail <= fail_latch;

    -------------------------------------------------------------------------
    -- SHA-256 Core Instance
    -------------------------------------------------------------------------
    sha_inst : entity work.sha256_core
        port map (
            clk         => clk,
            rst_n       => rst_n,
            kill_signal => '0',  -- FI doesn't use kill (fail_latch is separate)
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
    -- Main FSM
    -------------------------------------------------------------------------
    fsm_proc: process(clk)
        variable compare_xor : std_logic_vector(255 downto 0);
        variable mismatch    : std_logic;
        -- Padding calculation:
        -- Total message bits = total_words * 32
        -- Need padding: 1-bit + zeros + 64-bit length
        -- Words remaining in current block after last data word
        variable words_in_block : integer;
        variable total_bits     : unsigned(63 downto 0);
        variable pad_words_needed : integer;
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state          <= IDLE;
                word_counter   <= 0;
                addr_counter   <= (others => '0');
                integrity_pass <= '0';
                busy           <= '0';
                cfg_read_req   <= '0';
                cfg_addr       <= (others => '0');
                sha_start      <= '0';
                sha_data_valid <= '0';
                sha_last_block <= '0';
                block_word_cnt <= 0;
                total_words    <= 0;
                pad_idx        <= 0;
                is_last_block  <= '0';
                -- fail_latch NOT reset — kalıcı!
            else
                -- Default pulses
                sha_start      <= '0';
                sha_data_valid <= '0';
                sha_last_block <= '0';
                cfg_read_req   <= '0';

                case state is
                    -------------------------------------------------------
                    -- IDLE
                    -------------------------------------------------------
                    when IDLE =>
                        busy <= '0';
                        if start = '1' and fail_latch = '0' then
                            state <= HASH_INIT;
                        end if;

                    -------------------------------------------------------
                    -- HASH_INIT: Start SHA-256 core
                    -------------------------------------------------------
                    when HASH_INIT =>
                        sha_start      <= '1';
                        word_counter   <= 0;
                        addr_counter   <= (others => '0');
                        block_word_cnt <= 0;
                        total_words    <= 0;
                        busy           <= '1';
                        integrity_pass <= '0';
                        is_last_block  <= '0';
                        state          <= HASH_READ;

                    -------------------------------------------------------
                    -- HASH_READ: Config belleğinden okuma talebi
                    -------------------------------------------------------
                    when HASH_READ =>
                        cfg_addr     <= std_logic_vector(addr_counter);
                        cfg_read_req <= '1';
                        state        <= HASH_WAIT;

                    -------------------------------------------------------
                    -- HASH_WAIT: Config bellek cevabını bekle
                    -------------------------------------------------------
                    when HASH_WAIT =>
                        if cfg_valid = '1' then
                            data_latched <= cfg_data;
                            state <= HASH_FEED_ADDR;
                        end if;

                    -------------------------------------------------------
                    -- HASH_FEED_ADDR: Adres word'ünü SHA'ya besle
                    -- (position binding: reorder attack koruması)
                    -------------------------------------------------------
                    when HASH_FEED_ADDR =>
                        if sha_ready = '1' then
                            sha_data_in    <= x"0000" & std_logic_vector(addr_counter);
                            sha_data_valid <= '1';
                            state          <= HASH_FEED_ACK;
                        end if;

                    -------------------------------------------------------
                    -- HASH_FEED_ACK: SHA akbul sonrası yönlendir
                    -------------------------------------------------------
                    when HASH_FEED_ACK =>
                        -- Address word was just sent, now send data
                        block_word_cnt <= block_word_cnt + 1;
                        total_words    <= total_words + 1;

                        -- Did we complete a 16-word block?
                        if block_word_cnt = 15 then
                            block_word_cnt <= 0;
                        end if;

                        state <= HASH_FEED_DATA;

                    -------------------------------------------------------
                    -- HASH_FEED_DATA: Data word'ünü SHA'ya besle
                    -------------------------------------------------------
                    when HASH_FEED_DATA =>
                        if sha_ready = '1' then
                            sha_data_in    <= data_latched;
                            sha_data_valid <= '1';

                            -- Update counters
                            total_words    <= total_words + 1;
                            word_counter   <= word_counter + 1;
                            addr_counter   <= addr_counter + 1;

                            -- Block word counter: wrap at 15 to avoid range overflow
                            if block_word_cnt = 15 then
                                block_word_cnt <= 0;
                            else
                                block_word_cnt <= block_word_cnt + 1;
                            end if;

                            if word_counter = HASH_WORDS - 1 then
                                -- All words read → prepare padding
                                state <= HASH_PAD_PREP;
                            else
                                -- More words to read
                                state <= HASH_READ;
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- HASH_PAD_PREP: Calculate padding
                    -- Message = HASH_WORDS * 2 words (addr+data each)
                    -- Total bits = total_words * 32
                    -- Padding: 0x80000000 + zeros + length (2 words)
                    -------------------------------------------------------
                    when HASH_PAD_PREP =>
                        pad_idx <= 0;
                        -- Calculate how many pad words to fill current block
                        -- We need: 1 (0x80) + zeros + 2 (length) to end on block boundary
                        -- Words remaining in current block:
                        --   16 - block_word_cnt
                        -- If remaining >= 3 (0x80 + len_hi + len_lo): pad this block
                        -- If remaining < 3: pad this block with zeros, then full next block
                        
                        -- For simplicity: just feed padding words until we hit
                        -- a block boundary with length at the end
                        is_last_block <= '0';
                        state <= HASH_PAD_FEED;

                    -------------------------------------------------------
                    -- HASH_PAD_FEED: Feed padding words
                    -- Block 2 layout: 0x80000000, zeros, length_hi, length_lo
                    -------------------------------------------------------
                    when HASH_PAD_FEED =>
                        if sha_ready = '1' then
                            -- Determine what to write
                            if pad_idx = 0 then
                                -- First padding word: 0x80000000
                                sha_data_in <= x"80000000";
                            elsif block_word_cnt = 14 then
                                -- Length hi (always 0 for our message sizes)
                                sha_data_in <= (others => '0');
                            elsif block_word_cnt = 15 then
                                -- Length lo: total_words * 32 bits
                                -- total_words is at most ~512*2 = 1024
                                -- 1024 * 32 = 32768 = 0x8000
                                sha_data_in <= std_logic_vector(
                                    to_unsigned(total_words * 32, 32)
                                );
                                sha_last_block <= '1';
                                is_last_block  <= '1';
                            else
                                -- Zero padding
                                sha_data_in <= (others => '0');
                            end if;

                            sha_data_valid <= '1';
                            pad_idx        <= pad_idx + 1;

                            -- Block word counter: wrap at 15 to avoid range overflow
                            if block_word_cnt = 15 then
                                block_word_cnt <= 0;
                            else
                                block_word_cnt <= block_word_cnt + 1;
                            end if;

                            state <= HASH_PAD_ACK;
                        end if;

                    -------------------------------------------------------
                    -- HASH_PAD_ACK: Decide next padding action
                    -------------------------------------------------------
                    when HASH_PAD_ACK =>
                        if is_last_block = '1' then
                            -- All padding sent, wait for hash
                            state <= HASH_WAIT_DONE;
                        else
                            -- More padding to send
                            state <= HASH_PAD_FEED;
                        end if;

                    -------------------------------------------------------
                    -- HASH_WAIT_DONE: Wait for SHA-256 hash_valid
                    -------------------------------------------------------
                    when HASH_WAIT_DONE =>
                        if sha_hash_valid = '1' then
                            state <= HASH_COMPARE;
                        end if;

                    -------------------------------------------------------
                    -- HASH_COMPARE: Constant-time 256-bit comparison
                    -- ★ Kimseye Güvenme: XOR + OR reduction
                    -------------------------------------------------------
                    when HASH_COMPARE =>
                        compare_xor := sha_hash_out xor golden_hash;

                        -- OR reduction: any bit difference → mismatch
                        mismatch := '0';
                        for i in 0 to 255 loop
                            mismatch := mismatch or compare_xor(i);
                        end loop;

                        if mismatch = '0' then
                            integrity_pass <= '1';
                            state <= PASS_STATE;
                        else
                            fail_latch <= '1';   -- GERİ DÖNÜŞSÜZ!
                            state <= FAIL_STATE;
                        end if;

                    -------------------------------------------------------
                    -- PASS_STATE
                    -------------------------------------------------------
                    when PASS_STATE =>
                        busy <= '0';
                        -- PASS durumda kalır (tek seferlik kontrol)

                    -------------------------------------------------------
                    -- FAIL_STATE
                    -------------------------------------------------------
                    when FAIL_STATE =>
                        busy <= '0';
                        -- FAIL durumda kalır — fail_latch kalıcı → KILL zinciri

                end case;
            end if;
        end if;
    end process;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI — P3-11 SHA-256 Upgrade
--------------------------------------------------------------------------------
-- 1. TEK SEFERLİK: POST sırasında bir kez çalışır, sonuç latched
-- 2. FAIL_LATCH: rst_n bile temizleyemez — sadece güç kesme
-- 3. SHA-256 METODU: NIST FIPS 180-4
--    - 256-bit hash → 2^128 collision resistance
--    - Kasıtlı tamper tespiti (CRC-32 sadece iletim hatası için)
--    - Adres dahil edilerek word reorder saldırıları engellenir
-- 4. SABİT ZAMANLI KARŞILAŞTIRMA:
--    - XOR + OR reduction (timing side-channel koruması)
--    - Tüm 256 bit karşılaştırılır (CRC-32'de sadece 64 bit idi)
-- 5. KONFİG OKUMA: ICAP (Xilinx) veya MCAP (PolarFire) primitives
-- 6. GOLDEN HASH: Manufacturing sırasında eFuse'a yakılır (tüm 256 bit)
-- 7. BAĞLANTI: Entity port imzası değişmedi (drop-in replacement)
--------------------------------------------------------------------------------
