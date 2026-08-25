--------------------------------------------------------------------------------
-- PROJECT TITAN V13: Data Gearbox (Width Converter)
-- Module: 8-bit UART ↔ 128-bit AES Bridge
--------------------------------------------------------------------------------
-- AMAÇ: RED/BLACK domain separation ve veri genişliği dönüşümü
--
-- KOMUTAN ŞERHİ: "Vites Kutusu - 8-bit damlaları 128-bit kovaya dönüştürür!"
--
-- MİMARİ:
--   ┌────────────┐                    ┌─────────────┐
--   │   PC       │                    │    AES      │
--   │  (ASCII)   │                    │   Motor     │
--   └──────┬─────┘                    └──────┬──────┘
--          │ 8-bit                           │ 128-bit
--          ↓ UART RX                         ↓ Ciphertext
--   ┌──────────────┐                  ┌──────────────┐
--   │   PACKER     │ ──16 bytes──->    │  UNPACKER    │
--   │ (Accumulator)│                  │ (Serializer) │
--   └──────────────┘                  └──────────────┘
--
-- KIRMIZI ALAN (RED): Plaintext (8-bit UART)
-- SİYAH ALAN (BLACK): Ciphertext (128-bit AES)
--
-- GİYOTİN: rst_n='0' -> Buffer temizle, veri akışı dur!
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity data_gearbox is
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;  -- ★ GİYOTİN (pipeline_enable)
        
        -------------------------------------------------------------------------
        -- KIRMIZI TARAF (RED Domain - Plaintext)
        -------------------------------------------------------------------------
        -- UART RX -> Gearbox
        rx_byte     : in  std_logic_vector(7 downto 0);
        rx_valid    : in  std_logic;  -- Tek cycle pulse
        
        -- Gearbox -> UART TX
        tx_byte     : out std_logic_vector(7 downto 0);
        tx_start    : out std_logic;  -- Tek cycle pulse
        tx_busy     : in  std_logic;  -- Backpressure
        
        -------------------------------------------------------------------------
        -- SİYAH TARAF (BLACK Domain - Ciphertext)
        -------------------------------------------------------------------------
        -- Gearbox -> AES Input (Plaintext Block)
        aes_in_blk  : out std_logic_vector(127 downto 0);
        aes_in_vld  : out std_logic;  -- '1' = 128-bit blok hazır!
        
        -- AES Output -> Gearbox (Ciphertext Block)
        aes_out_blk : in  std_logic_vector(127 downto 0);
        aes_out_vld : in  std_logic   -- '1' = Yeni şifreli blok geldi
    );
end data_gearbox;

architecture Behavioral of data_gearbox is

    -------------------------------------------------------------------------
    -- PACKER (RX -> AES) SİNYALLERİ
    -------------------------------------------------------------------------
    -- 16 byte biriktiği an AES'e gönder
    -------------------------------------------------------------------------
    signal input_buf  : std_logic_vector(127 downto 0) := (others => '0');
    signal byte_cnt   : integer range 0 to 15 := 0;
    
    -------------------------------------------------------------------------
    -- UNPACKER (AES -> TX) SİNYALLERİ
    -------------------------------------------------------------------------
    -- 128-bit blogu 16 byte'a böl, sırayla UART'a gönder
    -------------------------------------------------------------------------
    signal output_buf : std_logic_vector(127 downto 0) := (others => '0');
    signal out_cnt    : integer range 0 to 16 := 16;  -- 16 = idle

    -- Internal drive signals (VHDL-93: cannot read 'out' ports)
    signal tx_start_i : std_logic := '0';
    signal tx_byte_i  : std_logic_vector(7 downto 0) := (others => '0');
    
    -------------------------------------------------------------------------
    -- DEBUG SİNYALLERİ (Simülasyon için)
    -------------------------------------------------------------------------
    attribute mark_debug : string;
    attribute mark_debug of byte_cnt : signal is "true";
    attribute mark_debug of out_cnt  : signal is "true";

begin

    -- Output port assignments
    tx_start <= tx_start_i;
    tx_byte  <= tx_byte_i;

    -------------------------------------------------------------------------
    -- 1. PACKER (RED -> BLACK) - Plaintext Accumulation
    -------------------------------------------------------------------------
    -- PC'den gelen 8-bit byte'ları topla, 16 byte dolduğunda AES'e at
    --
    -- Big Endian Byte Order:
    --   Byte 0  -> input_buf(127 downto 120)
    --   Byte 1  -> input_buf(119 downto 112)
    --   ...
    --   Byte 15 -> input_buf(7 downto 0)
    --
    -- Örnek: "S A L D I R I   S A F A K T A ." (16 char)
    --   S = 0x53 -> MSB
    --   A = 0x41
    --   ...
    --   . = 0x2E -> LSB
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                ---------------------------------------------------------------------
                -- ★ GİYOTİN: Buffer temizle!
                ---------------------------------------------------------------------
                input_buf  <= (others => '0');
                byte_cnt   <= 0;
                aes_in_vld <= '0';
                
            else
                ---------------------------------------------------------------------
                -- Default: aes_in_vld tek cycle pulse
                ---------------------------------------------------------------------
                aes_in_vld <= '0';
                
                ---------------------------------------------------------------------
                -- RX Byte Geldi (UART'tan)
                ---------------------------------------------------------------------
                if rx_valid = '1' then
                    -- Big Endian packing: MSB'den başla
                    input_buf(127 - byte_cnt*8 downto 120 - byte_cnt*8) <= rx_byte;
                    
                    if byte_cnt = 15 then
                        -------------------------------------------------------------------
                        -- 16. Byte Geldi -> 128-bit Blok Tamamlandı!
                        -------------------------------------------------------------------
                        byte_cnt <= 0;
                        
                        -- Son byte'ı da ekle (yukarıdaki assignment bir cycle gecikmeli)
                        aes_in_blk <= input_buf(127 downto 8) & rx_byte;
                        aes_in_vld <= '1';  -- ★ AES'e ateş komutu!
                        
                    else
                        -------------------------------------------------------------------
                        -- Henüz blok dolmadı, sayaç arttır
                        -------------------------------------------------------------------
                        byte_cnt <= byte_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- 2. UNPACKER (BLACK -> RED) - Ciphertext Serialization
    -------------------------------------------------------------------------
    -- AES'ten gelen 128-bit bloğu 16 byte'a böl, UART'a sırayla gönder
    --
    -- Big Endian Byte Order:
    --   out_cnt=0  -> output_buf(127 downto 120) = Byte 0
    --   out_cnt=1  -> output_buf(119 downto 112) = Byte 1
    --   ...
    --   out_cnt=15 -> output_buf(7 downto 0)    = Byte 15
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                ---------------------------------------------------------------------
                -- ★ GİYOTİN: Output buffer temizle!
                ---------------------------------------------------------------------
                output_buf <= (others => '0');
                out_cnt    <= 16;  -- IDLE state
                tx_start   <= '0';
                tx_byte    <= (others => '0');
                
            else
                ---------------------------------------------------------------------
                -- Default: tx_start tek cycle pulse
                ---------------------------------------------------------------------
                tx_start_i <= '0';
                
                ---------------------------------------------------------------------
                -- Yeni Şifreli Blok Geldi (AES'ten)
                ---------------------------------------------------------------------
                if aes_out_vld = '1' then
                    output_buf <= aes_out_blk;
                    out_cnt    <= 0;  -- Gönderimi başlat
                end if;
                
                ---------------------------------------------------------------------
                -- Byte-by-Byte Gönderme (UART TX'e)
                ---------------------------------------------------------------------
                if out_cnt < 16 and tx_busy = '0' and tx_start_i = '0' then
                    -- Big Endian extraction
                    tx_byte_i  <= output_buf(127 - out_cnt*8 downto 120 - out_cnt*8);
                    tx_start_i <= '1';  -- UART'a "gönder!" emri
                    out_cnt    <= out_cnt + 1;
                end if;
            end if;
        end if;
    end process;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. BIG ENDIAN BYTE ORDER
--    İlk gelen byte MSB'de olur (network byte order)
--    PC'de little endian ama UART hattı big endian kabul edilir
--
-- 2. FIFO YOK (Basitlik)
--    Backpressure: tx_busy ile UART'ın hazır olmasını bekle
--    Overflow riski: Yoktur (AES blok tamamlanana kadar yeni blok gelmez)
--
-- 3. PACKER FILLING TIME
--    115200 baud -> 11520 byte/s (10 bit/byte dahil)
--    16 byte -> 1.39 ms
--    AES latency (~10 cycle @ 50MHz = 200ns) << packing time
--
-- 4. UNPACKER DRAINING TIME
--    16 byte × 86.8µs/byte (UART overhead) = 1.39 ms
--    AES başka blok şifrelerken TX devam eder (pipelined)
--
-- 5. GUILLOTINE EFFECT
--    rst_n='0' -> Buffer reset
--    Kısmi paketler kaybolur (intentional - güvenlik!)
--    key_valid='0' iken veri göndermek anlamsız (şifreleme yok)
--
-- 6. LOOPBACK TEST
--    PC -> "SALDIRI BASLASIN" (16 char)
--    Gearbox -> 128-bit block
--    AES -> Cipher block
--    Gearbox -> 16 byte ciphertext
--    PC ← [gürültü] (şifreli data)
--
-- 7. TIMING DIAGRAM (Packer)
--    t=0ms:   rx_valid='1', rx_byte=0x53 ('S'), byte_cnt=0
--    t=86µs:  rx_valid='1', rx_byte=0x41 ('A'), byte_cnt=1
--    ...
--    t=1.29ms: rx_valid='1', rx_byte=0x2E ('.'), byte_cnt=15
--    t=1.29ms: aes_in_vld='1' (tek cycle), aes_in_blk=128-bit
--
-- 8. TIMING DIAGRAM (Unpacker)
--    t=1.30ms: aes_out_vld='1', aes_out_blk=[cipher]
--    t=1.30ms: out_cnt=0, tx_start='1', tx_byte=[cipher byte 0]
--    t=1.39ms: tx_busy='0' (UART bitti)
--    t=1.39ms: out_cnt=1, tx_start='1', tx_byte=[cipher byte 1]
--    ...
--    t=2.68ms: out_cnt=16 (IDLE)
--
-- 9. RED/BLACK SEPARATION
--    RED (Plaintext):
--      - rx_byte, tx_byte
--      - input_buf (plaintext accumulator)
--    BLACK (Ciphertext):
--      - aes_in_blk, aes_out_blk
--      - output_buf (ciphertext serializer)
--
-- 10. SENTEZ SONUÇLARI (Beklenen)
--    LUT: ~50 (counter + mux)
--    FF: 256 + 10 (input_buf + output_buf + counters)
--    BRAM: 0
--
-- 11. ALTERNATIF MİMARİLER
--    - FIFO ekle: Pipelined operation (daha hızlı throughput)
--    - Little endian: PC endianness'ına uyum (gereksiz)
--    - Multi-block buffering: Daha karmaşık (gereksiz şimdilik)
--
-- 12. GÜVENLIK KONSİDERASYONLARI
--    - Buffer overflow: Mümkün değil (16 byte limit)
--    - Timing attack: Counter visible (kabul edilebilir)
--    - Side-channel: Veri akışı sabit hız (DPA zorlaştı)
--
-- 13. DEBUGGING
--    Simülasyonda:
--      - byte_cnt izle (0..15 sayması lazım)
--      - aes_in_vld pulse'ı gör (her 16 byte'da bir)
--      - out_cnt izle (0..16 sayması lazım)
--
-- 14. TEST SENARYOSU
--    ```vhdl
--    -- 16 byte gönder
--    for i in 0 to 15 loop
--        wait until rising_edge(clk);
--        rx_byte <= std_logic_vector(to_unsigned(i + 65, 8));  -- 'A'..'P'
--        rx_valid <= '1';
--        wait until rising_edge(clk);
--        rx_valid <= '0';
--        wait for 86 us;  -- UART bit time
--    end loop;
--    
--    -- AES'ten cipher block geldi (simüle et)
--    wait for 1 us;
--    aes_out_blk <= x"DEADBEEF_CAFEBABE_12345678_9ABCDEF0";
--    aes_out_vld <= '1';
--    wait until rising_edge(clk);
--    aes_out_vld <= '0';
--    
--    -- 16 byte TX bekle
--    for i in 0 to 15 loop
--        wait until tx_start = '1';
--        report "TX Byte " & integer'image(i) & ": " & to_hstring(tx_byte);
--    end loop;
--    ```
--------------------------------------------------------------------------------

-- ⚙️ "VİTES KUTUSU HAZIR - 8-BİT ↔ 128-BİT DÖNÜŞÜm AKTIF!" ⚙️

--------------------------------------------------------------------------------
