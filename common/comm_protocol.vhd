--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Secure Communication Protocol V2
-- Module: Full-Duplex, Multi-Block Encrypted Communication
--------------------------------------------------------------------------------
-- V2 YENİLİKLER:
--   1. FULL-DUPLEX: TX ve RX bağımsız FSM'ler → eşzamanlı şifrele + çöz
--   2. MULTI-BLOCK: 16-byte sabit yerine 1-16 blok (16-256 byte payload)
--   3. AES ARBITRATION: TX ve RX AES'i sırayla paylaşır (round-robin)
--
-- WIRE FORMAT v2 (BLACK UART üzerinden):
--   [SOF: 0xAA55AA55] [SEQ: 4 byte] [NBLK: 1 byte] [CT: N*16 byte] [MAC: 16]
--   NBLK = 1..16 (kaç adet 16-byte blok)
--   MAC hesabı: CBC-MAC tüm bloklar üzerinden (chained)
--
-- TX: PC→RED_UART→Encrypt→BLACK_UART→Kablo (TX FSM)
-- RX: Kablo→BLACK_UART→Decrypt+Verify→RED_UART→PC (RX FSM)
-- Her iki yön aynı anda çalışabilir.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity comm_protocol is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;       -- Pipeline guillotine
        kill_signal     : in  std_logic;       -- Async tamper wipe
        mode            : in  std_logic;       -- '0'=TX only, '1'=RX only
                                               -- (Full-duplex: connect both)
        
        -----------------------------------------------------------------------
        -- RED SIDE (Plaintext — PC interface)
        -----------------------------------------------------------------------
        red_rx_byte     : in  std_logic_vector(7 downto 0);   -- RED UART'tan
        red_rx_valid    : in  std_logic;
        red_tx_byte     : out std_logic_vector(7 downto 0);   -- RED UART'a
        red_tx_start    : out std_logic;
        red_tx_busy     : in  std_logic;
        
        -----------------------------------------------------------------------
        -- BLACK SIDE (Ciphertext — Encrypted channel)
        -----------------------------------------------------------------------
        blk_rx_byte     : in  std_logic_vector(7 downto 0);   -- BLACK UART'tan
        blk_rx_valid    : in  std_logic;
        blk_tx_byte     : out std_logic_vector(7 downto 0);   -- BLACK UART'a
        blk_tx_start    : out std_logic;
        blk_tx_busy     : in  std_logic;
        
        -----------------------------------------------------------------------
        -- AES ENGINE INTERFACE
        -----------------------------------------------------------------------
        aes_pt_out      : out std_logic_vector(127 downto 0);  -- Plaintext → AES
        aes_pt_valid    : out std_logic;                        -- AES trigger
        aes_ct_in       : in  std_logic_vector(127 downto 0);  -- AES → Ciphertext
        aes_ct_valid    : in  std_logic;                        -- AES done
        
        -----------------------------------------------------------------------
        -- KEY/IV INTERFACE
        -----------------------------------------------------------------------
        derived_iv      : in  std_logic_vector(127 downto 0);  -- Key'den türetilmiş IV
        
        -----------------------------------------------------------------------
        -- STATUS
        -----------------------------------------------------------------------
        session_active  : out std_logic;       -- İletişim aktif
        mac_error       : out std_logic;       -- MAC doğrulama hatası (RX)
        frame_error     : out std_logic        -- SOF / SeqNum hatası (RX)
    );
end comm_protocol;

architecture Behavioral of comm_protocol is

    -------------------------------------------------------------------------
    -- PROTOKOL SABİTLERİ
    -------------------------------------------------------------------------
    constant SOF_MARKER : std_logic_vector(31 downto 0) := x"AA55AA55";
    constant MAX_BLOCKS : integer := 16;  -- 16 blok × 16 byte = 256 byte max
    
    -------------------------------------------------------------------------
    -- TX FSM (Bağımsız)
    -------------------------------------------------------------------------
    type tx_state_type is (
        TX_IDLE,
        TX_COLLECT,         -- RED UART'tan byte topla (1-16 blok)
        TX_ENCRYPT,         -- Mevcut bloğu AES'e gönder
        TX_WAIT_AES,        -- AES sonucu bekle
        TX_MAC_UPDATE,      -- CBC-MAC update (blok XOR → AES)
        TX_WAIT_MAC,        -- MAC AES sonucu bekle
        TX_NEXT_BLOCK,      -- Sonraki blok var mı?
        TX_SEND_SOF,        -- SOF marker gönder (4 byte)
        TX_SEND_SEQ,        -- SeqNum gönder (4 byte)
        TX_SEND_NBLK,       -- Block count gönder (1 byte)
        TX_SEND_CT,         -- Tüm ciphertext blokları gönder
        TX_SEND_MAC,        -- MAC gönder (16 byte)
        TX_DONE             -- Temizle
    );
    signal tx_state : tx_state_type := TX_IDLE;
    
    -------------------------------------------------------------------------
    -- RX FSM (Bağımsız)
    -------------------------------------------------------------------------
    type rx_state_type is (
        RX_IDLE,
        RX_SYNC,            -- SOF marker ara
        RX_SEQ,             -- SeqNum oku (4 byte)
        RX_NBLK,            -- Block count oku (1 byte)
        RX_COLLECT_CT,      -- Ciphertext topla (N*16 byte)
        RX_DECRYPT,         -- Mevcut bloğu AES ile çöz
        RX_WAIT_AES,        -- AES sonucu bekle
        RX_MAC_UPDATE,      -- CBC-MAC update
        RX_WAIT_MAC,        -- MAC AES sonucu bekle
        RX_NEXT_BLOCK,      -- Sonraki blok var mı?
        RX_COLLECT_MAC,     -- MAC oku (16 byte)
        RX_CHECK_MAC,       -- MAC karşılaştır
        RX_OUTPUT,          -- Plaintext → RED UART
        RX_DONE             -- Temizle
    );
    signal rx_state : rx_state_type := RX_IDLE;
    
    -------------------------------------------------------------------------
    -- AES ARBITRATION (TX vs RX round-robin)
    -------------------------------------------------------------------------
    signal aes_owner    : std_logic := '0';  -- '0'=TX, '1'=RX
    signal tx_aes_req   : std_logic := '0';
    signal rx_aes_req   : std_logic := '0';
    signal tx_aes_grant : std_logic := '0';
    signal rx_aes_grant : std_logic := '0';
    
    -- Per-FSM AES interface (muxed to actual port)
    signal tx_aes_pt    : std_logic_vector(127 downto 0) := (others => '0');
    signal tx_aes_valid : std_logic := '0';
    signal rx_aes_pt    : std_logic_vector(127 downto 0) := (others => '0');
    signal rx_aes_valid : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- TX VERİ BUFFER'LARI
    -------------------------------------------------------------------------
    signal tx_data_block   : std_logic_vector(127 downto 0) := (others => '0');
    signal tx_ct_blocks    : std_logic_vector(255 downto 0) := (others => '0');
    -- 16 blok × 128 bit = 2048 bit çok büyük, bunun yerine her blok
    -- şifrelendikten sonra hemen gönderilir (streaming mode)
    signal tx_ct_current   : std_logic_vector(127 downto 0) := (others => '0');
    signal tx_mac_accum    : std_logic_vector(127 downto 0) := (others => '0');
    signal tx_mac_result   : std_logic_vector(127 downto 0) := (others => '0');
    signal tx_byte_cnt     : integer range 0 to 15 := 0;
    signal tx_sof_cnt      : integer range 0 to 3 := 0;
    signal tx_block_cnt    : integer range 0 to MAX_BLOCKS := 0;
    signal tx_total_blocks : integer range 1 to MAX_BLOCKS := 1;
    signal tx_send_blk_idx : integer range 0 to MAX_BLOCKS := 0;
    signal tx_seq_num      : unsigned(31 downto 0) := (others => '0');
    signal tx_active       : std_logic := '0';
    
    -- TX multi-block ciphertext FIFO (streaming: encrypt → store → send)
    type ct_array_t is array (0 to MAX_BLOCKS - 1) of 
        std_logic_vector(127 downto 0);
    signal tx_ct_fifo : ct_array_t := (others => (others => '0'));
    
    -------------------------------------------------------------------------
    -- RX VERİ BUFFER'LARI
    -------------------------------------------------------------------------
    signal rx_ct_block     : std_logic_vector(127 downto 0) := (others => '0');
    signal rx_pt_block     : std_logic_vector(127 downto 0) := (others => '0');
    signal rx_mac_accum    : std_logic_vector(127 downto 0) := (others => '0');
    signal rx_mac_computed : std_logic_vector(127 downto 0) := (others => '0');
    signal rx_mac_received : std_logic_vector(127 downto 0) := (others => '0');
    signal rx_byte_cnt     : integer range 0 to 15 := 0;
    signal rx_sof_cnt      : integer range 0 to 3 := 0;
    signal rx_block_cnt    : integer range 0 to MAX_BLOCKS := 0;
    signal rx_total_blocks : integer range 1 to MAX_BLOCKS := 1;
    signal rx_out_blk_idx  : integer range 0 to MAX_BLOCKS := 0;
    signal rx_seq_num      : unsigned(31 downto 0) := (others => '0');
    signal rx_seq_last     : unsigned(31 downto 0) := (others => '1');  -- 0xFFFFFFFF sentinel
    signal rx_active       : std_logic := '0';
    signal sof_shift       : std_logic_vector(31 downto 0) := (others => '0');
    
    -- RX multi-block ciphertext buffer (buffer-then-process)
    signal rx_ct_fifo : ct_array_t := (others => (others => '0'));
    -- RX multi-block plaintext FIFO
    signal rx_pt_fifo : ct_array_t := (others => (others => '0'));
    
    -------------------------------------------------------------------------
    -- SYNTHESIS PROTECTION
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of tx_data_block : signal is "true";
    attribute dont_touch of tx_mac_accum  : signal is "true";
    attribute dont_touch of rx_mac_accum  : signal is "true";
    attribute dont_touch of tx_state      : signal is "true";
    attribute dont_touch of rx_state      : signal is "true";
    attribute dont_touch of tx_seq_num    : signal is "true";
    
begin

    -------------------------------------------------------------------------
    -- AES ARBITRATION: Round-robin TX vs RX
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' or kill_signal = '1' then
                aes_owner    <= '0';
                tx_aes_grant <= '0';
                rx_aes_grant <= '0';
            else
                tx_aes_grant <= '0';
                rx_aes_grant <= '0';
                
                if tx_aes_req = '1' and rx_aes_req = '0' then
                    tx_aes_grant <= '1';
                    aes_owner <= '0';
                elsif rx_aes_req = '1' and tx_aes_req = '0' then
                    rx_aes_grant <= '1';
                    aes_owner <= '1';
                elsif tx_aes_req = '1' and rx_aes_req = '1' then
                    -- Her ikisi de istiyorsa round-robin
                    if aes_owner = '0' then
                        rx_aes_grant <= '1';
                        aes_owner <= '1';
                    else
                        tx_aes_grant <= '1';
                        aes_owner <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- TX FSM (Bağımsız — PC'den oku, şifrele, kabloya yaz)
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            tx_state       <= TX_IDLE;
            tx_data_block  <= (others => '0');
            tx_ct_current  <= (others => '0');
            tx_mac_accum   <= (others => '0');
            tx_mac_result  <= (others => '0');
            tx_byte_cnt    <= 0;
            tx_sof_cnt     <= 0;
            tx_block_cnt   <= 0;
            tx_total_blocks <= 1;
            tx_send_blk_idx <= 0;
            tx_seq_num     <= (others => '0');
            tx_active      <= '0';
            tx_aes_req     <= '0';
            blk_tx_byte    <= (others => '0');
            blk_tx_start   <= '0';
            tx_ct_fifo     <= (others => (others => '0'));
            
        elsif rising_edge(clk) then
            if rst_n = '0' then
                tx_state       <= TX_IDLE;
                tx_data_block  <= (others => '0');
                tx_ct_current  <= (others => '0');
                tx_mac_accum   <= (others => '0');
                tx_mac_result  <= (others => '0');
                tx_byte_cnt    <= 0;
                tx_sof_cnt     <= 0;
                tx_block_cnt   <= 0;
                tx_total_blocks <= 1;
                tx_send_blk_idx <= 0;
                tx_active      <= '0';
                tx_aes_req     <= '0';
                blk_tx_start   <= '0';
                tx_ct_fifo     <= (others => (others => '0'));
            else
                -- Defaults (pulse sinyalleri her cycle sıfırlanmalı)
                blk_tx_start  <= '0';
                tx_aes_req    <= '0';
                tx_aes_valid  <= '0';  -- ★ AES valid tek pulse olmalı
                
                case tx_state is
                
                -- IDLE: İlk byte = NBLK (blok sayısı), sonra TX_COLLECT
                when TX_IDLE =>
                    tx_active <= '0';
                    tx_byte_cnt <= 0;
                    tx_block_cnt <= 0;
                    tx_total_blocks <= 1;
                    tx_send_blk_idx <= 0;
                    tx_mac_accum <= (others => '0');  -- CBC-MAC IV = 0
                    
                    if red_rx_valid = '1' then
                        -- İlk byte = NBLK (1-16)
                        if unsigned(red_rx_byte) >= 1 and
                           unsigned(red_rx_byte) <= MAX_BLOCKS then
                            tx_total_blocks <= to_integer(unsigned(red_rx_byte));
                            tx_state <= TX_COLLECT;
                            tx_active <= '1';
                        end if;
                        -- Geçersiz NBLK sessizce yoksayılır
                    end if;
                
                -- COLLECT: 16 byte topla (bir blok)
                when TX_COLLECT =>
                    if red_rx_valid = '1' then
                        tx_data_block(127 - tx_byte_cnt*8 downto 120 - tx_byte_cnt*8)
                            <= red_rx_byte;
                        
                        if tx_byte_cnt = 15 then
                            -- 16 byte toplandı → şifrele
                            tx_byte_cnt <= 0;
                            tx_state <= TX_ENCRYPT;
                        else
                            tx_byte_cnt <= tx_byte_cnt + 1;
                        end if;
                    end if;
                
                -- ENCRYPT: AES'e gönder
                when TX_ENCRYPT =>
                    tx_aes_req <= '1';
                    if tx_aes_grant = '1' then
                        tx_aes_pt    <= tx_data_block;
                        tx_aes_valid <= '1';
                        tx_aes_req   <= '0';
                        tx_state <= TX_WAIT_AES;
                    end if;
                
                -- WAIT_AES: Ciphertext geldi
                when TX_WAIT_AES =>
                    if aes_ct_valid = '1' and aes_owner = '0' then
                        tx_ct_current <= aes_ct_in;
                        tx_ct_fifo(tx_block_cnt) <= aes_ct_in;
                        -- CBC-MAC: accum XOR plaintext → AES
                        tx_mac_accum <= tx_mac_accum xor tx_data_block xor
                            (x"000000000000000000000000" & 
                             std_logic_vector(tx_seq_num));
                        tx_state <= TX_MAC_UPDATE;
                    end if;
                
                -- MAC_UPDATE: MAC hesapla
                when TX_MAC_UPDATE =>
                    tx_aes_req <= '1';
                    if tx_aes_grant = '1' then
                        tx_aes_pt    <= tx_mac_accum xor x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";
                        tx_aes_valid <= '1';
                        tx_aes_req   <= '0';
                        tx_state <= TX_WAIT_MAC;
                    end if;
                
                -- WAIT_MAC: MAC AES sonucu
                when TX_WAIT_MAC =>
                    if aes_ct_valid = '1' and aes_owner = '0' then
                        report "TX_DBG: WAIT_MAC got result" severity note;
                        tx_mac_accum <= aes_ct_in;  -- CBC-MAC chain
                        tx_block_cnt <= tx_block_cnt + 1;
                        tx_state <= TX_NEXT_BLOCK;
                    end if;
                
                -- NEXT_BLOCK: Devam mı, gönder mi?
                when TX_NEXT_BLOCK =>
                    if tx_block_cnt >= tx_total_blocks then
                        -- Tüm bloklar şifrelendi → göndermeye başla
                        tx_mac_result <= tx_mac_accum;
                        tx_sof_cnt <= 0;
                        tx_state <= TX_SEND_SOF;
                    else
                        -- Daha blok var → sonraki 16 byte'ı topla
                        tx_byte_cnt <= 0;
                        tx_state <= TX_COLLECT;
                    end if;
                
                -- SEND_SOF: SOF marker (AA 55 AA 55)
                when TX_SEND_SOF =>
                    if blk_tx_busy = '0' then
                        blk_tx_byte <= SOF_MARKER(31 - tx_sof_cnt*8 downto 
                                                   24 - tx_sof_cnt*8);
                        blk_tx_start <= '1';
                        if tx_sof_cnt = 3 then
                            tx_sof_cnt <= 0;
                            tx_state <= TX_SEND_SEQ;
                        else
                            tx_sof_cnt <= tx_sof_cnt + 1;
                        end if;
                    end if;
                
                -- SEND_SEQ: Sequence number (4 byte)
                when TX_SEND_SEQ =>
                    if blk_tx_busy = '0' then
                        blk_tx_byte <= std_logic_vector(
                            tx_seq_num(31 - tx_sof_cnt*8 downto 24 - tx_sof_cnt*8));
                        blk_tx_start <= '1';
                        if tx_sof_cnt = 3 then
                            tx_state <= TX_SEND_NBLK;
                        else
                            tx_sof_cnt <= tx_sof_cnt + 1;
                        end if;
                    end if;
                
                -- SEND_NBLK: Block count (1 byte)
                when TX_SEND_NBLK =>
                    if blk_tx_busy = '0' then
                        blk_tx_byte <= std_logic_vector(
                            to_unsigned(tx_block_cnt, 8));
                        blk_tx_start <= '1';
                        tx_send_blk_idx <= 0;
                        tx_byte_cnt <= 0;
                        tx_state <= TX_SEND_CT;
                    end if;
                
                -- SEND_CT: Tüm ciphertext blokları gönder
                when TX_SEND_CT =>
                    if blk_tx_busy = '0' then
                        blk_tx_byte <= tx_ct_fifo(tx_send_blk_idx)(
                            127 - tx_byte_cnt*8 downto 120 - tx_byte_cnt*8);
                        blk_tx_start <= '1';
                        
                        if tx_byte_cnt = 15 then
                            tx_byte_cnt <= 0;
                            if tx_send_blk_idx = tx_block_cnt - 1 then
                                -- Tüm CT blokları gönderildi → MAC gönder
                                tx_byte_cnt <= 0;
                                tx_state <= TX_SEND_MAC;
                            else
                                tx_send_blk_idx <= tx_send_blk_idx + 1;
                            end if;
                        else
                            tx_byte_cnt <= tx_byte_cnt + 1;
                        end if;
                    end if;
                
                -- SEND_MAC: MAC gönder (16 byte)
                when TX_SEND_MAC =>
                    if blk_tx_busy = '0' then
                        blk_tx_byte <= tx_mac_result(
                            127 - tx_byte_cnt*8 downto 120 - tx_byte_cnt*8);
                        blk_tx_start <= '1';
                        if tx_byte_cnt = 15 then
                            tx_state <= TX_DONE;
                        else
                            tx_byte_cnt <= tx_byte_cnt + 1;
                        end if;
                    end if;
                
                -- DONE: Temizle
                when TX_DONE =>
                    tx_data_block <= (others => '0');
                    tx_ct_current <= (others => '0');
                    tx_mac_accum  <= (others => '0');
                    tx_mac_result <= (others => '0');
                    
                    -- ★ FIX 4: Seq wrap-around guard
                    -- 0xFFFFFFFE = son güvenli değer. Bundan sonra sentinel
                    -- (0xFFFFFFFF) kullanılır ve wrap riski oluşur.
                    if tx_seq_num >= x"FFFFFFFE" then
                        -- Seq tükendi → TX donduruluyor
                        -- Yeni key yüklenmeli (kill + reinit)
                        tx_active <= '0';
                        -- TX_DONE'da kalır — yeni veriler kabul edilmez
                    else
                        tx_seq_num <= tx_seq_num + 1;
                        tx_state <= TX_IDLE;
                    end if;
                
                when others =>
                    tx_state <= TX_IDLE;
                end case;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- RX FSM (Bağımsız — kabloda dinle, çöz, PC'ye yaz)
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            rx_state       <= RX_IDLE;
            rx_ct_block    <= (others => '0');
            rx_pt_block    <= (others => '0');
            rx_mac_accum   <= (others => '0');
            rx_mac_computed <= (others => '0');
            rx_mac_received <= (others => '0');
            rx_byte_cnt    <= 0;
            rx_sof_cnt     <= 0;
            rx_block_cnt   <= 0;
            rx_total_blocks <= 1;
            rx_out_blk_idx <= 0;
            rx_seq_num     <= (others => '0');
            rx_seq_last    <= (others => '1');  -- Sentinel: 0xFFFFFFFF
            rx_active      <= '0';
            rx_aes_req     <= '0';
            sof_shift      <= (others => '0');
            red_tx_byte    <= (others => '0');
            red_tx_start   <= '0';
            mac_error      <= '0';
            frame_error    <= '0';
            rx_pt_fifo     <= (others => (others => '0'));
            rx_ct_fifo     <= (others => (others => '0'));
            
        elsif rising_edge(clk) then
            if rst_n = '0' then
                rx_state       <= RX_IDLE;
                rx_ct_block    <= (others => '0');
                rx_pt_block    <= (others => '0');
                rx_mac_accum   <= (others => '0');
                rx_mac_computed <= (others => '0');
                rx_mac_received <= (others => '0');
                rx_byte_cnt    <= 0;
                rx_sof_cnt     <= 0;
                rx_block_cnt   <= 0;
                rx_total_blocks <= 1;
                rx_out_blk_idx <= 0;
                rx_active      <= '0';
                rx_aes_req     <= '0';
                sof_shift      <= (others => '0');
                red_tx_start   <= '0';
                mac_error      <= '0';
                frame_error    <= '0';
                rx_pt_fifo     <= (others => (others => '0'));
            else
                -- Defaults (pulse sinyalleri her cycle sıfırlanmalı)
                red_tx_start  <= '0';
                rx_aes_req    <= '0';
                rx_aes_valid  <= '0';  -- ★ AES valid tek pulse olmalı
                
                case rx_state is
                
                -- IDLE: RX moduna geç
                when RX_IDLE =>
                    rx_active <= '0';
                    mac_error <= '0';
                    frame_error <= '0';
                    rx_byte_cnt <= 0;
                    rx_sof_cnt <= 0;
                    rx_block_cnt <= 0;
                    rx_total_blocks <= 1;
                    rx_out_blk_idx <= 0;
                    rx_mac_accum <= (others => '0');
                    sof_shift <= (others => '0');
                    rx_state <= RX_SYNC;
                    rx_active <= '1';
                
                -- SYNC: SOF marker ara
                when RX_SYNC =>
                    if blk_rx_valid = '1' then
                        sof_shift <= sof_shift(23 downto 0) & blk_rx_byte;
                        if sof_shift(23 downto 0) & blk_rx_byte = SOF_MARKER then
                            rx_sof_cnt <= 0;
                            rx_state <= RX_SEQ;
                        end if;
                    end if;
                
                -- SEQ: Sequence number oku (4 byte)
                when RX_SEQ =>
                    if blk_rx_valid = '1' then
                        rx_seq_num(31 - rx_sof_cnt*8 downto 24 - rx_sof_cnt*8)
                            <= unsigned(blk_rx_byte);
                        if rx_sof_cnt = 3 then
                            rx_state <= RX_NBLK;
                        else
                            rx_sof_cnt <= rx_sof_cnt + 1;
                        end if;
                    end if;
                
                -- NBLK: Block count oku (1 byte)
                when RX_NBLK =>
                    if blk_rx_valid = '1' then
                        -- Anti-replay: seq_num MUTLAKA son kabul edilenden BÜYÜK olmalı
                        -- Sentinel (0xFFFFFFFF): İlk frame'de her zaman geçer
                        if rx_seq_num <= rx_seq_last and rx_seq_last /= x"FFFFFFFF" then
                            frame_error <= '1';
                            rx_state <= RX_IDLE;
                        else
                            -- Block count (1..16)
                            if unsigned(blk_rx_byte) >= 1 and 
                               unsigned(blk_rx_byte) <= MAX_BLOCKS then
                                rx_total_blocks <= to_integer(unsigned(blk_rx_byte));
                                rx_byte_cnt <= 0;
                                rx_block_cnt <= 0;
                                rx_state <= RX_COLLECT_CT;
                            else
                                frame_error <= '1';
                                rx_state <= RX_IDLE;
                            end if;
                        end if;
                    end if;
                
                -- COLLECT_CT: TÜM ciphertext bloklarını buffer'la
                -- Buffer-then-process: Tüm CT + MAC okunduktan SONRA decrypt başlar
                when RX_COLLECT_CT =>
                    if blk_rx_valid = '1' then
                        rx_ct_block(127 - rx_byte_cnt*8 downto 120 - rx_byte_cnt*8)
                            <= blk_rx_byte;
                        if rx_byte_cnt = 15 then
                            -- Block tamamlandı → ct_fifo'ya kaydet
                            rx_ct_fifo(rx_block_cnt) <= rx_ct_block(127 downto 8) & blk_rx_byte;
                            rx_byte_cnt <= 0;
                            rx_block_cnt <= rx_block_cnt + 1;
                            if rx_block_cnt + 1 >= rx_total_blocks then
                                -- Tüm CT blokları toplandı → MAC topla
                                rx_state <= RX_COLLECT_MAC;
                            end if;
                            -- else: rx_state RX_COLLECT_CT kalır → sonraki blok
                        else
                            rx_byte_cnt <= rx_byte_cnt + 1;
                        end if;
                    end if;
                
                -- DECRYPT: ct_fifo'dan sonraki bloğu AES'e gönder
                when RX_DECRYPT =>
                    rx_aes_req <= '1';
                    if rx_aes_grant = '1' then
                        rx_aes_pt    <= rx_ct_fifo(rx_block_cnt);
                        rx_aes_valid <= '1';
                        rx_aes_req   <= '0';
                        rx_state <= RX_WAIT_AES;
                    end if;
                
                -- WAIT_AES: Decrypted plaintext geldi
                when RX_WAIT_AES =>
                    if aes_ct_valid = '1' and aes_owner = '1' then
                        rx_pt_block <= aes_ct_in;
                        rx_pt_fifo(rx_block_cnt) <= aes_ct_in;
                        -- CBC-MAC: accum XOR plaintext XOR seqnum → AES
                        rx_mac_accum <= rx_mac_accum xor aes_ct_in xor 
                            (x"000000000000000000000000" &
                             std_logic_vector(rx_seq_num));
                        rx_state <= RX_MAC_UPDATE;
                    end if;
                
                -- MAC_UPDATE: MAC hesapla
                when RX_MAC_UPDATE =>
                    rx_aes_req <= '1';
                    if rx_aes_grant = '1' then
                        rx_aes_pt    <= rx_mac_accum xor x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF";
                        rx_aes_valid <= '1';
                        rx_aes_req   <= '0';
                        rx_state <= RX_WAIT_MAC;
                    end if;
                
                -- WAIT_MAC: MAC AES sonucu
                when RX_WAIT_MAC =>
                    if aes_ct_valid = '1' and aes_owner = '1' then
                        report "RX_DBG: WAIT_MAC got result" severity note;
                        rx_mac_accum <= aes_ct_in;  -- CBC-MAC chain
                        rx_block_cnt <= rx_block_cnt + 1;
                        rx_state <= RX_NEXT_BLOCK;
                    end if;
                
                -- NEXT_BLOCK: Daha blok var mı?
                when RX_NEXT_BLOCK =>
                    if rx_block_cnt >= rx_total_blocks then
                        -- Tüm bloklar decrypt edildi → MAC karşılaştır
                        rx_mac_computed <= rx_mac_accum;
                        rx_state <= RX_CHECK_MAC;
                    else
                        -- Sonraki blok → decrypt devam
                        rx_state <= RX_DECRYPT;
                    end if;
                
                -- COLLECT_MAC: MAC oku (16 byte) → sonra decrypt chain başla
                when RX_COLLECT_MAC =>
                    if blk_rx_valid = '1' then
                        rx_mac_received(127 - rx_byte_cnt*8 downto 120 - rx_byte_cnt*8)
                            <= blk_rx_byte;
                        if rx_byte_cnt = 15 then
                            -- MAC buffer'landı → decrypt chain başlat
                            rx_byte_cnt <= 0;
                            rx_block_cnt <= 0;  -- Decrypt loop counter sıfırla
                            rx_state <= RX_DECRYPT;
                        else
                            rx_byte_cnt <= rx_byte_cnt + 1;
                        end if;
                    end if;
                
                -- CHECK_MAC: MAC karşılaştır
                when RX_CHECK_MAC =>
                    -- DEBUG: safe check without to_integer
                    if rx_mac_computed = rx_mac_received then
                        -- ✅ MAC geçerli → plaintext gönder
                        report "RX_DBG: MAC MATCH - proceeding to output" severity note;
                        rx_byte_cnt <= 0;
                        rx_out_blk_idx <= 0;
                        rx_state <= RX_OUTPUT;
                    else
                        -- ❌ MAC hatalı → veriyi at
                        report "RX_DBG: MAC MISMATCH!" severity warning;
                        mac_error <= '1';
                        rx_pt_fifo <= (others => (others => '0'));
                        rx_state <= RX_IDLE;
                    end if;
                
                -- OUTPUT: Tüm plaintext blokları → RED UART
                when RX_OUTPUT =>
                    if red_tx_busy = '0' then
                        red_tx_byte <= rx_pt_fifo(rx_out_blk_idx)(
                            127 - rx_byte_cnt*8 downto 120 - rx_byte_cnt*8);
                        red_tx_start <= '1';
                        
                        if rx_byte_cnt = 15 then
                            rx_byte_cnt <= 0;
                            if rx_out_blk_idx = rx_total_blocks - 1 then
                                rx_state <= RX_DONE;
                            else
                                rx_out_blk_idx <= rx_out_blk_idx + 1;
                            end if;
                        else
                            rx_byte_cnt <= rx_byte_cnt + 1;
                        end if;
                    end if;
                
                -- DONE: Temizle
                when RX_DONE =>
                    rx_seq_last <= rx_seq_num;
                    -- rx_first_rx bypass kaldırıldı — sentinel sistemi kullanılıyor
                    rx_ct_block     <= (others => '0');
                    rx_pt_block     <= (others => '0');
                    rx_mac_accum    <= (others => '0');
                    rx_mac_received <= (others => '0');
                    rx_pt_fifo      <= (others => (others => '0'));
                    rx_state <= RX_IDLE;
                
                when others =>
                    rx_state <= RX_IDLE;
                end case;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- AES OUTPUT MUX (TX vs RX based on owner)
    -------------------------------------------------------------------------
    aes_pt_out   <= tx_aes_pt   when aes_owner = '0' else rx_aes_pt;
    aes_pt_valid <= tx_aes_valid when aes_owner = '0' else rx_aes_valid;

    -------------------------------------------------------------------------
    -- STATUS OUTPUTS
    -------------------------------------------------------------------------
    session_active <= tx_active or rx_active;

end Behavioral;
