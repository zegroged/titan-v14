--------------------------------------------------------------------------------
-- PROJECT TITAN V13: SANAL DONANIM (VIRTUAL HARDWARE)
-- Module: External Tamper Detection (XOR + RC Filtre Simülasyonu)
--------------------------------------------------------------------------------
-- AMAÇ: Fiziksel 74VHC86 XOR + 10kΩ/1nF RC devresi davranışını simüle eder.
--        İki FPGA clock çıkışları arasındaki faz farkını tespit eder.
--
-- FİZİKSEL GERÇEK: RC devresinde kondansatör anında deşarj olmaz.
--                  Tau (zaman sabiti) = R × C = 10kΩ × 1nF = 10µs
--
-- KRİTİK: "Leaky Bucket" (Sızdıran Kova) algoritması kullanılır.
--         XOR='1' → Counter artar (+1)
--         XOR='0' → Counter SIFIRLANMAZ, AZALIR (-1)
--         Böylece ardışık kısa gürültüler birikir (fiziksel kondansatör gibi)
--
-- KOMUTAN ŞERHİ: "Sıradan counter sıfırlama kullanırsan, binlerce 1ns spike
--                 sistemi tetiklemez ama gerçek kondansatör tetikler. 
--                 Donanım geldiğinde felaketle karşılaşırsın."
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity module_external_tamper is
    generic (
        -- RC Filtre Parametreleri (Fiziksel: 10kΩ × 1nF = 10µs)
        TAU_NS              : integer := 10_000;  -- Zaman sabiti (nanosaniye)
        THRESHOLD_NS        : integer := 10_000;  -- Tetikleme eşiği
        SIMULATION_TIMESTEP : integer := 10       -- Simülasyon adım süresi (ns)
    );
    port (
        -- İki FPGA'dan gelen clock sinyalleri
        clk_artix7    : in  std_logic;
        clk_polarfire : in  std_logic;
        
        -- Sisteme gönderilen KILL sinyali
        kill_signal   : out std_logic;
        
        -- Debug çıkışları (waveform'da gözlemlemek için)
        xor_output    : out std_logic;        -- Ham XOR çıkışı
        capacitor_voltage : out integer range 0 to 100  -- Sanal kondansatör voltajı (%)
    );
end module_external_tamper;

architecture Behavioral of module_external_tamper is
    -- Sanal Kondansatör Durumu (Leaky Bucket Counter)
    signal bucket_level : integer range -THRESHOLD_NS to THRESHOLD_NS := 0;
    
    -- XOR Gate Çıkışı
    signal internal_xor : std_logic := '0';
    
    -- DONT_TOUCH korumasi (Sentezleyici bu sinyali silmemeli)
    attribute dont_touch : string;
    attribute dont_touch of kill_signal : signal is "true";
    attribute dont_touch of internal_xor : signal is "true";
    
begin
    -- XOR Gate (74VHC86 davranışı)
    internal_xor <= clk_artix7 xor clk_polarfire;
    xor_output <= internal_xor;
    
    -------------------------------------------------------------------------
    -- LEAKY BUCKET PROCESS (RC Devresi Fiziksel Simülasyonu)
    -------------------------------------------------------------------------
    -- Bu process, gerçek RC devresinin "yavaş deşarj" davranışını taklit eder.
    -- Her SIMULATION_TIMESTEP'te bucket_level güncellenir:
    --   XOR='1' → Kondansatör ŞARJ oluyor (+SIMULATION_TIMESTEP)
    --   XOR='0' → Kondansatör DEŞARJ oluyor (-SIMULATION_TIMESTEP)
    -------------------------------------------------------------------------
    process
    begin
        wait for SIMULATION_TIMESTEP * 1 ns;  -- Her 10ns'de bir güncelle
        
        if internal_xor = '1' then
            -- XOR aktif: Kondansatör şarj oluyor
            if bucket_level < THRESHOLD_NS then
                bucket_level <= bucket_level + SIMULATION_TIMESTEP;
            end if;
        else
            -- XOR pasif: Kondansatör deşarj oluyor (Leaky Bucket!)
            if bucket_level > 0 then
                bucket_level <= bucket_level - SIMULATION_TIMESTEP;
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- THRESHOLD DETECTOR (Comparator - LTC1540 davranışı)
    -------------------------------------------------------------------------
    -- Eğer sanal kondansatör voltajı eşiğe ulaşırsa KILL tetiklenir.
    -------------------------------------------------------------------------
    kill_signal <= '1' when bucket_level >= THRESHOLD_NS else '0';
    
    -- Debug: Kondansatör voltajını yüzdeye çevir (waveform görselliği için)
    capacitor_voltage <= (bucket_level * 100) / THRESHOLD_NS when bucket_level > 0 else 0;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. LEAKY BUCKET ALGORİTMASI
--    -> 1000 adet 1ns spike geldiğinde: bucket_level = 1000 * 10ns = 10µs
--    -> Eşiğe ulaşır ve kill_signal tetiklenir.
--    -> Eğer "counter sıfırlanır" yaklaşımı kullansaydık, hiçbir zaman 
--       10µs'ye ulaşamazdı (her spike arasında sıfırlanırdı).
--
-- 2. GERÇEK DONANIMA UYUM
--    -> Tau = 10µs (gerçek RC devresi ile birebir aynı)
--    -> XOR çıkışı sürekli '1' olursa 10µs sonra tetiklenir.
--    -> XOR düşerse kondansatör yavaşça boşalır (anında değil).
--
-- 3. SENTEZLEYİCİ KORUMASI
--    -> 'dont_touch' attribute'u sayesinde Vivado/Libero bu sinyalleri
--       "kullanılmamış" diyerek silemez.
--------------------------------------------------------------------------------
