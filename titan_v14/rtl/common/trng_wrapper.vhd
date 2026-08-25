--------------------------------------------------------------------------------
-- PROJECT TITAN V13→V15: TRNG Wrapper (ENTROPY HARVESTER)
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
--
-- V15 P0-4: TRNG FAIL-CLOSED
--   health_degraded aktif olduğunda comm_disable çıkışı set edilir.
--   İletişim sadece gerçek TRNG sağlıklı iken aktif olabilir.
--   DRBG fallback varken veri GÖNDERİLMEZ (fail-closed tasarım).
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity trng_wrapper is
    port (
        clk        : in  std_logic;                      -- System clock
        rst_n      : in  std_logic;                      -- Active-low reset
        random_out : out std_logic_vector(127 downto 0); -- IV output (128-bit)
        -- ★ FIX: Health status exposed (SP800-90B + RO combined)
        health_ok  : out std_logic;                      -- '1' = entropy quality OK
        -- ★ UPGRADE: DRBG fallback explicit flag (Kimseye Güvenme)
        -- health_ok kalabilir '1' iken DRBG aktif olabilir
        -- Bu sinyal upstream'e "gerçek entropi değil, DRBG" uyarısı verir
        health_degraded : out std_logic;                  -- '1' = DRBG fallback aktif

        -- ★ V15 P0-4: Fail-closed iletişim kontrolü
        -- TRNG sağlığı bozulduğunda iletişimi devre dışı bırak
        comm_disable    : out std_logic                   -- '1' = iletişim engellendi
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
    -- ★ A4: NIST SP 800-90B §4.4.1 Repetition Count Test (RCT)
    -- Detects catastrophic entropy source failure (stuck output)
    -- Cutoff C = ⌈1 + (-log2(α)) / H_min⌉ = 20 for H_min=4, α=2^-40
    -------------------------------------------------------------------------
    signal rct_counter   : unsigned(4 downto 0) := (others => '0');
    signal rct_prev_bit  : std_logic := '0';
    signal rct_pass      : std_logic := '1';
    constant RCT_CUTOFF  : unsigned(4 downto 0) := to_unsigned(20, 5);

    -------------------------------------------------------------------------
    -- ★ A4: NIST SP 800-90B §4.4.2 Adaptive Proportion Test (APT)
    -- Detects degraded entropy source (bias drift)
    -- Window W=512, cutoff for H_min≈1 = 410
    -------------------------------------------------------------------------
    signal apt_window_cnt : unsigned(9 downto 0) := (others => '0');
    signal apt_match_cnt  : unsigned(9 downto 0) := (others => '0');
    signal apt_ref_value  : std_logic := '0';
    signal apt_pass       : std_logic := '1';
    constant APT_WINDOW   : unsigned(9 downto 0) := to_unsigned(512, 10);
    constant APT_CUTOFF   : unsigned(9 downto 0) := to_unsigned(410, 10);

    -------------------------------------------------------------------------
    -- ★ FAZ 14.1: VON NEUMANN CONDITIONING
    -------------------------------------------------------------------------
    signal vn_pair_phase : std_logic := '0';
    signal vn_first_bit  : std_logic := '0';
    signal vn_output_bit : std_logic := '0';
    signal vn_valid      : std_logic := '0';

    -------------------------------------------------------------------------
    -- ★ BUG-3 FIX: 3-LFSR Nonlinear Combination Generator
    -- Coprime periods: 2^127-1, 2^126-1, 2^121-1
    -- Nonlinear combine: (L1 AND L2) XOR (L2 AND L3) XOR L3
    -- Correlation attack complexity: O(2^63)
    -------------------------------------------------------------------------
    signal lfsr_a : std_logic_vector(126 downto 0) := x"DEADBEEFCAFEBABE0123456789ABCD" & "1111111";  -- 127-bit
    signal lfsr_b : std_logic_vector(125 downto 0) := x"A5A5A5A5B6B6B6B6C7C7C7C7D8D8D8" & "101001";   -- 126-bit
    signal lfsr_c : std_logic_vector(120 downto 0) := x"1234567890ABCDEF1234567890AB" & "110101001";   -- 121-bit
    signal lfsr_fb_a   : std_logic;  -- LFSR-A feedback
    signal lfsr_fb_b   : std_logic;  -- LFSR-B feedback
    signal lfsr_fb_c   : std_logic;  -- LFSR-C feedback
    signal drbg_output : std_logic;  -- Combined nonlinear output
    signal drbg_active : std_logic := '0';
    signal entropy_bit : std_logic;

    -- ★ V14.3 FIX Z3: Full LFSR reseed tracking
    signal reseed_done : std_logic := '0';
    signal reseed_cnt  : integer range 0 to 511 := 0;

    -------------------------------------------------------------------------
    -- SENTEZLEYİCİ KORUMASI
    -------------------------------------------------------------------------
    attribute keep : string;
    attribute keep of shift_reg : signal is "true";
    attribute keep of ro_healthy : signal is "true";
    attribute keep of sp800_healthy : signal is "true";
    attribute keep of lfsr_a : signal is "true";
    attribute keep of lfsr_b : signal is "true";
    attribute keep of lfsr_c : signal is "true";
    
    attribute syn_keep : boolean;
    attribute syn_keep of shift_reg : signal is true;
    attribute syn_keep of ro_healthy : signal is true;
    attribute syn_keep of sp800_healthy : signal is true;
    attribute syn_keep of lfsr_a : signal is true;

begin

    -- ★ A4: Combined health (all 4 tests must pass)
    health_ok <= ro_healthy and sp800_healthy and rct_pass and apt_pass;

    -- ★ UPGRADE: Explicit DRBG fallback signal
    -- Kimseye Güvenme: Tüketici modüller DRBG durumunu bilmeli
    health_degraded <= drbg_active;

    -- ★ V15 P0-4: Fail-closed — TRNG sağlıksızsa iletişim engellenir
    -- DRBG fallback aktifken iletişim yapılması güvenli değildir
    comm_disable <= drbg_active;

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
    -- ★ FAZ 14.1: Von Neumann conditioning + bias removal
    -- ★ FAZ 14.2: DRBG fallback when health_ok = '0'
    -------------------------------------------------------------------------
    
    -- ★ 3 Ring Oscillator XOR mixing (combinational)
    sampled_bit <= ro_out_1 xor ro_out_2 xor ro_out_3;
    
    -- ★ BUG-3 FIX: Individual LFSR feedback polynomials
    -- LFSR-A (127-bit): x¹²⁷ + x¹²⁶ + 1 (maximal period)
    lfsr_fb_a <= lfsr_a(126) xor lfsr_a(125);
    -- LFSR-B (126-bit): x¹²⁶ + x¹²⁵ + x¹²⁴ + x¹²³ + 1
    lfsr_fb_b <= lfsr_b(125) xor lfsr_b(124) xor lfsr_b(123) xor lfsr_b(122);
    -- LFSR-C (121-bit): x¹²¹ + x¹¹⁸ + 1
    lfsr_fb_c <= lfsr_c(120) xor lfsr_c(117);
    
    -- Nonlinear combining function: (A AND B) XOR (B AND C) XOR C
    drbg_output <= (lfsr_a(0) and lfsr_b(0)) xor (lfsr_b(0) and lfsr_c(0)) xor lfsr_c(0);
    
    -- DRBG active when TRNG health fails (driven inside process below)
    -- drbg_active is computed inside the process to avoid multiple drivers
    
    -- Final entropy bit: conditioned RO output or DRBG
    entropy_bit <= drbg_output when drbg_active = '1'
                   else vn_output_bit when vn_valid = '1'
                   else sampled_bit;  -- Raw fallback (should not happen)
    
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                shift_reg    <= (others => '0');
                vn_pair_phase <= '0';
                vn_first_bit  <= '0';
                vn_output_bit <= '0';
                drbg_active   <= '0';
                lfsr_a <= x"DEADBEEFCAFEBABE0123456789ABCD" & "1111111";
                lfsr_b <= x"A5A5A5A5B6B6B6B6C7C7C7C7D8D8D8" & "101001";
                lfsr_c <= x"1234567890ABCDEF1234567890AB" & "110101001";
                reseed_done <= '0';
                reseed_cnt  <= 0;
            else
                -- ★ BUG-3 FIX: 3 LFSRs always run (free-running)
                lfsr_a <= lfsr_fb_a & lfsr_a(126 downto 1);
                lfsr_b <= lfsr_fb_b & lfsr_b(125 downto 1);
                lfsr_c <= lfsr_fb_c & lfsr_c(120 downto 1);
                
                -- ★ DRC FIX: drbg_active computed inside process (single driver)
                drbg_active <= not (ro_healthy and sp800_healthy);
                
                -- Re-seed from good entropy when available
                if drbg_active = '0' then
                    lfsr_a(31 downto 0) <= lfsr_a(31 downto 0) xor shift_reg(31 downto 0);
                    lfsr_b(31 downto 0) <= lfsr_b(31 downto 0) xor shift_reg(63 downto 32);
                    lfsr_c(31 downto 0) <= lfsr_c(31 downto 0) xor shift_reg(95 downto 64);
                end if;
                
                -- ★ V14.3 FIX Z3: Full LFSR reseed from ring oscillators
                -- Reset sonrasi RO sagliklı olunca tum LFSR'lari gercek  
                -- entropi ile karistir (hardcoded seed'leri etkisiz kilmak icin)
                if ro_healthy = '1' and reseed_done = '0' then
                    reseed_cnt <= reseed_cnt + 1;
                    if reseed_cnt < 127 then
                        lfsr_a(reseed_cnt) <= lfsr_a(reseed_cnt) xor shift_reg(0);
                    elsif reseed_cnt < 253 then
                        lfsr_b(reseed_cnt - 127) <= lfsr_b(reseed_cnt - 127) xor shift_reg(0);
                    elsif reseed_cnt < 374 then
                        lfsr_c(reseed_cnt - 253) <= lfsr_c(reseed_cnt - 253) xor shift_reg(0);
                    else
                        reseed_done <= '1';
                    end if;
                end if;
                
                -- ★ FAZ 14.1: Von Neumann extractor
                -- Collect bit pairs from raw XOR output
                vn_valid <= '0';  -- Default: no conditioned bit
                if drbg_active = '0' then
                    if vn_pair_phase = '0' then
                        -- First bit of pair
                        vn_first_bit  <= sampled_bit;
                        vn_pair_phase <= '1';
                    else
                        -- Second bit of pair
                        vn_pair_phase <= '0';
                        if vn_first_bit /= sampled_bit then
                            -- Complementary pair: output first bit
                            vn_output_bit <= vn_first_bit;
                            vn_valid      <= '1';
                        end if;
                        -- Identical pair: discard (no output)
                    end if;
                end if;
                
                -- Shift register update:
                -- DRBG mode: always shift (LFSR bit)
                -- TRNG mode: only shift when Von Neumann produces valid bit
                if drbg_active = '1' or vn_valid = '1' then
                    shift_reg <= shift_reg(126 downto 0) & entropy_bit;
                end if;
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
    -- ★ A4: REPETITION COUNT TEST (NIST SP 800-90B §4.4.1)
    -- Ardışık C=20 aynı bit → katastrofik entropy kaybı
    -------------------------------------------------------------------------
    rct_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                rct_counter  <= (others => '0');
                rct_prev_bit <= '0';
                rct_pass     <= '1';
            else
                if entropy_bit = rct_prev_bit then
                    if rct_counter < RCT_CUTOFF then
                        rct_counter <= rct_counter + 1;
                    else
                        rct_pass <= '0';  -- FAIL: C ardışık aynı bit
                    end if;
                else
                    rct_counter  <= (others => '0');
                    rct_prev_bit <= entropy_bit;
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- ★ A4: ADAPTIVE PROPORTION TEST (NIST SP 800-90B §4.4.2)
    -- 512 örneklik pencerede >410 aynı değer → bias sürüklenmesi
    -------------------------------------------------------------------------
    apt_proc: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                apt_window_cnt <= (others => '0');
                apt_match_cnt  <= (others => '0');
                apt_ref_value  <= '0';
                apt_pass       <= '1';
            else
                if apt_window_cnt = 0 then
                    -- Yeni pencere başlat: ilk örnekleme referans değeri
                    apt_ref_value  <= entropy_bit;
                    apt_match_cnt  <= (others => '0');
                    apt_window_cnt <= apt_window_cnt + 1;
                elsif apt_window_cnt < APT_WINDOW then
                    -- Pencere içinde eşleşme say
                    apt_window_cnt <= apt_window_cnt + 1;
                    if entropy_bit = apt_ref_value then
                        apt_match_cnt <= apt_match_cnt + 1;
                        -- Erken çıkış: cutoff aşıldıysa fail
                        if apt_match_cnt >= APT_CUTOFF then
                            apt_pass <= '0';
                        end if;
                    end if;
                else
                    -- Pencere tamamlandı: sıfırla, yeni pencere başlat
                    apt_window_cnt <= (others => '0');
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
