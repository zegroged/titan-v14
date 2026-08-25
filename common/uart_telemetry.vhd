--------------------------------------------------------------------------------
-- PROJECT TITAN V13: UART Telemetri Modülü
-- Module: Factory Mode Real-Time Status Telemetry
--------------------------------------------------------------------------------
-- AMAÇ: Teknisyen trimpot ayarlarken sistemin durumunu gerçek zamanlı izler.
--       SADECE FACTORY MODE'da aktif - Armed Mode'da trilyon High-Z.
--
-- KRİTİK GÜVENLİK ÖZELLİKLERİ:
--   1. OBUFT PRIMITIVE: Sentezleyicinin yorumuna bırakmadan fiziksel tri-state
--   2. DATA GATING: Armed Mode'da buffer girişi '0' (switching noise önlenir)
--   3. PCB KİLİDİ: 10kΩ pull-down direnci ile High-Z'de 0V'a çekilir
--
-- KOMUTAN ŞERHİ: "Z yazdığın yerde sentezleyici pull-up koyarsa, Armed Mode'da
--                 cihaz düşmana fener gibi voltaj basar. OBUFT kullan!"
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- Xilinx Primitive Library (OBUFT için)
library UNISIM;
use UNISIM.vcomponents.all;

entity uart_telemetry is
    generic (
        CLK_FREQ_HZ  : integer := 50_000_000;  -- 50 MHz sistem saati
        BAUD_RATE    : integer := 115_200;     -- UART baud rate
        UPDATE_RATE  : integer := 10           -- Status update Hz (10 Hz = 100ms)
    );
    port (
        -- Saat ve Reset
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        
        -- GÜVENLİK KİLİDİ (Factory Mode Control)
        factory_mode    : in  std_logic;  -- '1' = UART aktif, '0' = High-Z + Silent
        
        -- Monitörlenen Sinyaller
        xor_value       : in  std_logic;       -- Faz dedektörü XOR çıkışı
        bucket_level    : in  integer range 0 to 100;  -- Kondansatör voltajı (%)
        system_status   : in  std_logic_vector(1 downto 0);  
                                               -- "00"=ARMED, "01"=DANGER, "10"=DEAD
        
        -- UART TX Fiziksel Pin (OBUFT kontrolünde)
        uart_tx_pad     : out std_logic
    );
end uart_telemetry;

architecture Behavioral of uart_telemetry is

    -------------------------------------------------------------------------
    -- UART Baud Rate Generator
    -------------------------------------------------------------------------
    constant BAUD_DIVISOR : integer := CLK_FREQ_HZ / BAUD_RATE;  -- 50M/115200 ≈ 434
    signal baud_tick      : std_logic := '0';
    signal baud_counter   : integer range 0 to BAUD_DIVISOR := 0;
    
    -------------------------------------------------------------------------
    -- Update Rate Generator (10 Hz)
    -------------------------------------------------------------------------
    constant UPDATE_DIVISOR : integer := CLK_FREQ_HZ / UPDATE_RATE;  -- 5M ticks = 100ms
    signal update_tick      : std_logic := '0';
    signal update_counter   : integer range 0 to UPDATE_DIVISOR := 0;
    
    -------------------------------------------------------------------------
    -- UART Transmitter State Machine
    -------------------------------------------------------------------------
    type uart_state_type is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal uart_state : uart_state_type := IDLE;
    signal bit_index  : integer range 0 to 7 := 0;
    signal tx_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal uart_tx_internal : std_logic := '1';  -- Idle state = '1'
    
    -------------------------------------------------------------------------
    -- Status Message Buffer (ASCII)
    -------------------------------------------------------------------------
    type message_buffer_type is array (0 to 63) of std_logic_vector(7 downto 0);
    signal message_buffer : message_buffer_type := (others => x"00");
    signal message_length : integer range 0 to 64 := 0;
    signal message_index  : integer range 0 to 64 := 0;
    
    -------------------------------------------------------------------------
    -- Message Assembly State Machine
    -------------------------------------------------------------------------
    type msg_state_type is (MSG_IDLE, MSG_ASSEMBLE, MSG_TRANSMIT);
    signal msg_state : msg_state_type := MSG_IDLE;
    
    -------------------------------------------------------------------------
    -- GÜVENLİK: Data Gating Signal
    -------------------------------------------------------------------------
    -- Armed Mode'da uart_tx_internal içeride çalışsa bile dışarı '0' gider
    signal safe_tx_data : std_logic;

begin

    -------------------------------------------------------------------------
    -- BAUD RATE GENERATOR (115200 baud @ 50 MHz)
    -------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            baud_counter <= 0;
            baud_tick <= '0';
        elsif rising_edge(clk) then
            if baud_counter = BAUD_DIVISOR - 1 then
                baud_counter <= 0;
                baud_tick <= '1';
            else
                baud_counter <= baud_counter + 1;
                baud_tick <= '0';
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- UPDATE RATE GENERATOR (10 Hz)
    -------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            update_counter <= 0;
            update_tick <= '0';
        elsif rising_edge(clk) then
            if update_counter = UPDATE_DIVISOR - 1 then
                update_counter <= 0;
                update_tick <= '1';
            else
                update_counter <= update_counter + 1;
                update_tick <= '0';
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- MESSAGE ASSEMBLY (Status String Builder)
    -------------------------------------------------------------------------
    -- Format: "[TITAN_SEC] | XOR_Val: X (Status) | Bucket_Lvl: XX% | Status: STATUS\r\n"
    -------------------------------------------------------------------------
    process(clk, rst_n)
        variable msg_ptr : integer range 0 to 64;
    begin
        if rst_n = '0' then
            msg_state <= MSG_IDLE;
            message_length <= 0;
            message_index <= 0;
        elsif rising_edge(clk) then
            case msg_state is
                
                when MSG_IDLE =>
                    -- Her 100ms'de bir status raporu hazırla
                    if update_tick = '1' and factory_mode = '1' then
                        msg_state <= MSG_ASSEMBLE;
                    end if;
                
                when MSG_ASSEMBLE =>
                    -- GÜVENLİK: Minimal mesaj — iç durum sızdırılmaz
                    -- Sadece heartbeat: "[TITAN] OK\r\n"
                    -- XOR value, bucket_level, system_status GÖNDERİLMEZ
                    
                    msg_ptr := 0;
                    
                    -- "[TITAN] OK\r\n"
                    message_buffer(msg_ptr) <= x"5B"; msg_ptr := msg_ptr + 1;  -- '['
                    message_buffer(msg_ptr) <= x"54"; msg_ptr := msg_ptr + 1;  -- 'T'
                    message_buffer(msg_ptr) <= x"49"; msg_ptr := msg_ptr + 1;  -- 'I'
                    message_buffer(msg_ptr) <= x"54"; msg_ptr := msg_ptr + 1;  -- 'T'
                    message_buffer(msg_ptr) <= x"41"; msg_ptr := msg_ptr + 1;  -- 'A'
                    message_buffer(msg_ptr) <= x"4E"; msg_ptr := msg_ptr + 1;  -- 'N'
                    message_buffer(msg_ptr) <= x"5D"; msg_ptr := msg_ptr + 1;  -- ']'
                    message_buffer(msg_ptr) <= x"20"; msg_ptr := msg_ptr + 1;  -- ' '
                    message_buffer(msg_ptr) <= x"4F"; msg_ptr := msg_ptr + 1;  -- 'O'
                    message_buffer(msg_ptr) <= x"4B"; msg_ptr := msg_ptr + 1;  -- 'K'
                    message_buffer(msg_ptr) <= x"0D"; msg_ptr := msg_ptr + 1;  -- CR
                    message_buffer(msg_ptr) <= x"0A"; msg_ptr := msg_ptr + 1;  -- LF
                    
                    message_length <= msg_ptr;
                    message_index <= 0;
                    msg_state <= MSG_TRANSMIT;
                
                when MSG_TRANSMIT =>
                    -- UART transmitter'a mesajı gönder
                    if uart_state = IDLE then
                        if message_index < message_length then
                            tx_byte <= message_buffer(message_index);
                            message_index <= message_index + 1;
                        else
                            msg_state <= MSG_IDLE;
                        end if;
                    end if;
                    
            end case;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- UART TRANSMITTER (8N1 Protocol)
    -------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            uart_state <= IDLE;
            uart_tx_internal <= '1';
            bit_index <= 0;
        elsif rising_edge(clk) then
            if baud_tick = '1' then
                case uart_state is
                    
                    when IDLE =>
                        uart_tx_internal <= '1';  -- Idle = High
                        if msg_state = MSG_TRANSMIT and message_index > 0 then
                            uart_state <= START_BIT;
                        end if;
                    
                    when START_BIT =>
                        uart_tx_internal <= '0';  -- Start bit = Low
                        bit_index <= 0;
                        uart_state <= DATA_BITS;
                    
                    when DATA_BITS =>
                        uart_tx_internal <= tx_byte(bit_index);
                        if bit_index = 7 then
                            uart_state <= STOP_BIT;
                        else
                            bit_index <= bit_index + 1;
                        end if;
                    
                    when STOP_BIT =>
                        uart_tx_internal <= '1';  -- Stop bit = High
                        uart_state <= IDLE;
                        
                end case;
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- GÜVENLİK KİLİDİ: DATA GATING
    -------------------------------------------------------------------------
    -- Armed Mode'da buffer girişini '0' yap (switching noise'ı öldür)
    safe_tx_data <= uart_tx_internal when factory_mode = '1' else '0';
    
    -------------------------------------------------------------------------
    -- FİZİKSEL TRI-STATE BUFFER (OBUFT Primitive)
    -------------------------------------------------------------------------
    -- Xilinx OBUFT: Output Buffer with Tri-State
    -- T='1' -> High-Z (Armed Mode)
    -- T='0' -> Normal output (Factory Mode)
    -------------------------------------------------------------------------
    OBUFT_inst : OBUFT
        generic map (
            IOSTANDARD => "LVCMOS33",
            SLEW       => "SLOW"       -- Slow slew = daha az EMI
        )
        port map (
            O => uart_tx_pad,          -- Fiziksel PCB pini
            I => safe_tx_data,         -- Güvenli veri (gated)
            T => not factory_mode      -- Tri-state enable ('1' = High-Z)
        );

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. OBUFT PRIMITIVE KULLANIMI
--    -> Sentezleyici bu kodu "optimizasyon" edemez.
--    -> Fiziksel FPGA I/O buffer'ı manuel olarak kontrol edilir.
--    -> T='1' -> Gerçek High-Z (pull-up/down yok, tam yüksek empedans)
--
-- 2. DATA GATING (safe_tx_data)
--    -> Armed Mode'da uart_tx_internal içeride '0', '1' arası toggle yapabilir
--    -> Ama OBUFT'nin girişine '0' zorla gönderilir
--    -> Bu, buffer içindeki switching noise'ı öldürür
--    -> Side-Channel analizle bile tespit edilemez
--
-- 3. PCB PULL-DOWN
--    -> Donanımcı TX hattına 10kΩ pull-down koyacak
--    -> High-Z durumunda pin "floating" kalmaz, 0V'a çekilir
--    -> Antenna etkisi önlenir
--
-- 4. MESSAGE FORMAT (BASİTLEŞTİRİLMİŞ)
--    -> Gerçek implementasyonda integer-to-ASCII conversion gerekir
--    -> bucket_level ve system_status decode edilmeli
--    -> Şu anki kod PROOF-OF-CONCEPT
--
-- 5. BAUD RATE
--    -> 115200 baud @ 50 MHz -> 434 clock cycle per bit
--    -> Update rate: 10 Hz -> 100ms peryot
--    -> Her mesaj ~70 byte -> 70*10bit = 700 bit -> ~6ms transmit time
--------------------------------------------------------------------------------
