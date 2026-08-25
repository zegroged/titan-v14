--------------------------------------------------------------------------------
-- PROJECT TITAN V13: Crypto Core Stub (Kukla Hedef)
-- Module: Dummy Cryptographic Core for Synthesis Load Testing
--------------------------------------------------------------------------------
-- AMAÇ: Sentezleyiciye FANOUT yükü bindirmek ve KILL sinyalinin gerçek
--       register'lara etkisini test etmek.
--
-- STRATEJI: İçi boş ama ağır bir kutu. 256-bit devasa register bank ile
--          KILL sinyalinin tüm flip-flop'lara eşzamanlı ulaşmasını test et.
--
-- KOMUTAN ŞERHİ: "Gerçek AES çekirdeği yok ama sentez aracı 256 tane FF
--                 resetlediğimizi görmel i. DONT_TOUCH ile korunacak!"
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity crypto_core_stub is
    port (
        clk         : in  std_logic;
        kill_signal : in  std_logic;  -- ASYNC CLEAR (Ş ah Damarı!)
        data_out    : out std_logic_vector(255 downto 0)
    );
end crypto_core_stub;

architecture Behavioral of crypto_core_stub is

    -------------------------------------------------------------------------
    -- 256-BIT MASTER KEY (Kukla Kripto Anahtarı)
    -------------------------------------------------------------------------
    -- Varsayılan: Hepsi '1' (Anahtar mevcut demek)
    -- KILL geldiğinde: Hepsi '0' (Anahtar yok edildi)
    -------------------------------------------------------------------------
    signal master_key : std_logic_vector(255 downto 0) := (others => '1');
    
    -------------------------------------------------------------------------
    -- SENTEZLEYİCİ KORUMASI (ÇAPRAZ PLATFORM)
    -------------------------------------------------------------------------
    -- Vivado/Libero "Bu register hiç okunmuyor, gereksiz" diyebilir.
    -- XILINX: DONT_TOUCH ve KEEP ile korunuyor
    -- MICROCHIP: syn_keep ve syn_preserve ile korunuyor
    -------------------------------------------------------------------------
    -- Xilinx Attributes (Vivado)
    attribute keep : string;
    attribute keep of master_key : signal is "true";
    
    attribute dont_touch : string;
    attribute dont_touch of master_key : signal is "true";
    
    -- Microchip/Synplify Attributes (Libero)
    attribute syn_keep : boolean;
    attribute syn_keep of master_key : signal is true;
    
    attribute syn_preserve : boolean;
    attribute syn_preserve of master_key : signal is true;

begin

    -------------------------------------------------------------------------
    -- ASENKRON İMHA MEKANİZMASI
    -------------------------------------------------------------------------
    -- KILL sinyali geldiğinde clock beklemeden ANINDA sil!
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        -- ASENKRON CLEAR: kill_signal='1' -> Tüm bitler '0'
        if kill_signal = '1' then
            master_key <= (others => '0');  -- ANINDA SİL!
            
        -- SENKRON İŞLEM: Normal çalışma
        elsif rising_edge(clk) then
            -- Normal operasyon: Veriyi tut (değiştirme)
            master_key <= master_key;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- ÇIKIŞ PORTUNocument (Telemetri Hack İçin)
    -------------------------------------------------------------------------
    -- Anahtarın MSB'si telemetriye gidecek.
    -- MSB='1' -> Anahtar Hayatta
    -- MSB='0' -> Anahtar İmha Edilmiş
    -------------------------------------------------------------------------
    data_out <= master_key;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. FANOUT YÜK TESTİ
--    -> 256 flip-flop tek bir KILL sinyali ile resetleniyor
--    -> BUFG kullanımı bu yükte kritik (Skew <500ps gerekli)
--
-- 2. ASENKRON CLEAR
--    -> kill_signal process sensitivity listinde
--    -> kill_signal='1' olduğunda clock beklemeden hemen temizlik
--    -> Gerçek FPGA'da: master_key_reg/CLR pinine bağlanır
--
-- 3. DONT_TOUCH + KEEP KORUMASI
--    -> Vivado "Optimization Strategy: Performance_ExploreWithRemap" bile
--      bu register'ları silemez
--    -> Sentez sonrası Hierarchy Report'ta görünmeliler
--
-- 4. TELEMETRİ HACK
--    -> master_key(255) -> uart_telemetry'nin xor_value girişine
--    -> UART'tan "XOR_Val: 1" -> Anahtar hayatta
--    -> UART'tan "XOR_Val: 0" -> Anahtar silindi (KILL tetiklendi)
--
-- 5. GERÇEKİ FPGA'DA BEKLENEN DAVRANI Ş
--    -> KILL_PIN=0: master_key tüm '1'ler
--    -> KILL_PIN=1: ~2 clock cycle sonra master_key tüm '0'lar
--    -> Timing Report: KILL_PIN -> master_key_reg[*]/CLR path <6ns
--------------------------------------------------------------------------------
