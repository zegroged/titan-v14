--------------------------------------------------------------------------------
-- PROJECT TITAN V13: Full-Duplex UART Driver
-- Module: Universal Asynchronous Receiver/Transmitter (8N1)
--------------------------------------------------------------------------------
-- AMAÇ: PC ile güvenli cihaz arasında seri iletişim (RED/BLACK köprüsü)
--
-- KOMUTAN ŞERHİ: "Cihazın Ağzı ve Kulağı!"
--
-- STANDART:
--   - Baud Rate: 115200 (hızlı iletişim)
--   - Data Bits: 8
--   - Parity: None
--   - Stop Bits: 1
--   - Flow Control: None (FIFO'suz basit mimari)
--
-- KRİTİK ÖZELLİKLER:
--   1. Full-Duplex: Aynı anda hem RX hem TX
--   2. CDC Synchronization: rx_pin asenkron -> sys_clk domain'e güvenli geçiş
--   3. Start Bit Detection: False trigger önleme (half-bit sampling)
--   4. Independent FSM: RX ve TX birbirini bloklamaz
--
-- GÜVENLİK:
--   - IP Core YASAK: Saf VHDL (zero trust on vendor libs)
--   - Guillotine Ready: rst_n ile instant shutdown
--   - No FIFO: Buffer overflow riski yok (gearbox'ta olacak)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_driver is
    generic (
        CLK_FREQ  : integer := 50_000_000;  -- System clock (Hz)
        BAUD_RATE : integer := 115_200      -- Serial baud rate
    );
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;  -- ★ GİYOTİN: pipeline_enable'dan gelir
        
        -------------------------------------------------------------------------
        -- FİZİKSEL HATlar (Seri Port Pinleri)
        -------------------------------------------------------------------------
        rx_pin    : in  std_logic;  -- UART RX (PC -> FPGA)
        tx_pin    : out std_logic;  -- UART TX (FPGA -> PC)
        
        -------------------------------------------------------------------------
        -- KIRMIZI/SİYAH ARAYÜZ (Gearbox ile)
        -------------------------------------------------------------------------
        -- TX Path (FPGA -> PC)
        tx_data   : in  std_logic_vector(7 downto 0);  -- Gönderilecek byte
        tx_start  : in  std_logic;                     -- '1' = Gönder!
        tx_busy   : out std_logic;                     -- '1' = Meşgul, bekle
        
        -- RX Path (PC -> FPGA)
        rx_data   : out std_logic_vector(7 downto 0);  -- Alınan byte
        rx_valid  : out std_logic                      -- '1' = Yeni byte hazır
    );
end uart_driver;

architecture Behavioral of uart_driver is

    -------------------------------------------------------------------------
    -- BİT PERİYODU (Clock cycle cinsinden)
    -------------------------------------------------------------------------
    -- 115200 baud -> 8.68 µs/bit
    -- 50 MHz -> 20 ns/cycle
    -- BIT_PERIOD = 8.68µs / 20ns = 434 cycle
    -------------------------------------------------------------------------
    constant BIT_PERIOD : integer := CLK_FREQ / BAUD_RATE;
    
    -------------------------------------------------------------------------
    -- RECEIVER (RX) SİNYALLERİ
    -------------------------------------------------------------------------
    signal rx_sync      : std_logic_vector(1 downto 0) := "11";  -- CDC sync
    signal rx_cnt       : integer range 0 to BIT_PERIOD-1 := 0;
    signal rx_bit_idx   : integer range 0 to 8 := 0;
    signal rx_shift     : std_logic_vector(7 downto 0) := (others => '0');
    
    -- RX State Machine
    type rx_state_type is (IDLE, START_CHECK, DATA_BITS, STOP_BIT);
    signal rx_state : rx_state_type := IDLE;
    
    -------------------------------------------------------------------------
    -- TRANSMITTER (TX) SİNYALLERİ
    -------------------------------------------------------------------------
    signal tx_cnt       : integer range 0 to BIT_PERIOD-1 := 0;
    signal tx_bit_idx   : integer range 0 to 9 := 0;
    signal tx_shift     : std_logic_vector(9 downto 0) := (others => '1');
    
    -- TX State Machine
    type tx_state_type is (IDLE, TRANSMIT);
    signal tx_state : tx_state_type := IDLE;

begin

    -------------------------------------------------------------------------
    -- 1. UART RECEIVER (RX) - PC'den Veri Alma
    -------------------------------------------------------------------------
    -- UART Protocol (8N1):
    --   [IDLE='1'] -> [START='0'] -> [D0..D7] -> [STOP='1'] -> [IDLE]
    --
    -- CDC SYNC: rx_pin asenkron (PC clock) -> rx_sync senkron (sys_clk)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                ---------------------------------------------------------------------
                -- GİYOTİN KESTİ! (KILL veya key_valid='0')
                ---------------------------------------------------------------------
                rx_state   <= IDLE;
                rx_sync    <= "11";
                rx_valid   <= '0';
                rx_data    <= (others => '0');
                rx_cnt     <= 0;
                rx_bit_idx <= 0;
                
            else
                ---------------------------------------------------------------------
                -- CDC SYNCHRONIZATION (2-FF Cascade)
                ---------------------------------------------------------------------
                rx_sync <= rx_sync(0) & rx_pin;
                
                ---------------------------------------------------------------------
                -- Default: rx_valid tek cycle pulse
                ---------------------------------------------------------------------
                rx_valid <= '0';
                
                ---------------------------------------------------------------------
                -- RX STATE MACHINE
                ---------------------------------------------------------------------
                case rx_state is
                
                    -------------------------------------------------------------------
                    -- IDLE: Start bit'i bekle
                    -------------------------------------------------------------------
                    when IDLE =>
                        if rx_sync(1) = '0' then  -- Falling edge (Start bit başlangıcı)
                            rx_cnt <= 0;
                            rx_state <= START_CHECK;
                        end if;
                    
                    -------------------------------------------------------------------
                    -- START_CHECK: Yarı bit gecikme sonrası start bit doğrula
                    -------------------------------------------------------------------
                    -- False trigger önleme: Noise spike'lar hemen start sanılmasın
                    -------------------------------------------------------------------
                    when START_CHECK =>
                        if rx_cnt < BIT_PERIOD / 2 then
                            rx_cnt <= rx_cnt + 1;
                        else
                            -- Half-bit noktasında hala '0' mı?
                            if rx_sync(1) = '0' then
                                -- ✅ Geçerli start bit!
                                rx_cnt     <= 0;
                                rx_bit_idx <= 0;
                                rx_state   <= DATA_BITS;
                            else
                                -- ❌ False trigger (noise)
                                rx_state <= IDLE;
                            end if;
                        end if;
                    
                    -------------------------------------------------------------------
                    -- DATA_BITS: 8 data bit'i (LSB first) örnekle
                    -------------------------------------------------------------------
                    when DATA_BITS =>
                        if rx_cnt < BIT_PERIOD - 1 then
                            rx_cnt <= rx_cnt + 1;
                        else
                            -- Bit ortasında örnekle (en stabil nokta)
                            rx_cnt <= 0;
                            rx_shift(rx_bit_idx) <= rx_sync(1);
                            
                            if rx_bit_idx < 7 then
                                rx_bit_idx <= rx_bit_idx + 1;
                            else
                                rx_state <= STOP_BIT;
                            end if;
                        end if;
                    
                    -------------------------------------------------------------------
                    -- STOP_BIT: Stop bit'i bekle ve byte'ı output'a yaz
                    -------------------------------------------------------------------
                    when STOP_BIT =>
                        if rx_cnt < BIT_PERIOD - 1 then
                            rx_cnt <= rx_cnt + 1;
                        else
                            -- Stop bit kontrol et (olması gereken: '1')
                            if rx_sync(1) = '1' then
                                -- ✅ Geçerli paket!
                                rx_data  <= rx_shift;
                                rx_valid <= '1';  -- ← Tek cycle pulse
                            end if;
                            -- Hatalı stop bit bile olsa IDLE'a dön (framing error ignore)
                            rx_state <= IDLE;
                        end if;
                        
                end case;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- 2. UART TRANSMITTER (TX) - PC'ye Veri Gönderme
    -------------------------------------------------------------------------
    -- UART Protocol: [START='0'] -> [D0..D7] -> [STOP='1']
    -- tx_shift: [STOP | D7 D6 D5 D4 D3 D2 D1 D0 | START]
    --            MSB ←---------------------------> LSB (sağdan sola shift)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                ---------------------------------------------------------------------
                -- GİYOTİN KESTİ!
                ---------------------------------------------------------------------
                tx_state <= IDLE;
                tx_pin   <= '1';  -- IDLE state (high)
                tx_busy  <= '0';
                tx_cnt   <= 0;
                
            else
                ---------------------------------------------------------------------
                -- TX STATE MACHINE
                ---------------------------------------------------------------------
                case tx_state is
                
                    -------------------------------------------------------------------
                    -- IDLE: Gönderim emri bekle
                    -------------------------------------------------------------------
                    when IDLE =>
                        tx_pin <= '1';  -- IDLE = high
                        
                        if tx_start = '1' then
                            -- Shift register'ı hazırla:
                            -- [STOP='1'] [Data(7..0)] [START='0']
                            tx_shift <= '1' & tx_data & '0';
                            tx_state <= TRANSMIT;
                            tx_cnt   <= 0;
                            tx_bit_idx <= 0;
                            tx_busy  <= '1';
                        else
                            tx_busy <= '0';
                        end if;
                    
                    -------------------------------------------------------------------
                    -- TRANSMIT: Shift register'dan LSB'yi gönder
                    -------------------------------------------------------------------
                    when TRANSMIT =>
                        tx_pin <= tx_shift(0);  -- LSB -> TX pin
                        
                        if tx_cnt < BIT_PERIOD - 1 then
                            tx_cnt <= tx_cnt + 1;
                        else
                            -- Bir bit süresi doldu
                            tx_cnt <= 0;
                            
                            if tx_bit_idx < 9 then
                                -- Shift right (bir sonraki bit)
                                tx_shift <= '1' & tx_shift(9 downto 1);
                                tx_bit_idx <= tx_bit_idx + 1;
                            else
                                -- 10 bit gönderildi (START + 8 DATA + STOP)
                                tx_state <= IDLE;
                                tx_busy  <= '0';
                            end if;
                        end if;
                        
                end case;
            end if;
        end if;
    end process;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. BAUD RATE CALCULATION
--    BIT_PERIOD = CLK_FREQ / BAUD_RATE
--    @ 50MHz, 115200 baud: 434 clock cycles/bit
--
-- 2. CDC SYNCHRONIZATION (RX)
--    rx_pin -> rx_sync(0) -> rx_sync(1) -> FSM
--    2-FF cascade metastability'yi önler
--
-- 3. START BIT VERIFICATION
--    False trigger (noise spike) önleme:
--    Falling edge tespit -> Half-bit bekle -> Hala '0' mı kontrol et
--
-- 4. SAMPLING POINT
--    Her bit'in ortasında örneklenir (en stabil nokta)
--    BIT_PERIOD - 1 cycle bekle (counter wrap arası)
--
-- 5. TX SHIFT REGISTER FORMAT
--    [9]  [8..1]     [0]
--    STOP DATA(7..0) START
--    LSB first gönderilir (UART standardı)
--
-- 6. FRAMING ERROR HANDLING
--    Stop bit '1' değilse bile paket kabul edilir
--    Gelecek: Error counter eklenebilir (debugging için)
--
-- 7. TX_BUSY SİNYALİ
--    Gearbox'un yeni byte göndermemesi için backpressure
--    tx_busy='1' iken tx_start ignore edilmeli
--
-- 8. RX_VALID SİNYALİ
--    Tek cycle pulse (valid strobe)
--    Gearbox bu sinyali gördüğünde rx_data'yı latch etmeli
--
-- 9. GUILLOTINE (rst_n)
--    pipeline_enable='0' -> Instant shutdown
--    RX/TX FSM IDLE'a döner, veri akışı durur
--
-- 10. SENTEZ SONUÇLARI (Beklenen)
--    LUT: ~100 (FSM + counter)
--    FF: ~40 (state + shift reg + counter)
--    Max Freq: 200+ MHz (simple logic)
--
-- 11. TEST SENARYOSU
--    ```vhdl
--    -- TX Test
--    wait until rising_edge(clk);
--    tx_data <= x"41";  -- 'A'
--    tx_start <= '1';
--    wait until rising_edge(clk);
--    tx_start <= '0';
--    wait until tx_busy = '0';  -- 10 bit × 8.68µs = 86.8µs
--    
--    -- RX Test
--    rx_pin <= '0';  -- Start bit
--    wait for 8.68 us;
--    rx_pin <= '1';  -- LSB of 'A' = 1
--    wait for 8.68 us;
--    -- ... (8 data bits)
--    rx_pin <= '1';  -- Stop bit
--    wait for 8.68 us;
--    assert rx_valid = '1' and rx_data = x"41";
--    ```
--
-- 12. PCCONNECTION (Real Hardware)
--    FTDI FT232H USB-to-UART bridge
--    TX (FPGA) -> RX (FT232H)
--    RX (FPGA) ← TX (FT232H)
--    GND common
--
-- 13. LINUX TERMINAL COMMAND
--    stty -F /dev/ttyUSB0 115200 raw -echo
--    cat /dev/ttyUSB0         # RX monitor
--    echo "test" > /dev/ttyUSB0  # TX send
--------------------------------------------------------------------------------

-- 📡 "CİHAZIN AĞZI VE KULAĞI HAZIR!" 📡

--------------------------------------------------------------------------------
