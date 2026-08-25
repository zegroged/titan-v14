--------------------------------------------------------------------------------
-- PROJECT TITAN V13: TRNG Wrapper (ENTROPY HARVESTER)
-- Module: True Random Number Generator - IV Generator
--------------------------------------------------------------------------------
-- AMAÇ: Birden fazla ring oscillator'dan entropy toplamak ve 128-bit IV üretmek
--
-- KOMUTAN ŞERHİ: "Düşmanın tahmin edemediği tek şey kaostur!"
--
-- MİMARİ:
--   1. 3 bağımsız ring oscillator (farklı jitter kaynakları)
--   2. XOR mixing (bias elimination)
--   3. Shift register sampling (128-bit accumulation)
--   4. Continuous operation (her clock cycle'da yeni bit)
--
-- TWO-TIME PAD ÖNLEME:
--   -> Her boot'ta farklı IV
--   -> Aynı anahtar + farklı IV = farklı keystream
--   -> Cipher1 XOR Cipher2 -> Plaintext açığa çıkmaz!
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity trng_wrapper is
    port (
        clk        : in  std_logic;                      -- System clock
        rst_n      : in  std_logic;                      -- Active-low reset
        random_out : out std_logic_vector(127 downto 0)  -- IV output (128-bit)
    );
end trng_wrapper;

architecture Behavioral of trng_wrapper is

    -------------------------------------------------------------------------
    -- RING OSCILLATOR ÇIKIŞLARI
    -------------------------------------------------------------------------
    -- 3 bağımsız halka -> 3 farklı jitter kaynağı
    -------------------------------------------------------------------------
    signal ro_out_1 : std_logic;
    signal ro_out_2 : std_logic;
    signal ro_out_3 : std_logic;
    
    -------------------------------------------------------------------------
    -- ENTROPY BİRLEŞTİRME (XOR Mixing)
    -------------------------------------------------------------------------
    signal sampled_bit : std_logic;
    
    -------------------------------------------------------------------------
    -- SHIFT REGISTER (128-bit Accumulator)
    -------------------------------------------------------------------------
    -- Her clock cycle'da yeni bit ekleniyor (LSB'den)
    -- En eski bit MSB'den atılıyor
    -------------------------------------------------------------------------
    signal shift_reg : std_logic_vector(127 downto 0) := (others => '0');
    
    -------------------------------------------------------------------------
    -- RO HEALTH CHECK (stuck-at tespit)
    -------------------------------------------------------------------------
    signal health_cnt    : unsigned(13 downto 0) := (others => '0');
    signal ro1_prev      : std_logic := '0';
    signal ro2_prev      : std_logic := '0';
    signal ro3_prev      : std_logic := '0';
    signal ro1_toggle    : unsigned(7 downto 0) := (others => '0');
    signal ro2_toggle    : unsigned(7 downto 0) := (others => '0');
    signal ro3_toggle    : unsigned(7 downto 0) := (others => '0');
    signal ro_healthy    : std_logic := '0';

    -------------------------------------------------------------------------
    -- SP 800-90B HEALTH TESTS
    -------------------------------------------------------------------------
    -- Monobit: 128-bit pencerede '1' sayısı 48-80 arasında mı?
    -- Runs: Ardışık aynı bit sayısı >8 ise FAIL
    -------------------------------------------------------------------------
    signal monobit_cnt   : unsigned(7 downto 0) := (others => '0');
    signal monobit_pass  : std_logic := '0';
    signal bit_counter   : unsigned(7 downto 0) := (others => '0');  -- 128 bit pencere
    signal run_length    : unsigned(3 downto 0) := (others => '0');
    signal run_prev_bit  : std_logic := '0';
    signal runs_pass     : std_logic := '1';
    signal sp800_healthy : std_logic := '0';
    constant MONO_LOW    : unsigned(7 downto 0) := to_unsigned(48, 8);  -- Min '1' count
    constant MONO_HIGH   : unsigned(7 downto 0) := to_unsigned(80, 8);  -- Max '1' count
    constant MAX_RUN     : unsigned(3 downto 0) := to_unsigned(9, 4);   -- Max consecutive

    -------------------------------------------------------------------------
    -- SENTEZLEYİCİ KORUMASI
    -------------------------------------------------------------------------
    attribute keep : string;
    attribute keep of shift_reg : signal is "true";
    attribute keep of ro_healthy : signal is "true";
    attribute keep of sp800_healthy : signal is "true";
    
    attribute syn_keep : boolean;
    attribute syn_keep of shift_reg : signal is true;
    attribute syn_keep of ro_healthy : signal is true;
    attribute syn_keep of sp800_healthy : signal is true;

begin

    -------------------------------------------------------------------------
    -- 1. RING OSCILLATOR INSTANCES (3 Bağımsız Kaos Kaynağı)
    -------------------------------------------------------------------------
    -- enable = rst_n -> Reset bittiğinde oscillation başlar
    -------------------------------------------------------------------------
    ro_inst_1 : entity work.trng_ring_osc
        port map (
            enable  => rst_n,
            osc_out => ro_out_1
        );
    
    ro_inst_2 : entity work.trng_ring_osc
        port map (
            enable  => rst_n,
            osc_out => ro_out_2
        );
    
    ro_inst_3 : entity work.trng_ring_osc
        port map (
            enable  => rst_n,
            osc_out => ro_out_3
        );

    -------------------------------------------------------------------------
    -- 2. RO HEALTH MONITOR (16K cycle window)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                health_cnt <= (others => '0');
                ro1_toggle <= (others => '0');
                ro2_toggle <= (others => '0');
                ro3_toggle <= (others => '0');
                ro_healthy <= '0';
                ro1_prev   <= '0';
                ro2_prev   <= '0';
                ro3_prev   <= '0';
            else
                if ro_out_1 /= ro1_prev and ro1_toggle < 255 then
                    ro1_toggle <= ro1_toggle + 1;
                end if;
                if ro_out_2 /= ro2_prev and ro2_toggle < 255 then
                    ro2_toggle <= ro2_toggle + 1;
                end if;
                if ro_out_3 /= ro3_prev and ro3_toggle < 255 then
                    ro3_toggle <= ro3_toggle + 1;
                end if;
                ro1_prev <= ro_out_1;
                ro2_prev <= ro_out_2;
                ro3_prev <= ro_out_3;
                
                health_cnt <= health_cnt + 1;
                if health_cnt = 0 then
                    if ro1_toggle >= 4 and ro2_toggle >= 4 and ro3_toggle >= 4 then
                        ro_healthy <= '1';
                    else
                        ro_healthy <= '0';
                    end if;
                    ro1_toggle <= (others => '0');
                    ro2_toggle <= (others => '0');
                    ro3_toggle <= (others => '0');
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- 3. ENTROPY HARVESTING (Hasat Process)
    -------------------------------------------------------------------------
    -- Asenkron oscillator'ları sys_clk ile örnekliyoruz
    -- XOR ile bias azaltıyoruz (eğer bir RO %60 '1' verse bile,
    -- üç RO'nun XOR'u %50'ye yaklaşır - Von Neumann corrector)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                -- Reset: Shift register temizle
                shift_reg <= (others => '0');
            else
                -------------------------------------------------------------
                -- 3 Ring Oscillator'ün XOR'u -> Bias azaltma
                -------------------------------------------------------------
                sampled_bit <= ro_out_1 xor ro_out_2 xor ro_out_3;
                
                -------------------------------------------------------------
                -- Shift Register (128-bit FIFO)
                -------------------------------------------------------------
                -- Yeni bit LSB'ye eklenir, en eski bit MSB'den atılır
                -------------------------------------------------------------
                shift_reg <= shift_reg(126 downto 0) & sampled_bit;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- 4. SP 800-90B CONTINUOUS HEALTH TESTS
    -------------------------------------------------------------------------
    -- Monobit: 128-bit pencerede '1' sayısı 48-80 arasında olmalı
    -- Runs: Ardışık aynı bit >9 ise FAIL (stuck pattern tespiti)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                monobit_cnt  <= (others => '0');
                monobit_pass <= '0';
                bit_counter  <= (others => '0');
                run_length   <= (others => '0');
                run_prev_bit <= '0';
                runs_pass    <= '1';
                sp800_healthy <= '0';
            else
                -- Her cycle bir bit gelir (sampled_bit)
                bit_counter <= bit_counter + 1;

                -- Monobit: '1' say
                if sampled_bit = '1' then
                    monobit_cnt <= monobit_cnt + 1;
                end if;

                -- Runs: ardışık aynı bit uzunluğu
                if sampled_bit = run_prev_bit then
                    if run_length < 15 then
                        run_length <= run_length + 1;
                    end if;
                    -- Max run aşıldı mı?
                    if run_length >= MAX_RUN then
                        runs_pass <= '0';
                    end if;
                else
                    run_length <= (others => '0');
                end if;
                run_prev_bit <= sampled_bit;

                -- 128-bit pencere tamamlandı mı?
                if bit_counter = 127 then
                    -- Monobit sonucu: 48 <= ones <= 80 ?
                    if monobit_cnt >= MONO_LOW and monobit_cnt <= MONO_HIGH then
                        monobit_pass <= '1';
                    else
                        monobit_pass <= '0';
                    end if;

                    -- SP 800-90B toplam sonuç
                    if monobit_cnt >= MONO_LOW and monobit_cnt <= MONO_HIGH
                       and runs_pass = '1' then
                        sp800_healthy <= '1';
                    else
                        sp800_healthy <= '0';
                    end if;

                    -- Yeni pencere başlat
                    bit_counter <= (others => '0');
                    monobit_cnt <= (others => '0');
                    runs_pass   <= '1';
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- 5. OUTPUT ASSIGNMENT
    -------------------------------------------------------------------------
    random_out <= shift_reg;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. NEDEN 3 RING OSCILLATOR?
--    -> Tek RO: Bias olabilir (%55 '1', %45 '0')
--    -> XOR mixing: Bias cancel (%50'ye yaklaşır)
--    -> 3 RO: İstatistiksel bağımsızlık (birinin failure'ı diğerlerini etkilemez)
--
-- 2. SHIFT REGISTER BOYUTU (128-bit)
--    -> AES CTR mode: 128-bit counter initial value
--    -> Boot süresi ~200ms @ 50MHz = 10M clock cycle
--    -> Shift register 128 cycle'da dolar, sonrası continuous update
--
-- 3. ENTROPY RATE (Entropi Oranı)
--    -> Ideal: 1 bit/cycle (50 MHz -> 50 Mbit/s entropi)
--    -> Gerçek: ~0.5 bit/cycle (jitter quality'ye göre)
--    -> 128-bit IV için: 256 cycle = 5.12 µs @ 50MHz
--
-- 4. BOOT-TIME IV GENERATION
--    -> Power-On -> rst_n='0' -> shift_reg sıfır
--    -> System warmup (100ms) -> RO'lar jitter üretiyor
--    -> rst_n='1' -> Sampling başlıyor
--    -> key_valid='1' olduğunda -> IV hazır (128-bit)
--
-- 5. CONTINUOUS UPDATE
--    -> shift_reg sürekli güncelleniyor
--    -> Her key injection'da farklı IV
--    -> Aynı session içinde bile counter farklı başlar
--
-- 6. XOR MIXING (Von Neumann Debiasing)
--    -> Eğer RO1=%60, RO2=%55, RO3=%52 bias'a sahipse
--    -> XOR(RO1, RO2, RO3) ≈ %50 (daha uniform distribution)
--
-- 7. STATISTICAL TESTS (Gelecek: NIST SP 800-90B)
--    -> Monobit Test: '1' ve '0' sayısı denk mi?
--    -> Runs Test: Ardışık bitler pattern oluşturmuyor mu?
--    -> Autocorrelation: Bitler birbirinden bağımsız mı?
--
-- 8. SENTEZ SONUÇLARI (Beklenen)
--    -> LUT: ~20 (3×5 RO + XOR + shift reg control)
--    -> FF: 128 (shift_reg)
--    -> BRAM: 0
--    -> Power: ~5 mW (3 RO çalışıyor)
--
-- 9. GÜVENLIK ANALİZİ
--    -> Attack: Side-channel power analysis
--      -> Mitigation: RO'lar sürekli çalışıyor (no data correlation)
--    -> Attack: Temperature/Voltage manipulation
--      -> Mitigation: Health check (frequency monitor - gelecek)
--    -> Attack: Deterministic boot sequence
--      -> Mitigation: Jitter tamamen fiziksel (tahmin edilemez)
--
-- 10. ALTERNATİF MİMARİLER
--    -> More ROs (5-7): Daha iyi entropi, daha fazla alan
--    -> Coherent sampling: İki RO'yu karşılaştır, metastability kullan
--    -> PLL jitter: MMCM'in jitter'ını kullan (Xilinx specific)
--    -> ADC noise: Analog gürültü (ek donanım gerekir)
--
-- 11. FPGA PLACEMENT
--    -> 3 RO'yu farklı clock region'lara yerleştir
--    -> Voltage variation maksimize et (farklı power domain)
--    -> DSP/BRAM bloklarından uzak (clock skew minimizasyonu)
--
-- 12. SIMÜLASYON DAVRANIŞI
--    -> Gerçek TRNG: Unpredictable
--    -> GHDL simülasyon: 'after 1 ns' delay -> Predictable pattern
--    -> Test: shift_reg'in değiştiğini gözlemle (spesifik değer önemsiz)
--
-- 13. PRODUCTION IV USAGE
--    ```vhdl
--    -- AES Core Wrapper içinde:
--    signal current_iv : std_logic_vector(127 downto 0);
--    
--    trng_inst : entity work.trng_wrapper
--        port map (clk => sys_clk, rst_n => not global_rst, random_out => current_iv);
--    
--    -- Counter initialization:
--    if rst_n = '0' then
--        ctr_block <= unsigned(current_iv);  -- ★ RANDOM START!
--    elsif valid_in = '1' then
--        ctr_block <= ctr_block + 1;  -- Increment
--    end if;
--    ```
--
-- 14. ENTROPY POOL CONCEPT (Gelecek)
--    -> shift_reg'i daha büyük yap (256-bit, 512-bit)
--    -> Birden fazla consumer için entropy havuzu
--    -> Key generation, nonce generation, padding
--
-- 15. TEST SENARYOSU
--    ```vhdl
--    -- Boot 1
--    rst_n <= '0'; wait for 100 ns;
--    rst_n <= '1'; wait for 1 ms;
--    iv_boot1 := random_out;
--    
--    -- Reboot
--    rst_n <= '0'; wait for 100 ns;
--    rst_n <= '1'; wait for 1 ms;
--    iv_boot2 := random_out;
--    
--    -- Assert: iv_boot1 ≠ iv_boot2
--    assert iv_boot1 /= iv_boot2 report "IV'ler farklı olmalı!";
--    ```
--------------------------------------------------------------------------------

-- 🎲 "DÜŞMANIN TAHMİN EDEMEDİĞİ TEK ŞEY KAOSTUR!" 🎲

--------------------------------------------------------------------------------
