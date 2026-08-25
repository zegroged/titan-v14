--------------------------------------------------------------------------------
-- PROJECT TITAN V14.1: SPI Key Loader V3 (ENCRYPTED TRANSFER + SPLIT-KEY)
-- Module: Hardened Volatile Key Injection via Encrypted SPI Protocol
--------------------------------------------------------------------------------
-- V14 → V14.1 DEĞİŞİKLİKLERİ:
--   ★ Anahtar artık SPI'da cleartext AKMAZ
--   ★ İki-fazlı protokol: Nonce (128-bit) + Encrypted Key (256-bit)
--   ★ spi_key_unwrap modülü: Transport Key ile çözme
--   ★ Çözülmüş anahtar hala TRNG split-key XOR ile korunur
--
-- PROTOKOL:
--   Phase A: SPI transfer 128-bit → Nonce
--   Phase B: SPI transfer 256-bit → Encrypted Key (AES-CTR(SK, RealKey))
--   Unwrap:  Session Key = AES(TK, Nonce), Key = AES-CTR-Dec(SK, EncKey)
--   Final:   key_latched = Plain_Key XOR (TRNG & TRNG)
--
-- GÜVENLİK ÖZELLİKLERİ (V14'ten korunan):
--   → 30-saniye injection window (1.5×10^9 cycle)
--   → 3-strike lockout + kill trigger
--   → Dead-man timer (CS aktif sınırı)
--   → kill_signal → tüm register'lar anında sıfırlanır
--   → Factory jumper gating
--   → TRNG split-key XOR
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity key_loader_spi is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        kill_signal  : in  std_logic;  -- ★ ACİL DURUMDA YÜKLEYİCİYİ DE SİL ★
        
        -- SPI Arayüzü (Dış Dünyadan Gelir - Fill Gun)
        spi_sclk     : in  std_logic;  -- SPI Clock (Harici)
        spi_mosi     : in  std_logic;  -- Master Out Slave In
        spi_cs_n     : in  std_logic;  -- Chip Select (Active Low)
        
        -- TRNG Split-Key Input (FPGA internal — dışarıya sızmaz)
        trng_key_part : in  std_logic_vector(127 downto 0);
        
        -- ★ V14.1: Transport Key (eFUSE'dan — şimdilik constant)
        transport_key : in  std_logic_vector(255 downto 0);
        
        -- ★ V14.1: TRNG mask for dedicated AES core
        trng_mask     : in  std_logic_vector(127 downto 0);
        
        -- Security Control
        jumper_calib : in  std_logic;  -- '1'=Factory, '0'=Armed
        
        -- Çıkış (secure_key_storage'a gider)
        key_out      : out std_logic_vector(255 downto 0);
        key_valid    : out std_logic;  -- '1' = Anahtar yüklenmiş ve geçerli
        
        -- Kill trigger output (3-strike veya dead-man)
        key_kill_trigger : out std_logic  -- → kill chain OR'a bağlanır
    );
end key_loader_spi;

architecture Behavioral of key_loader_spi is

    -------------------------------------------------------------------------
    -- SHIFT REGISTER (256-bit SPI RX Buffer)
    -------------------------------------------------------------------------
    signal shift_reg    : std_logic_vector(255 downto 0) := (others => '0');
    signal key_latched  : std_logic_vector(255 downto 0) := (others => '0');
    signal valid_flag   : std_logic := '0';
    signal bit_cnt      : integer range 0 to 256 := 0;
    signal fail_count   : unsigned(1 downto 0) := "00";
    signal lockout      : std_logic := '0';
    
    -- CDC Synchronization (3-stage)
    signal sclk_sync    : std_logic_vector(2 downto 0) := "000";
    signal cs_sync      : std_logic_vector(2 downto 0) := "111";
    signal mosi_sync    : std_logic_vector(2 downto 0) := "000";
    
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sclk_sync : signal is "TRUE";
    attribute ASYNC_REG of cs_sync   : signal is "TRUE";
    attribute ASYNC_REG of mosi_sync : signal is "TRUE";
    
    -------------------------------------------------------------------------
    -- INJECTION WINDOW (30 saniye — 1.5 × 10^9 cycle @50MHz)
    -------------------------------------------------------------------------
    signal window_cnt   : unsigned(30 downto 0) := (others => '0');
    signal window_open  : std_logic := '1';
    constant WINDOW_LIMIT : unsigned(30 downto 0) := 
        to_unsigned(1_500_000_000, 31);
    
    -------------------------------------------------------------------------
    -- DEAD-MAN TIMER (CS aktifken sayar — 500ms max)
    -------------------------------------------------------------------------
    signal deadman_cnt  : unsigned(24 downto 0) := (others => '0');
    signal deadman_trip : std_logic := '0';
    constant DEADMAN_LIMIT : unsigned(24 downto 0) := 
        to_unsigned(25_000_000, 25);  -- 500ms @ 50MHz
    
    -------------------------------------------------------------------------
    -- KILL TRIGGER
    -------------------------------------------------------------------------
    signal kill_trig_int : std_logic := '0';
    
    -------------------------------------------------------------------------
    -- ARMED MODE SPI GATING
    -------------------------------------------------------------------------
    signal spi_gated_cs  : std_logic;
    signal spi_allowed   : std_logic;
    
    -------------------------------------------------------------------------
    -- ★ V14.1: TWO-PHASE PROTOCOL
    -------------------------------------------------------------------------
    type rx_phase_t is (RX_NONCE, RX_ENC_KEY);
    signal rx_phase : rx_phase_t := RX_NONCE;
    
    -- Nonce register (128-bit, Phase A output)
    signal nonce_latched    : std_logic_vector(127 downto 0) := (others => '0');
    signal nonce_ready      : std_logic := '0';
    
    -- Encrypted key register (256-bit, Phase B output)
    signal enc_key_latched  : std_logic_vector(255 downto 0) := (others => '0');
    signal enc_key_ready    : std_logic := '0';
    
    -- Unwrap interface
    signal unwrap_key_out   : std_logic_vector(255 downto 0);
    signal unwrap_ready     : std_logic;
    signal unwrap_fail      : std_logic;
    signal unwrap_busy      : std_logic;
    
    -------------------------------------------------------------------------
    -- DONT_TOUCH for security
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of key_latched : signal is "true";
    attribute dont_touch of valid_flag  : signal is "true";
    attribute dont_touch of window_cnt  : signal is "true";
    attribute dont_touch of nonce_latched  : signal is "true";
    attribute dont_touch of enc_key_latched : signal is "true";
    
    attribute keep : string;
    attribute keep of key_latched : signal is "true";
    attribute keep of valid_flag  : signal is "true";

begin

    -- SPI allowed = factory mode AND window open AND not locked out AND not already keyed
    spi_allowed <= jumper_calib and window_open and (not lockout) and (not valid_flag);
    
    -------------------------------------------------------------------------
    -- ★ V14.1: SPI KEY UNWRAP INSTANCE
    -------------------------------------------------------------------------
    u_unwrap : entity work.spi_key_unwrap
        port map (
            clk           => clk,
            rst_n         => rst_n,
            kill_signal   => kill_signal,
            transport_key => transport_key,
            trng_mask     => trng_mask,
            nonce_in      => nonce_latched,
            nonce_valid   => nonce_ready,
            enc_key_in    => enc_key_latched,
            enc_key_valid => enc_key_ready,
            plain_key_out => unwrap_key_out,
            key_ready     => unwrap_ready,
            unwrap_fail   => unwrap_fail,
            busy          => unwrap_busy
        );

    -------------------------------------------------------------------------
    -- INJECTION WINDOW TIMER
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            window_cnt  <= (others => '0');
            window_open <= '0';
        elsif rising_edge(clk) then
            if rst_n = '0' then
                window_cnt  <= (others => '0');
                window_open <= '1';
            else
                if window_open = '1' then
                    if window_cnt >= WINDOW_LIMIT then
                        window_open <= '0';
                    else
                        window_cnt <= window_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- DEAD-MAN TIMER (CS_N düşükken sayar)
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            deadman_cnt  <= (others => '0');
            deadman_trip <= '0';
        elsif rising_edge(clk) then
            if rst_n = '0' then
                deadman_cnt  <= (others => '0');
                deadman_trip <= '0';
            else
                if cs_sync(2) = '0' then
                    if deadman_cnt >= DEADMAN_LIMIT then
                        deadman_trip <= '1';
                    else
                        deadman_cnt <= deadman_cnt + 1;
                    end if;
                else
                    deadman_cnt <= (others => '0');
                end if;
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- ★ V14.1: TWO-PHASE SPI RECEIVER + UNWRAP KEY LATCH
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            shift_reg       <= (others => '0');
            key_latched     <= (others => '0');
            nonce_latched   <= (others => '0');
            enc_key_latched <= (others => '0');
            valid_flag      <= '0';
            bit_cnt         <= 0;
            sclk_sync       <= "000";
            cs_sync         <= "111";
            mosi_sync       <= "000";
            fail_count      <= "00";
            lockout         <= '0';
            kill_trig_int   <= '0';
            rx_phase        <= RX_NONCE;
            nonce_ready     <= '0';
            enc_key_ready   <= '0';
            
        elsif rising_edge(clk) then
            if rst_n = '0' then
                valid_flag      <= '0';
                bit_cnt         <= 0;
                shift_reg       <= (others => '0');
                nonce_latched   <= (others => '0');
                enc_key_latched <= (others => '0');
                sclk_sync       <= "000";
                cs_sync         <= "111";
                mosi_sync       <= "000";
                fail_count      <= "00";
                lockout         <= '0';
                kill_trig_int   <= '0';
                rx_phase        <= RX_NONCE;
                nonce_ready     <= '0';
                enc_key_ready   <= '0';
            else
                -- ★ H-2 FIX: 3-stage CDC Synchronization
                sclk_sync <= sclk_sync(1 downto 0) & spi_sclk;
                cs_sync   <= cs_sync(1 downto 0)   & spi_cs_n;
                mosi_sync <= mosi_sync(1 downto 0) & spi_mosi;
                
                -- Default: clear one-shot signals
                nonce_ready   <= '0';
                enc_key_ready <= '0';
                
                -- ★ UNWRAP DONE: Transfer key from unwrap to key_latched
                if unwrap_ready = '1' and valid_flag = '0' then
                    key_latched <= unwrap_key_out xor
                                   (trng_key_part & trng_key_part);
                    valid_flag  <= '1';
                    fail_count  <= "00";
                end if;
                
                -- ★ UNWRAP FAIL: Count as failed attempt
                if unwrap_fail = '1' then
                    if fail_count = "10" then  -- 3. deneme
                        lockout       <= '1';
                        kill_trig_int <= '1';
                    else
                        fail_count <= fail_count + 1;
                    end if;
                    rx_phase <= RX_NONCE;  -- Reset protocol
                end if;
                
                -- ★ SPI GEÇİTLEME: Armed modda pencere kapanmışsa → yoksay
                if spi_allowed = '1' then
                    
                    -- CS rising edge detection (priority)
                    if cs_sync(2 downto 1) = "01" then
                        -- CS just deasserted → evaluate transfer
                        
                        case rx_phase is
                            -- Phase A: Nonce (128-bit)
                            when RX_NONCE =>
                                if bit_cnt = 128 then
                                    nonce_latched <= shift_reg(127 downto 0);
                                    nonce_ready   <= '1';
                                    rx_phase      <= RX_ENC_KEY;
                                else
                                    -- Wrong bit count = fail
                                    if fail_count = "10" then
                                        lockout       <= '1';
                                        kill_trig_int <= '1';
                                    else
                                        fail_count <= fail_count + 1;
                                    end if;
                                end if;
                                
                            -- Phase B: Encrypted Key (256-bit)
                            when RX_ENC_KEY =>
                                if bit_cnt = 256 then
                                    enc_key_latched <= shift_reg;
                                    enc_key_ready   <= '1';
                                    -- Don't advance rx_phase yet —
                                    -- wait for unwrap to complete
                                else
                                    -- Wrong bit count = fail
                                    if fail_count = "10" then
                                        lockout       <= '1';
                                        kill_trig_int <= '1';
                                    else
                                        fail_count <= fail_count + 1;
                                    end if;
                                    rx_phase <= RX_NONCE;  -- Reset protocol
                                end if;
                        end case;
                        
                        bit_cnt <= 0;
                        
                    elsif cs_sync(2) = '0' then
                        -- CS Aktif → Transfer devam
                        if sclk_sync(2 downto 1) = "01" then  -- Rising edge
                            shift_reg <= shift_reg(254 downto 0) & mosi_sync(1);
                            if bit_cnt < 256 then
                                bit_cnt <= bit_cnt + 1;
                            end if;
                        end if;
                        
                    end if;
                    
                end if;  -- spi_allowed
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- OUTPUT ASSIGNMENT
    -------------------------------------------------------------------------
    key_out          <= key_latched;
    key_valid        <= valid_flag;
    key_kill_trigger <= kill_trig_int or deadman_trip;

end Behavioral;
