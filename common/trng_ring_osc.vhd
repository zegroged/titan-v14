--------------------------------------------------------------------------------
-- PROJECT TITAN V13: Ring Oscillator (KAOS KAYNAĞI)
-- Module: True Random Number Generator - Entropy Source
--------------------------------------------------------------------------------
-- AMAÇ: FPGA'nın fiziksel gürültüsünden (Jitter) rastgele sayı üretmek.
--
-- KOMUTAN ŞERHİ: "Tanrı zar atmaz, ama biz atmak zorundayız!"
--
-- FİZİKSEL PRENSİP:
--   1. Tek sayıda inverter'ı halka şeklinde bağla
--   2. Halka teoride sonsuz hızda döner
--   3. Pratikte tel gecikmeleri ve sıcaklık değişkenliği "Jitter" yaratır
--   4. Bu jitter tahmin edilemez -> Gerçek rastgelelik!
--
-- KRİTİK UYARI: COMBINATORIAL LOOP (Simülasyonda 'after 1 ns' gerekli)
--   -> Sentezleyici (Vivado/Libero) bunu "hata" sanıp silmeye çalışır
--   -> Synthesis attribute'ları ile korunmalı!
--
-- GÜVENLİK ANALİZİ:
--   - Deterministik PRNG (Pseudo-Random) değil
--   - Gerçek fiziksel kaos kaynağı (TRNG)
--   - Düşman öngöremez (Thermal noise, voltage fluctuation)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity trng_ring_osc is
    port (
        enable  : in  std_logic;  -- '1' = Halka dönüyor, '0' = Durdu
        osc_out : out std_logic   -- Osilatör çıkışı (kaotik toggling)
    );
end trng_ring_osc;

architecture Behavioral of trng_ring_osc is

    -------------------------------------------------------------------------
    -- HALKA UZUNLUĞU (ODD NUMBER - Tek Sayı Zorunlu!)
    -------------------------------------------------------------------------
    -- Çift sayıda inverter -> Halka kilitlenir (stable state)
    -- Tek sayıda inverter -> Sürekli osilasyon
    -------------------------------------------------------------------------
    constant RO_LENGTH : integer := 5;  -- 5-stage ring (iyi jitter)
    
    -------------------------------------------------------------------------
    -- İNVERTER ZİNCİRİ
    -------------------------------------------------------------------------
    signal chain : std_logic_vector(RO_LENGTH-1 downto 0) := (others => '0');
    
    -------------------------------------------------------------------------
    -- SENTEZLEYİCİ KORUMASI (Synthesis Protection)
    -------------------------------------------------------------------------
    -- Xilinx Vivado Attributes
    attribute keep : string;
    attribute keep of chain : signal is "true";
    
    attribute dont_touch : string;
    attribute dont_touch of chain : signal is "true";
    
    -- Microchip Libero Attributes
    attribute syn_keep : boolean;
    attribute syn_keep of chain : signal is true;
    
    attribute syn_preserve : boolean;
    attribute syn_preserve of chain : signal is true;
    
    -------------------------------------------------------------------------
    -- LUT PLACEMENT CONSTRAINT (Daha fazla jitter için)
    -------------------------------------------------------------------------
    -- Her inverter farklı bir LUT'a yerleştirilirse, tel uzunlukları
    -- farklı olur -> Daha fazla jitter -> Daha iyi entropi
    -------------------------------------------------------------------------
    -- NOT: Bu attribute'lar .xdc/.pdc dosyasında da tekrar edilmeli!

begin

    -------------------------------------------------------------------------
    -- RING OSCILLATOR LOGIC (Kombinasyonel Döngü)
    -------------------------------------------------------------------------
    -- chain(0) ← enable AND NOT chain(last)
    -- chain(i) ← NOT chain(i-1)
    -------------------------------------------------------------------------
    -- UYARI: 'after 1 ns' sadece GHDL simülasyonu için!
    --        Gerçek sentezde bu, tel gecikmesidir (propagation delay).
    -------------------------------------------------------------------------
    gen_ro: process(enable, chain)
    begin
        ---------------------------------------------------------------------
        -- İlk Eleman (Başlatıcı/Durdurucu)
        ---------------------------------------------------------------------
        -- enable='0' -> chain(0)='0' -> Halka durur
        -- enable='1' -> chain(0) = NOT chain(last) -> Halka döner
        ---------------------------------------------------------------------
        chain(0) <= (not chain(RO_LENGTH-1)) and enable after 1 ns;
        
        ---------------------------------------------------------------------
        -- Diğer Elemanlar (Inverter Zinciri)
        ---------------------------------------------------------------------
        for i in 1 to RO_LENGTH-1 loop
            chain(i) <= not chain(i-1) after 1 ns;
        end loop;
    end process;

    -------------------------------------------------------------------------
    -- OUTPUT (Halkadan Entropi Hasat Et)
    -------------------------------------------------------------------------
    -- Son elemanı dışarı ver, oscillation frequency ~ GHz (FPGA'ya göre)
    -------------------------------------------------------------------------
    osc_out <= chain(RO_LENGTH-1);

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. COMBINATORIAL LOOP (Neden Yasak ve Neden Bilerek Yapıyoruz?)
--    -> Senkron tasarımda döngü -> Setup/hold violation -> Hata
--    -> TRNG'de döngü -> Jitter kaynağı -> Özellik!
--    -> Sentezleyici bunu "mantık hatası" sanır, keep/dont_touch ile korunmalı
--
-- 2. RING OSCILLATOR FREQUENCY
--    -> f_osc ≈ 1 / (2 * N * t_pd)
--    -> N = stage sayısı (5)
--    -> t_pd = inverter propagation delay (~100 ps @ 7nm FPGA)
--    -> f_osc ≈ 1 GHz (FPGA'ya göre değişir)
--
-- 3. JITTER (Kaos Kaynağı)
--    -> Thermal noise (Sıcaklık dalgalanması)
--    -> Voltage fluctuation (VDD güç kaynağı gürültüsü)
--    -> Process variation (Chip'teki üretim farklılıkları)
--    -> Cross-talk (Komşu tellerin etkisi)
--    -> Bu jitter tahmin edilemez -> Gerçek rastgelelik!
--
-- 4. ENABLE LOGIC
--    -> enable='0' -> Halka durur (power save + reset)
--    -> enable='1' -> Halka döner (entropy generation)
--    -> Boot sırasında enable=rst_n olabilir (reset bitince dön)
--
-- 5. SENTEZ SONUÇLARI (Beklenen)
--    -> LUT: 5 (her inverter bir LUT)
--    -> FF: 0 (tamamen kombinasyonel)
--    -> Critical Path: Yok (döngü sonsuz)
--    -> Power: ~1-5 mW (sürekli toggle)
--
-- 6. ENTROPY QUALITY (Kalite)
--    -> Single RO: Düşük kalite (bias olabilir)
--    -> Multiple RO + XOR: Yüksek kalite (bias cancel)
--    -> Statistical test: NIST SP 800-90B (gelecek)
--
-- 7. TIMING CONSTRAINTS (Kısıtlamalar)
--    -> .xdc (Vivado):
--      set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets *chain*]
--      set_property SEVERITY {WARNING} [get_drc_checks LUTLP-1]
--    -> .pdc (Libero):
--      set_attribute {trng_ring_osc:chain[*]} preserve 1
--      set_attribute {trng_ring_osc:chain[*]} keep_hierarchy true
--
-- 8. PLACEMENT SUGGESTION
--    -> Farklı FPGA bölgelerine dağıt (PBLOCK)
--    -> Her RO farklı voltage region'da (daha fazla jitter)
--    -> Clock tree'den uzak tut (clock skew'dan etkilenmesin)
--
-- 9. GÜVENLIK KONSİDERASYONLARI
--    -> Side-Channel: Power analysis ile RO frequency tahmin edilebilir mi?
--      -> Mitigation: Birden fazla RO + XOR mixing
--    -> Temperature Attack: Isıtıcı ile jitter azaltılabilir mi?
--      -> Mitigation: Health check (frequency monitor)
--    -> Voltage Glitch: VDD spike ile RO durdurulabilir mi?
--      -> Mitigation: Watchdog (oscillation detector)
--
-- 10. ALTERNATIF MİMARİLER
--    -> Fibonacci RO: Daha uzun halka (daha çok jitter)
--    -> Transient RO: Geçici durum (power-on jitter)
--    -> Coherent sampling: İki RO'yu karşılaştır (metastability)
--
-- 11. SIMÜLASYON DAVRANIŞI
--    -> 'after 1 ns' delay ile oscillation simüle edilir
--    -> Gerçek hardware'de bu delay yoktur (tel gecikmesi vardır)
--    -> GHDL waveform'da chain sinyallerinin toggle'ı görülür
--
-- 12. TEST SENARYOSU
--    ```vhdl
--    -- Enable = '0' -> Durdu
--    enable <= '0';
--    wait for 100 ns;
--    assert osc_out = '0' report "Enable=0 iken durmalı!";
--    
--    -- Enable = '1' -> Dönüyor
--    enable <= '1';
--    wait for 100 ns;
--    -- osc_out toggle'lar (simülasyonda 1 ns period'la)
--    
--    -- Entropy örnekle (sys_clk ile)
--    for i in 0 to 127 loop
--        wait until rising_edge(sys_clk);
--        random_bit(i) <= osc_out;  -- Her clock'ta farklı bit
--    end loop;
--    ```
--------------------------------------------------------------------------------

-- 🎲 "KAOS BİZİM DOSTUMUZDUR!" 🎲

--------------------------------------------------------------------------------
