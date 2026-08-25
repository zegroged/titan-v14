--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Artix-7 Top Module (OMURGA) -- REVİZYON 3
-- Module: Full System Integration with AEGIS + Omega Cloak + PVT Monitor
--------------------------------------------------------------------------------
-- V13 -> V14 DEĞİŞİKLİKLER:
--   [NEW] 13. AEGIS AI Anomaly Detection (ESN + Readout + Anomaly)
--   [NEW] 14. OMEGA CLOAK DPA Protection (PRNG + Jitter + Dummy Ops)
--   [NEW] 15. PVT Monitor (Ring Osc Freq Counter × 4)
--   [MOD] 7.  Kill trigger: +aegis_anomaly_irq +pvt_alarm
--   [MOD] 9.  AES: +omega_cloak wrapper (stall + chaos)
--   [MOD] 10. Telemetry: +pvt_data, +omega status
--
-- GERİYE UYUMLULUK: V13 tüm fonksiyonalitesi korunmuştur.
--                    Yeni modüller omega_enable=0 ile devre dışı bırakılabilir.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity artix7_top_v14 is
    generic (
        -- ★ 5.1 FIX: Golden hash for firmware integrity (two-pass build)
        -- Pass 1: default 0x0 → FI fails but gated by system_ready
        -- Pass 2: golden_hash_update.tcl overrides via synth_design -generic
        GOLDEN_HASH_DEFAULT : std_logic_vector(255 downto 0) :=
            x"0000_0000_0000_0000_0000_0000_0000_0000"
          & x"0000_0000_0000_0000_0000_0000_0000_0000"
    );
    port (
        -- ======= V13 MEVCUT PİNLER (DOKUNULMADI) =======

        -- Harici Saat (50 MHz - SiTime SiT5356 + Prescaler)
        PIN_EXT_CLK_50MHZ : in  std_logic;

        -- Güvenlik Sinyalleri
        KILL_PIN          : in  std_logic;   -- Tamper dedektör çıkışı
        JUMPER_CALIB      : in  std_logic;   -- Factory/Armed mode seçici

        -- Dual-FPGA Lockstep (FAZ 6: Mutual Watchdog)
        PF_HEARTBEAT_IN   : in  std_logic;   -- PolarFire'dan gelen nabız
        PF_KILL_CMD       : out std_logic;   -- PolarFire'ı öldürme komutu

        -- SPI Key Injection (FAZ 8)
        SPI_SCLK_PIN      : in  std_logic;
        SPI_MOSI_PIN      : in  std_logic;
        SPI_CS_N_PIN      : in  std_logic;

        -- UART Data Pipeline (FAZ 10: RED/BLACK Interface)
        UART_RX_PIN       : in  std_logic;   -- PC -> FPGA (Plaintext)
        UART_TX_PIN       : out std_logic;   -- FPGA -> PC (Ciphertext)

        -- UART Telemetri
        UART_TX_PAD       : out std_logic;   -- OBUFT kontrolünde

        -- Durum LED'leri
        LED_STATUS_RED    : out std_logic;   -- Tamper tespit edildi
        LED_STATUS_GREEN  : out std_logic;   -- Heartbeat (canlılık)

        -- ======= V14 YENİ PİNLER =======

        -- PVT Monitor: 4 Ring Oscillator girişi (farklı FPGA bölgelerinden)
        RING_OSC_IN       : in  std_logic_vector(3 downto 0);

        -- AEGIS/Omega kontrol (DIP switch veya register)
        OMEGA_ENABLE_PIN  : in  std_logic;   -- Omega Cloak master switch
        AEGIS_ENABLE_PIN  : in  std_logic;   -- AEGIS AI anomaly detection

        -- V14 Durum LED'leri
        LED_OMEGA_ACTIVE  : out std_logic;   -- DPA koruması aktif
        LED_POST_FAIL     : out std_logic;   -- POST self-test FAIL

        -- ======= SECURE COMM PİNLER (Phase 10b) =======

        -- BLACK UART (Şifreli kanal — diğer cihaza bağlanır)
        BLACK_UART_RX_PIN  : in  std_logic;   -- Şifreli veri giriş
        BLACK_UART_TX_PIN  : out std_logic;   -- Şifreli veri çıkış

        -- V15 CALLWHITE: BLACK UART Akış Kontrolü (MCU backpressure)
        BLACK_UART_CTS_PIN : in  std_logic;   -- MCU -> FPGA: '1' = DUR
        BLACK_UART_RTS_PIN : out std_logic;   -- FPGA -> MCU: '1' = bekle

        -- İletişim modu (DIP switch)
        COMM_MODE_PIN     : in  std_logic;   -- '0'=TX (şifrele), '1'=RX (çöz)

        -- ======= HİDRA SPI COMMAND BRIDGE (Faz 2) =======
        SPI_APP_CS_N_PIN  : in  std_logic;   -- App Processor CS (ayrı pin)
        SPI_MISO_PIN      : out std_logic    -- MISO: FPGA → App Processor
    );
end artix7_top_v14;

architecture Behavioral of artix7_top_v14 is

    -------------------------------------------------------------------------
    -- V13 MEVCUT SİNYALLER (DOKUNULMADI)
    -------------------------------------------------------------------------
    signal sys_clk          : std_logic;
    signal pll_locked       : std_logic;
    signal system_ready     : std_logic;
    signal global_rst       : std_logic;
    signal global_rst_n     : std_logic;  -- ★ A-1 FIX: Intermediate for VHDL-93 port maps

    signal kill_active      : std_logic;
    signal safe_kill        : std_logic;
    signal factory_mode     : std_logic;
    signal crypto_data      : std_logic_vector(255 downto 0);
    signal system_halted    : std_logic;

    -- Dual-FPGA
    signal pf_watchdog_kill : std_logic;
    signal all_kill_sources : std_logic;

    -- Volatile Key
    signal loaded_key       : std_logic_vector(255 downto 0);
    signal key_is_valid     : std_logic;
    signal aes_reset_gated  : std_logic;

    -- ★ V14.3 FIX Z1: HMAC Key Derivation (KDF)
    -- HMAC key ≠ AES key — loaded_key XOR OPAD sabiti ile türetilir
    -- Bu sayede HMAC DPA sızdırsa bile AES key güvende kalır
    signal hmac_derived_key : std_logic_vector(255 downto 0);

    -- TRNG
    signal trng_iv          : std_logic_vector(127 downto 0);

    -- Data Pipeline (RED side)
    signal rx_byte, tx_byte : std_logic_vector(7 downto 0);
    signal rx_valid, tx_start, tx_busy : std_logic;
    signal pt_128, ct_128   : std_logic_vector(127 downto 0);
    signal pt_valid         : std_logic;  -- ct_valid moved to CDC section (FIX #2)
    signal pipeline_enable  : std_logic;

    -- Data Pipeline (BLACK side)
    signal blk_rx_byte, blk_tx_byte : std_logic_vector(7 downto 0);
    signal blk_rx_valid, blk_tx_start, blk_tx_busy : std_logic;

    -- Comm Protocol signals
    signal proto_aes_pt     : std_logic_vector(127 downto 0);
    signal proto_aes_pt_vld : std_logic;
    signal proto_aes_ct     : std_logic_vector(127 downto 0);
    signal proto_aes_ct_vld : std_logic;
    signal proto_red_tx_byte : std_logic_vector(7 downto 0);
    signal proto_red_tx_start : std_logic;
    signal proto_session    : std_logic;
    signal proto_mac_err    : std_logic;
    signal proto_frame_err  : std_logic;
    signal proto_aes_dir    : std_logic;  -- ★ FAZ 13.2: AES direction
    signal comm_mode_meta   : std_logic := '0'; -- ★ FIX #5: CDC stage 1 (metastability absorber)
    signal comm_mode_sync   : std_logic := '0'; -- ★ FIX #5: CDC stage 2 (stable output)

    -- ★ FIX #5: ASYNC_REG → Vivado places both FFs in same slice (max MTBF)
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of comm_mode_meta : signal is "TRUE";
    attribute ASYNC_REG of comm_mode_sync : signal is "TRUE";

    signal post_pass         : std_logic;
    signal post_fail         : std_logic;
    signal post_running      : std_logic;
    signal post_trng_healthy : std_logic;  -- POST module's own TRNG health (separate driver)
    signal trng_healthy      : std_logic;  -- driven by trng_wrapper.health_ok ONLY
    signal trng_degraded     : std_logic;  -- ★ P1-3: DRBG fallback uyarısı
    signal trng_comm_disable : std_logic;  -- ★ V15 P0-4: TRNG fail-closed → comm disable

    -- Watchdog Telemetri
    signal wdt_fail_count    : std_logic_vector(1 downto 0);  -- ★ P1-4
    signal wdt_grace_active  : std_logic;                     -- ★ P1-4

    -- RAM
    signal ram_addr         : std_logic_vector(15 downto 0);
    signal ram_data         : std_logic_vector(7 downto 0);
    signal ram_we           : std_logic;

    -- Telemetri
    signal telemetry_xor_hack : std_logic;

    -- Heartbeat
    signal heartbeat_cnt    : integer range 0 to 25_000_000 := 0;
    signal heartbeat_led    : std_logic := '0';

    -------------------------------------------------------------------------
    -- V14 YENİ SİNYALLER
    -------------------------------------------------------------------------

    -- AEGIS (AI Anomaly Detection)
    signal aegis_anomaly_irq : std_logic;
    signal aegis_tdata       : std_logic_vector(15 downto 0);
    signal aegis_tvalid      : std_logic;
    signal aegis_tready      : std_logic;
    signal aegis_config_addr : std_logic_vector(7 downto 0);
    signal aegis_config_data : std_logic_vector(15 downto 0);
    signal aegis_config_we   : std_logic;

    -- Omega Cloak (DPA Protection)
    signal omega_chaos_out   : std_logic_vector(31 downto 0);
    signal omega_chaos_valid : std_logic;
    signal omega_stall       : std_logic;
    signal omega_dummy_active: std_logic;
    signal omega_jittered_clk: std_logic;
    signal omega_sys_clk_buf : std_logic;
    signal omega_mmcm_locked : std_logic;
    signal omega_stat_dummies: std_logic_vector(15 downto 0);
    signal omega_stat_rounds : std_logic_vector(15 downto 0);
    signal omega_dummy_count : std_logic_vector(1 downto 0);  -- omega_cloak_top output (2-bit)
    signal omega_dummy_count_aes : std_logic_vector(15 downto 0);  -- aes_core_wrapper output (16-bit)
    signal omega_dummy_active_sig : std_logic;  -- ★ P2-7: telemetri
    signal omega_prng_seed_load : std_logic;

    -- ★ C-7 FIX: BUFGMUX_CTRL clock select signal
    signal aes_clk              : std_logic;
    signal omega_clk_sel        : std_logic;  -- '1' = jittered, '0' = sys_clk
    -- CDC: ct_valid crosses from aes_clk → sys_clk domain
    signal ct_valid_aes_domain  : std_logic;  -- raw output from AES (aes_clk domain)
    signal ct_valid_meta        : std_logic := '0';  -- CDC stage 1
    signal ct_valid             : std_logic := '0';  -- CDC stage 2 (safe in sys_clk)
    attribute ASYNC_REG of ct_valid_meta : signal is "TRUE";
    attribute ASYNC_REG of ct_valid      : signal is "TRUE";

    -- AES round signaling (for dummy op injector)
    signal aes_round_start   : std_logic;

    -- PVT Monitor
    signal pvt_alarm         : std_logic;
    signal pvt_sensor_alarms : std_logic_vector(3 downto 0);
    signal pvt_data          : std_logic_vector(15 downto 0);
    signal pvt_valid         : std_logic;
    signal pvt_tready        : std_logic;
    signal pvt_raw_avg       : std_logic_vector(23 downto 0);

    -- TRNG seed for Omega Cloak (reuse ring oscillator entropy)
    signal trng_seed_32      : std_logic_vector(31 downto 0);

    -- ★ V14.2: Split-key kill trigger + AES fault/timeout detection
    signal key_kill_trigger  : std_logic;
    signal aes_fault         : std_logic;

    -- ★ V14.1: Transport Key (eFUSE placeholder for encrypted SPI transfer)
    constant TRANSPORT_KEY : std_logic_vector(255 downto 0) :=
        x"0123456789ABCDEF_FEDCBA9876543210_DEADBEEFCAFEBABE_1337FACE7007F00D";
    signal aes_timeout       : std_logic;  -- ★ AES core stall → kill chain

    -------------------------------------------------------------------------
    -- ★ P0-1: GLITCH DETECTOR SİNYALLERİ
    -------------------------------------------------------------------------
    signal glitch_alarm      : std_logic;
    signal glitch_count      : std_logic_vector(7 downto 0);

    -------------------------------------------------------------------------
    -- ★ P0-2: FIRMWARE INTEGRITY SİNYALLERİ
    -------------------------------------------------------------------------
    signal fi_pass           : std_logic;
    signal fi_fail           : std_logic;
    signal fi_busy           : std_logic;
    signal fi_cfg_addr       : std_logic_vector(15 downto 0);
    signal fi_cfg_data       : std_logic_vector(31 downto 0);
    signal fi_cfg_valid      : std_logic;
    signal fi_cfg_read_req   : std_logic;
    -- Config memory stub: POST sırasında CRC-32 doğrulama
    -- Gerçek sentezde ICAP/MCAP bağlanır, simülasyonda sabit
    signal fi_start          : std_logic := '0';

    -------------------------------------------------------------------------
    -- HİDRA SPI COMMAND BRIDGE SİNYALLERİ (Faz 2)
    -------------------------------------------------------------------------
    signal cmd_aes_pt       : std_logic_vector(127 downto 0);
    signal cmd_aes_pt_valid : std_logic;
    signal cmd_kill_trigger : std_logic;
    signal cmd_active       : std_logic;
    signal cmd_error        : std_logic;
    signal cmd_heartbeat_ok : std_logic;
    -- ★ P2-6: SPI → AEGIS config bridge
    signal cmd_aegis_cfg_addr : std_logic_vector(7 downto 0);
    signal cmd_aegis_cfg_data : std_logic_vector(15 downto 0);
    signal cmd_aegis_cfg_wr   : std_logic;
    -- ★ 7.3: SPI error sticky latch (100ms pulse stretcher)
    signal spi_error_sticky   : std_logic := '0';
    signal spi_error_timer    : integer range 0 to 5_000_000 := 0;
    -- ★ 7.1: AES Input MUX + CDC signals
    -- Holding register (sys_clk domain)
    signal spi_pt_holding      : std_logic_vector(127 downto 0) := (others => '0');
    signal spi_pt_req_toggle   : std_logic := '0';  -- toggles on new data
    signal spi_pt_busy         : std_logic := '0';  -- buffer occupied
    -- CDC sync (aes_clk domain)
    signal spi_pt_req_meta     : std_logic := '0';
    signal spi_pt_req_sync     : std_logic := '0';
    signal spi_pt_req_prev     : std_logic := '0';  -- edge detector
    signal spi_pt_captured     : std_logic_vector(127 downto 0) := (others => '0');
    signal spi_pt_valid_aes    : std_logic := '0';  -- 1-cycle pulse in aes_clk
    signal spi_pt_ack_toggle   : std_logic := '0';  -- ack back to sys_clk
    -- CDC ack sync (sys_clk domain)
    signal spi_pt_ack_meta     : std_logic := '0';
    signal spi_pt_ack_sync     : std_logic := '0';
    signal spi_pt_ack_prev     : std_logic := '0';
    -- MUX output
    signal aes_pt_muxed        : std_logic_vector(127 downto 0);
    signal aes_pt_valid_muxed  : std_logic;
    -- CDC attributes
    attribute ASYNC_REG of spi_pt_req_meta  : signal is "TRUE";
    attribute ASYNC_REG of spi_pt_req_sync  : signal is "TRUE";
    attribute ASYNC_REG of spi_pt_ack_meta  : signal is "TRUE";
    attribute ASYNC_REG of spi_pt_ack_sync  : signal is "TRUE";

    -------------------------------------------------------------------------
    -- ★ P3-9: HMAC HEARTBEAT CONTROLLER SİNYALLERİ
    -------------------------------------------------------------------------
    signal hmac_hb_ok          : std_logic;
    signal hmac_hb_fail        : std_logic;
    signal hmac_hb_busy        : std_logic;
    signal hmac_challenge      : std_logic_vector(127 downto 0);
    signal hmac_challenge_valid: std_logic;
    signal hmac_response       : std_logic_vector(255 downto 0);
    signal hmac_response_valid : std_logic;
    signal hmac_combined_ok    : std_logic;
    signal pvt_all_valid        : std_logic;  -- ★ P3: PVT lockstep informational

begin

    -- ★ A-1 FIX: VHDL-93 intermediate signal (expressions illegal in port maps)
    global_rst_n <= not global_rst;

    -------------------------------------------------------------------------
    -- ★ V14.3 FIX Z1: Key Derivation Function (KDF)
    -- HMAC key = loaded_key XOR OPAD (0x5C repeated)
    -- Combinational — sıfır latency, her zaman güncel
    -------------------------------------------------------------------------
    kdf_gen: for i in 0 to 7 generate
        hmac_derived_key(i*32+31 downto i*32) <=
            loaded_key(i*32+31 downto i*32) xor x"5C5C5C5C";
    end generate;

    -------------------------------------------------------------------------
    -- BÖLÜM A: V13 MEVCUT MODÜLLER (DOKUNULMADI)
    -------------------------------------------------------------------------

    -------------------------------------------------------------------------
    -- 1. CLOCK INFRASTRUCTURE (MMCM + LOCKED)
    -------------------------------------------------------------------------
    clk_inst : entity work.artix7_clocking
        port map (
            clk_in_50mhz => PIN_EXT_CLK_50MHZ,
            sys_clk      => sys_clk,
            pll_locked   => pll_locked
        );

    -------------------------------------------------------------------------
    -- 2. SYSTEM SUPERVISOR (Emniyet Mandalı)
    -------------------------------------------------------------------------
    supervisor_inst : entity work.system_supervisor
        port map (
            clk        => sys_clk,
            pll_locked => pll_locked,
            post_pass  => post_pass,
            post_fail  => post_fail,
            system_rdy => system_ready,
            global_rst => global_rst
        );

    -------------------------------------------------------------------------
    -- 2b. POST SELF-TEST (FIPS 140-3: AES KAT + TRNG Health)
    -------------------------------------------------------------------------
    post_inst : entity work.post_self_test
        port map (
            clk          => sys_clk,
            rst_n        => global_rst_n,
            post_pass    => post_pass,
            post_fail    => post_fail,
            post_running => post_running,
            trng_data    => trng_iv,
            trng_healthy => post_trng_healthy  -- DRC FIX: separate signal from trng_wrapper.health_ok
        );

    -------------------------------------------------------------------------
    -- 3. DATA PIPELINE (FAZ 10b: SECURE COMM — RED/BLACK Fiziksel Ayrım)
    -------------------------------------------------------------------------
    pipeline_enable <= global_rst_n and key_is_valid;

    -- ★ FIX #5: COMM_MODE 2-Stage CDC Synchronizer (endüstri standardı)
    -- DIP switch asenkron → metastabilite riski → 2-FF ile güvenli senkronizasyon
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            comm_mode_meta <= COMM_MODE_PIN;  -- Stage 1: metastability absorber
            comm_mode_sync <= comm_mode_meta; -- Stage 2: safe to use
        end if;
    end process;

    -- RED UART (PC tarafı — sadece plaintext)
    uart_red_inst : entity work.uart_driver
        generic map (CLK_FREQ => 50_000_000, BAUD_RATE => 115_200)
        port map (
            clk      => sys_clk,
            rst_n    => pipeline_enable,
            rx_pin   => UART_RX_PIN,
            tx_pin   => UART_TX_PIN,
            rx_data  => rx_byte,
            rx_valid => rx_valid,
            tx_data  => proto_red_tx_byte,
            tx_start => proto_red_tx_start,
            tx_busy  => tx_busy
        );

    -- BLACK UART (Şifreli kanal — V15: 921600 baud + CTS/RTS)
    uart_black_inst : entity work.uart_driver
        generic map (CLK_FREQ => 50_000_000, BAUD_RATE => 921_600)
        port map (
            clk      => sys_clk,
            rst_n    => pipeline_enable,
            rx_pin   => BLACK_UART_RX_PIN,
            tx_pin   => BLACK_UART_TX_PIN,
            cts_n    => BLACK_UART_CTS_PIN,
            rts_n    => open,  -- RTS uart seviyesinde kullanılmıyor
            rx_data  => blk_rx_byte,
            rx_valid => blk_rx_valid,
            tx_data  => blk_tx_byte,
            tx_start => blk_tx_start,
            tx_busy  => blk_tx_busy
        );

    -- V15 CALLWHITE: RTS — TX meşgulken MCU'yu durdur
    BLACK_UART_RTS_PIN <= blk_tx_busy;

    -- SECURE COMMUNICATION PROTOCOL
    comm_proto_inst : entity work.comm_protocol
        port map (
            clk            => sys_clk,
            rst_n          => pipeline_enable,
            kill_signal    => safe_kill,
            mode           => comm_mode_sync,
            -- RED side (PC)
            red_rx_byte    => rx_byte,
            red_rx_valid   => rx_valid,
            red_tx_byte    => proto_red_tx_byte,
            red_tx_start   => proto_red_tx_start,
            red_tx_busy    => tx_busy,
            -- BLACK side (Encrypted channel)
            blk_rx_byte    => blk_rx_byte,
            blk_rx_valid   => blk_rx_valid,
            blk_tx_byte    => blk_tx_byte,
            blk_tx_start   => blk_tx_start,
            blk_tx_busy    => blk_tx_busy,
            -- AES engine
            aes_pt_out     => pt_128,
            aes_pt_valid   => pt_valid,
            aes_ct_in      => ct_128,
            aes_ct_valid   => ct_valid,
            -- IV (unused — deterministic derivation in AES wrapper)
            derived_iv     => trng_iv,
            -- ★ V15 P0-1: TRNG IV for nonce seeding
            trng_iv        => trng_iv,
            -- Status
            session_active => proto_session,
            mac_error      => proto_mac_err,
            frame_error    => proto_frame_err,
            -- ★ FAZ 13.2: AES direction
            aes_direction  => proto_aes_dir
        );

    -------------------------------------------------------------------------
    -- 4. TRNG IV GENERATOR (FAZ 9)
    -------------------------------------------------------------------------
    trng_inst : entity work.trng_wrapper
        port map (
            clk             => sys_clk,
            rst_n           => global_rst_n,
            random_out      => trng_iv,
            health_ok       => trng_healthy,
            health_degraded => trng_degraded,  -- ★ P1-3: DRBG fallback → telemetri
            comm_disable    => trng_comm_disable  -- ★ V15 P0-4: fail-closed
        );

    -- TRNG seed for Omega Cloak: lower 32 bits of IV
    trng_seed_32 <= trng_iv(31 downto 0);

    -------------------------------------------------------------------------
    -- 5. VOLATILE KEY LOADER (FAZ 8: SPI)
    -------------------------------------------------------------------------
    loader_inst : entity work.key_loader_spi
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            kill_signal      => safe_kill,
            spi_sclk         => SPI_SCLK_PIN,
            spi_mosi         => SPI_MOSI_PIN,
            spi_cs_n         => SPI_CS_N_PIN,
            -- ★ V14.2: Split-key + security hardening
            trng_key_part    => trng_iv,          -- TRNG->split key XOR
            -- ★ V14.1: Encrypted SPI key transfer
            transport_key    => TRANSPORT_KEY,     -- eFUSE placeholder
            trng_mask        => trng_iv,           -- AES mask (shared TRNG)
            jumper_calib     => JUMPER_CALIB,      -- Factory/Armed mode
            key_out          => loaded_key,
            key_valid        => key_is_valid,
            key_kill_trigger => key_kill_trigger   -- 3-strike/dead-man->kill
        );

    -------------------------------------------------------------------------
    -- 5b. SPI COMMAND SLAVE (HİDRA Faz 2: App Processor Bridge)
    -------------------------------------------------------------------------
    -- Shares the SPI bus (SCLK, MOSI) with key_loader_spi but uses
    -- a separate CS_APP_N pin. This allows simultaneous existence
    -- of key injection and command interfaces.
    -------------------------------------------------------------------------
    cmd_slave_inst : entity work.spi_cmd_slave
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            kill_signal      => safe_kill,
            -- SPI interface (shared bus, dedicated CS)
            spi_sclk         => SPI_SCLK_PIN,
            spi_mosi         => SPI_MOSI_PIN,
            spi_miso         => SPI_MISO_PIN,
            spi_cs_app_n     => SPI_APP_CS_N_PIN,
            -- AES engine interface (shared with comm_protocol)
            aes_pt_out       => cmd_aes_pt,
            aes_pt_valid     => cmd_aes_pt_valid,
            aes_ct_in        => ct_128,
            aes_ct_valid     => ct_valid,
            aes_busy         => '0',  -- Simplified: no backpressure
            -- TITAN status
            omega_active_in  => OMEGA_ENABLE_PIN and omega_mmcm_locked,
            aegis_active_in  => AEGIS_ENABLE_PIN,
            lockstep_ok_in   => '1',  -- PolarFire lockstep status
            post_pass_in     => post_pass,
            trng_healthy_in  => trng_healthy,
            kill_armed_in    => kill_active,
            hmac_busy_in     => hmac_hb_busy,    -- ★ K.16: HMAC busy → SPI status byte bit 4
            trng_degraded_in => trng_degraded,    -- ★ A.1: DRBG fallback → SPI status byte bit 7
            -- Outputs
            kill_trigger     => cmd_kill_trigger,
            cmd_active       => cmd_active,
            cmd_error        => cmd_error,
            heartbeat_ok     => cmd_heartbeat_ok,
            -- ★ P2-6: AEGIS Runtime Config
            aegis_cfg_addr   => cmd_aegis_cfg_addr,
            aegis_cfg_data   => cmd_aegis_cfg_data,
            aegis_cfg_wr     => cmd_aegis_cfg_wr,
            -- ★ P3-9: HMAC Heartbeat
            hmac_challenge_in    => hmac_challenge,
            hmac_challenge_ready => hmac_challenge_valid,
            hmac_response_out    => hmac_response,
            hmac_response_valid  => hmac_response_valid
        );

    -------------------------------------------------------------------------
    -- 6. WATCHDOG MONITOR (PolarFire Gözcüsü)
    -------------------------------------------------------------------------
    wdt_pf_inst : entity work.watchdog_monitor
        generic map (
            CLK_FREQ_MHZ   => 50,
            TIMEOUT_MS     => 1500,
            MAX_FAIL_COUNT => 3,
            BOOT_GRACE_MS  => 5000  -- PolarFire boot + Logic Wall settle
        )
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            target_heartbeat => PF_HEARTBEAT_IN,
            kill_trigger     => pf_watchdog_kill,
            fail_count_out   => wdt_fail_count,   -- ★ P1-4: telemetri
            grace_active     => wdt_grace_active   -- ★ P1-4: boot grace durumu
        );

    -------------------------------------------------------------------------
    -- 6b. HMAC HEARTBEAT CONTROLLER (★ P3-9)
    -- Cryptographic challenge-response: TRNG nonce + HMAC(key, nonce||counter)
    -- Toggle heartbeat + HMAC = hibrit savunma (combined_hb_ok)
    -------------------------------------------------------------------------
    hmac_hb_inst : entity work.hmac_heartbeat_ctrl
        generic map (
            CLK_FREQ_MHZ          => 50,
            HEARTBEAT_INTERVAL_MS => 500
        )
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            kill_signal      => safe_kill,
            -- ★ V14.3 FIX Z1: Türetilmiş key (loaded_key XOR OPAD)
            hmac_key         => hmac_derived_key,
            -- TRNG: nonce üretimi için
            trng_data        => trng_iv(31 downto 0),
            trng_valid       => trng_healthy,
            -- SPI challenge/response
            challenge_out    => hmac_challenge,
            challenge_valid  => hmac_challenge_valid,
            response_in      => hmac_response,
            response_valid   => hmac_response_valid,
            -- Sonuçlar
            heartbeat_ok     => hmac_hb_ok,
            heartbeat_fail   => hmac_hb_fail,
            hmac_busy        => hmac_hb_busy,
            -- Toggle heartbeat (mevcut watchdog)
            toggle_hb_in     => cmd_heartbeat_ok,
            combined_hb_ok   => hmac_combined_ok
        );

    -------------------------------------------------------------------------
    -- BÖLÜM B: V14 YENİ MODÜLLER
    -------------------------------------------------------------------------

    -------------------------------------------------------------------------
    -- 13. AEGIS AI ANOMALY DETECTION (FAZ 2: ESN Pipeline)
    -------------------------------------------------------------------------
    -- ESN Reservoir -> Readout -> Anomaly Detector
    -- Giriş: AXI4-Stream sensör verisi (PVT'den beslenir)
    -- Çıkış: anomaly_irq -> kill chain
    -------------------------------------------------------------------------
    aegis_tready <= '1';  -- Always ready (no backpressure from AEGIS consumer)
    pvt_tready   <= '1';  -- PVT always consumed

    -- ★ P2-6: AEGIS config artik SPI üzerinden yüklenebilir
    -- CMD_AEGIS_CFG (0xA0) komutuyla runtime weight/threshold yazılır
    -- Python offline training → weight export → SPI upload akışı aktif
    aegis_config_addr <= cmd_aegis_cfg_addr;
    aegis_config_data <= cmd_aegis_cfg_data;
    aegis_config_we   <= cmd_aegis_cfg_wr;

    aegis_inst : entity work.aegis_top
        port map (
            sys_clk         => sys_clk,
            rst_n           => global_rst_n,
            -- AXI4-Stream Slave (sensör verisi -- PVT'den)
            s_axis_tdata    => pvt_data,
            s_axis_tvalid   => pvt_valid,
            s_axis_tready   => open,      -- PVT always has data
            -- AXI4-Stream Master (tahmin çıkışı)
            m_axis_tdata    => aegis_tdata,
            m_axis_tvalid   => aegis_tvalid,
            m_axis_tready   => aegis_tready,
            -- Configuration
            cfg_addr        => aegis_config_addr,
            cfg_data        => aegis_config_data,
            cfg_wr_en       => aegis_config_we,
            -- Status
            anomaly_irq     => aegis_anomaly_irq
        );

    -------------------------------------------------------------------------
    -- 14. OMEGA CLOAK DPA PROTECTION (FAZ 3: Chaotic Masking)
    -------------------------------------------------------------------------
    -- Dual PRNG -> Clock Jitter -> Dummy Operations
    -- aes_stall -> AES pipeline pause during dummies
    -------------------------------------------------------------------------

    -- Seed the PRNG once at boot (system_ready rising edge)
    process(sys_clk, global_rst)
        variable prev_ready : std_logic := '0';
    begin
        if global_rst = '1' then
            omega_prng_seed_load <= '0';
            prev_ready := '0';
        elsif rising_edge(sys_clk) then
            omega_prng_seed_load <= '0';
            if system_ready = '1' and prev_ready = '0' then
                omega_prng_seed_load <= '1';  -- One-shot seed load
            end if;
            prev_ready := system_ready;
        end if;
    end process;

    omega_inst : entity work.omega_cloak_top
        generic map (
            MAX_DUMMIES     => 3,
            MAX_PHASE_STEPS => 108
        )
        port map (
            sys_clk         => sys_clk,
            rst_n           => global_rst_n,
            -- Master control
            omega_enable    => OMEGA_ENABLE_PIN,
            enable_jitter   => '1',   -- Jitter always on when omega active
            enable_dummy    => '1',   -- Dummies always on when omega active
            -- TRNG seed
            trng_seed       => trng_seed_32,
            trng_seed_valid => '1',
            -- AES round interface
            aes_round_start => aes_round_start,
            aes_stall       => omega_stall,
            -- Clock outputs
            jittered_clk    => omega_jittered_clk,
            sys_clk_buf     => omega_sys_clk_buf,
            mmcm_locked     => omega_mmcm_locked,
            -- Status
            chaos_out       => omega_chaos_out,
            chaos_valid_out => omega_chaos_valid,
            dummy_active    => omega_dummy_active,
            dummy_count     => omega_dummy_count,
            stat_dummies    => omega_stat_dummies,
            stat_rounds     => omega_stat_rounds,
            -- PRNG control
            prng_load_seed  => omega_prng_seed_load,
            prng_enable     => system_ready
        );

    -- AES round start: derived from pt_valid (simplified handshake)
    -- In a full integration, this would come from aes_core_wrapper's round FSM
    aes_round_start <= pt_valid and (not omega_stall);

    -------------------------------------------------------------------------
    -- 15. PVT MONITOR (FAZ 4: Physical Health)
    -------------------------------------------------------------------------
    -- 4 Ring Oscillator frekans sayıcı -> ortalama -> Q8.8 -> AEGIS'e
    -------------------------------------------------------------------------
    pvt_inst : entity work.pvt_monitor_top
        generic map (
            N_SENSORS     => 4,
            LOG2_N        => 2,
            SYS_CLK_FREQ  => 50_000_000,
            MEASURE_MS    => 1,
            NOMINAL_COUNT => 50_000,
            ALARM_PCT     => 10         -- ±10% (production tightened)
        )
        port map (
            clk           => sys_clk,
            rst_n         => global_rst_n,
            ring_osc_in   => RING_OSC_IN,
            measure_start => system_ready,   -- Start on boot
            continuous    => '1',            -- Always monitoring
            clear_alarm   => '0',            -- No auto-clear
            calib_nominal => std_logic_vector(to_unsigned(50_000, 24)),
            calib_load    => system_ready,
            m_tdata       => pvt_data,
            m_tvalid      => pvt_valid,
            m_tready      => pvt_tready,
            pvt_alarm     => pvt_alarm,
            sensor_alarms => pvt_sensor_alarms,
            pvt_raw_avg   => pvt_raw_avg,
            all_valid     => pvt_all_valid  -- ★ P3: connected for telemetry
        );

    -------------------------------------------------------------------------
    -- 16b. GLITCH DETECTOR (★ P0-1: Clock/Voltage Glitch Koruması)
    -------------------------------------------------------------------------
    -- Delay-line karşılaştırma ile glitch injection tespiti
    -- monitor_in olarak sys_clk verilir — clock glitch algılar
    -- ALARM_COUNT=3 ile 3 ardışık glitch → latched alarm → kill chain
    -------------------------------------------------------------------------
    glitch_det_inst : entity work.glitch_detector
        generic map (
            DELAY_STAGES => 8,     -- 8 LUT delay stage (~2-4ns)
            ALARM_COUNT  => 3      -- 3 glitch debounce
        )
        port map (
            clk           => sys_clk,
            rst_n         => global_rst_n,
            monitor_in    => sys_clk,     -- Clock'ın kendisini izle
            glitch_alarm  => glitch_alarm,
            glitch_count  => glitch_count  -- Debug: telemetriye bağlanabilir
        );

    -------------------------------------------------------------------------
    -- 16c. FIRMWARE INTEGRITY GUARD (★ P0-2: Bitstream Tamper Tespiti)
    -------------------------------------------------------------------------
    -- POST sırasında config belleğin CRC-32'sini hesaplar
    -- eFuse golden hash ile karşılaştırır
    -- Eşleşmezse → fi_fail latched → kill chain
    -------------------------------------------------------------------------
    -- ★ POST tamamlandığında firmware integrity kontrolü başlat
    -- system_ready rising edge'inde tetiklenir
    process(sys_clk, global_rst)
        variable fi_prev_ready : std_logic := '0';
    begin
        if global_rst = '1' then
            fi_start <= '0';
            fi_prev_ready := '0';
        elsif rising_edge(sys_clk) then
            fi_start <= '0';
            if system_ready = '1' and fi_prev_ready = '0' then
                fi_start <= '1';  -- One-shot: POST sonrası başlat
            end if;
            fi_prev_ready := system_ready;
        end if;
    end process;

    -- ★ Config Memory Stub (Simülasyon / Synthesis):
    -- Gerçek sentezde Xilinx ICAP veya MCAP primitive'i bağlanır.
    -- Simülasyonda sabit veri döndürür (CRC doğrulama testi için).
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if fi_cfg_read_req = '1' then
                fi_cfg_valid <= '1';
                -- Stub: sabit config word (sentezde ICAP verisi gelir)
                fi_cfg_data  <= x"A5A5_5A5A";
            else
                fi_cfg_valid <= '0';
            end if;
        end if;
    end process;

    fi_integrity_inst : entity work.firmware_integrity
        generic map (
            HASH_WORDS => 256    -- 256 word = 1KB config bölgesi
        )
        port map (
            clk            => sys_clk,
            rst_n          => global_rst_n,
            start          => fi_start,
            -- ★ 5.1 FIX: Golden hash artik top-level generic'ten gelir
            -- Build script synth_design -generic ile override edebilir
            golden_hash    => GOLDEN_HASH_DEFAULT,
            cfg_addr       => fi_cfg_addr,
            cfg_data       => fi_cfg_data,
            cfg_valid      => fi_cfg_valid,
            cfg_read_req   => fi_cfg_read_req,
            integrity_pass => fi_pass,
            integrity_fail => fi_fail,
            busy           => fi_busy
        );

    -------------------------------------------------------------------------
    -- BÖLÜM C: GÜNCELLENMIŞ ENTEGRASYON (V13 -> V14)
    -------------------------------------------------------------------------

    -------------------------------------------------------------------------
    -- 7. TETİK BİRLEŞTİRME (V14: 10-Source Kill Chain)
    -------------------------------------------------------------------------
    -- V13:  A) KILL_PIN  B) pf_watchdog_kill
    -- V14: +C) AEGIS anomaly  D) PVT alarm  E) AES fault/timeout
    --      +F) Glitch alarm  G) Firmware integrity fail
    -------------------------------------------------------------------------
    factory_mode    <= JUMPER_CALIB;

    all_kill_sources <= KILL_PIN
                     or pf_watchdog_kill
                     or (aegis_anomaly_irq and AEGIS_ENABLE_PIN)
                     or pvt_alarm
                     or key_kill_trigger    -- ★ V14.2: SPI 3-strike/dead-man
                     or aes_fault           -- ★ V14.2: AES fault injection
                     or aes_timeout         -- ★ V14.2: AES core stall (1024 cycle)
                     or glitch_alarm        -- ★ P0-1: Clock/voltage glitch tespit
                     or fi_fail             -- ★ P0-2: Bitstream tamper tespit
                     or cmd_kill_trigger    -- ★ HİDRA: SPI command kill
                     or hmac_hb_fail;       -- ★ K2 FIX: HMAC heartbeat doğrulama başarısız

    -- ★★ KRİTİK GÜVENLİK DÜZELTME (FAZ 2.1) ★★
    -- Factory mode maskeleme KALDIRILDI — artık kill_protocol.vhd içindeki
    -- factory timeout counter tek yetkili fabrika modu bekçisi.
    -- ESKİ (HATALI): kill_active <= all_kill_sources when factory_mode = '0' else '0';
    --   → Top-level factory_mode='1' iken safe_kill='0' gönderiyordu
    --   → kill_protocol içindeki timeout dolduktan sonra bile kill_pin='0' kalıyordu
    --   → Factory timeout bypass edilemiyordu!
    -- YENİ: all_kill_sources doğrudan geçer, factory maskeleme kill_protocol'de
    kill_active <= all_kill_sources;

    -- ★★ KRİTİK GÜVENLİK MANTIĞI ★★
    -- ★ V14.3 FIX Z4: Katmanlı boot kill
    -- Fiziksel KILL_PIN her zaman aktif (boot sırasında bile)
    -- Dijital kill kaynakları sadece system_ready sonrası
    safe_kill <= KILL_PIN or (all_kill_sources and system_ready);

    -------------------------------------------------------------------------
    -- 8. KILL PROTOKOLÜ (V13 -- değişmedi)
    -------------------------------------------------------------------------
    kill_inst : entity work.kill_protocol
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            trng_seed        => trng_iv(7 downto 0),  -- LFSR seed from TRNG
            kill_pin         => safe_kill,
            factory_mode     => factory_mode,
            ram_addr         => ram_addr,
            ram_data_out     => ram_data,
            ram_write_enable => ram_we,
            led_status_red   => LED_STATUS_RED,
            system_halted    => system_halted,
            -- ★ V15 P0-6: Clock alive monitoring
            clk_alive_toggle => open,       -- Dış F-to-V devresine bağlanacak
            ext_clk_dead     => '0'         -- Dış analog watchdog henüz bağlı değil
        );

    -------------------------------------------------------------------------
    -- 9. AES-256-CTR MOTOR (V14: Omega Cloak ile sardık)
    -------------------------------------------------------------------------
    -- ★ C-7 FIX: BUFGMUX_CTRL — glitch-free clock switching
    -- Eski: aes_clk <= omega_jittered_clk when (...) else sys_clk; → GLITCH!
    -- Yeni: Xilinx BUFGMUX_CTRL primitif → guaranteed glitch-free switching
    aes_clk_mux_inst : BUFGMUX_CTRL
        port map (
            O  => aes_clk,             -- Output: AES clock
            I0 => sys_clk,             -- Input 0: System clock (fallback)
            I1 => omega_jittered_clk,  -- Input 1: Omega jittered clock
            S  => omega_clk_sel        -- Select: '1' = jittered, '0' = sys
        );

    -- ★ C-7: Clock select logic (glitch-free through BUFGMUX_CTRL)
    omega_clk_sel <= OMEGA_ENABLE_PIN and omega_mmcm_locked;

    aes_reset_gated <= global_rst_n and key_is_valid;

    -------------------------------------------------------------------------
    -- ★ 7.1: SPI → AES Holding Register + Req/Ack CDC Handshake
    -------------------------------------------------------------------------
    -- sys_clk side: latch SPI plaintext into holding register, toggle req
    process(sys_clk, global_rst)
    begin
        if global_rst = '1' then
            spi_pt_holding    <= (others => '0');
            spi_pt_req_toggle <= '0';
            spi_pt_busy       <= '0';
        elsif rising_edge(sys_clk) then
            -- Detect ack edge: buffer freed
            spi_pt_ack_meta <= spi_pt_ack_toggle;
            spi_pt_ack_sync <= spi_pt_ack_meta;
            spi_pt_ack_prev <= spi_pt_ack_sync;
            if spi_pt_ack_sync /= spi_pt_ack_prev then
                spi_pt_busy <= '0';  -- AES consumed data, buffer free
            end if;
            -- Latch new SPI plaintext if buffer free
            if cmd_aes_pt_valid = '1' then
                if spi_pt_busy = '0' then
                    spi_pt_holding    <= cmd_aes_pt;
                    spi_pt_req_toggle <= not spi_pt_req_toggle;  -- flip req
                    spi_pt_busy       <= '1';
                end if;
                -- If busy, data is silently dropped (cmd_error already set by spi_cmd_slave)
            end if;
        end if;
    end process;

    -- aes_clk side: sync req, capture data on edge, send ack
    process(aes_clk)
    begin
        if rising_edge(aes_clk) then
            if aes_reset_gated = '0' then
                spi_pt_req_meta  <= '0';
                spi_pt_req_sync  <= '0';
                spi_pt_req_prev  <= '0';
                spi_pt_captured  <= (others => '0');
                spi_pt_valid_aes <= '0';
                spi_pt_ack_toggle <= '0';
            else
                -- 2-stage sync of req toggle
                spi_pt_req_meta <= spi_pt_req_toggle;
                spi_pt_req_sync <= spi_pt_req_meta;
                spi_pt_req_prev <= spi_pt_req_sync;
                spi_pt_valid_aes <= '0';  -- default: no pulse
                -- Edge detected: new data available
                if spi_pt_req_sync /= spi_pt_req_prev then
                    spi_pt_captured   <= spi_pt_holding;  -- safe: data stable
                    spi_pt_valid_aes  <= '1';             -- 1-cycle pulse
                    spi_pt_ack_toggle <= not spi_pt_ack_toggle;  -- ack back
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- ★ 7.1: AES Input Priority MUX
    -- comm_protocol traffic always has priority (real data).
    -- SPI plaintext only served when comm is idle.
    -------------------------------------------------------------------------
    aes_pt_muxed       <= spi_pt_captured when (spi_pt_valid_aes = '1' and pt_valid = '0')
                          else pt_128;
    aes_pt_valid_muxed <= (spi_pt_valid_aes and (not pt_valid)) or pt_valid;

    aes_inst : entity work.aes_core_wrapper
        port map (
            clk            => aes_clk,
            rst_n          => aes_reset_gated,
            kill_signal    => safe_kill,
            master_key_in  => loaded_key,
            key_valid      => key_is_valid,
            iv_in          => trng_iv,
            -- ★ 7.1: MUX'd input (comm_protocol | SPI), gated by omega stall
            plain_text     => aes_pt_muxed,
            valid_in       => aes_pt_valid_muxed and (not omega_stall),
            cipher_text    => ct_128,
            valid_out      => ct_valid_aes_domain,  -- ★ FIX #2: aes_clk domain output
            -- ★ V14.2: Fault detection from AES core
            fault_detected => aes_fault,
            -- ★ FAZ 13.2: TX/RX nonce space bölünmesi
            direction       => proto_aes_dir,
            -- ★ FAZ 13.3: AES timeout
            -- ★ FAZ 13.3: AES timeout → kill chain
            aes_timeout     => aes_timeout,
            -- ★ Omega Cloak DPA protection
            omega_enable    => OMEGA_ENABLE_PIN,
            trng_seed       => omega_chaos_out,
            trng_seed_valid => omega_chaos_valid,
            omega_dummy_count => omega_dummy_count_aes,  -- 16-bit AES internal counter
            omega_active      => omega_dummy_active_sig  -- ★ P2-7: DPA aktif durumu
        );

    -- ★ FIX #2: CDC Synchronizer (aes_clk → sys_clk) for ct_valid
    -- Required because downstream logic (comm_protocol, telemetry) runs on sys_clk
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            ct_valid_meta <= ct_valid_aes_domain;  -- Stage 1: metastability absorber
            ct_valid      <= ct_valid_meta;        -- Stage 2: safe for sys_clk domain
        end if;
    end process;

    -------------------------------------------------------------------------
    -- ★ D2 FIX: Telemetri XOR hack kaldırıldı (ciphertext sızdırıyordu)
    telemetry_xor_hack <= '0';  -- Sabit: UART'a ciphertext bilgi gönderme

    -------------------------------------------------------------------------
    -- 10. TELEMETRİ MODÜLÜ (V13 -- değişmedi)
    -------------------------------------------------------------------------
    uart_telem_inst : entity work.uart_telemetry
        port map (
            clk             => sys_clk,
            rst_n           => global_rst_n,
            factory_mode    => factory_mode,
            xor_value       => telemetry_xor_hack,
            bucket_level    => 0,
            system_status   => hmac_combined_ok & pvt_all_valid,  -- P3: HMAC+PVT status
            glitch_count_in => glitch_count,       -- P0-1: glitch detector count
            hmac_busy_in    => hmac_hb_busy,       -- P3-9: HMAC heartbeat busy
            trng_healthy_in => trng_healthy,       -- TRNG health status
            fi_busy_in      => fi_busy,            -- P0-2: firmware integrity busy
            spi_error_in    => spi_error_sticky,   -- ★ 7.3: SPI CRC/cmd error
            uart_tx_pad     => UART_TX_PAD
        );

    -------------------------------------------------------------------------
    -- 11. HEARTBEAT LED (V13 -- değişmedi)
    -------------------------------------------------------------------------
    process(sys_clk, global_rst)
    begin
        if global_rst = '1' then
            heartbeat_cnt <= 0;
            heartbeat_led <= '0';
        elsif rising_edge(sys_clk) then
            if heartbeat_cnt = 25_000_000 - 1 then
                heartbeat_led <= not heartbeat_led;
                heartbeat_cnt <= 0;
            else
                heartbeat_cnt <= heartbeat_cnt + 1;
            end if;
        end if;
    end process;

    LED_STATUS_GREEN <= '1' when factory_mode = '1' else
                        heartbeat_led when (system_ready = '1' and hmac_combined_ok = '1') else
                        '0';  -- ★ P3: Green LED off if HMAC heartbeat fails

    -------------------------------------------------------------------------
    -- 12. COUNTER-STRIKE OUTPUT (V13 -- değişmedi)
    -------------------------------------------------------------------------
    PF_KILL_CMD <= pf_watchdog_kill
                   when (system_ready = '1' and factory_mode = '0')
                   else '0';

    -------------------------------------------------------------------------
    -- 16. V14 STATUS LED (Omega Cloak durum göstergesi)
    -------------------------------------------------------------------------
    LED_OMEGA_ACTIVE <= OMEGA_ENABLE_PIN and system_ready
                        and omega_mmcm_locked;

    -------------------------------------------------------------------------
    -- 17. POST SELF-TEST STATUS LED
    -------------------------------------------------------------------------
    -------------------------------------------------------------------------
    -- ★ 7.3: SPI Error Sticky Latch (Re-triggerable Monostable)
    -- cmd_error is 1 cycle (20ns) — invisible to human eye on LED.
    -- Latch holds for 100ms (5M cycles @ 50MHz), re-triggerable.
    -------------------------------------------------------------------------
    process(sys_clk, global_rst)
    begin
        if global_rst = '1' then
            spi_error_sticky <= '0';
            spi_error_timer  <= 0;
        elsif rising_edge(sys_clk) then
            if cmd_error = '1' then
                spi_error_sticky <= '1';
                spi_error_timer  <= 5_000_000;
            elsif spi_error_timer > 0 then
                spi_error_timer <= spi_error_timer - 1;
            else
                spi_error_sticky <= '0';
            end if;
        end if;
    end process;

    LED_POST_FAIL <= post_fail or spi_error_sticky;  -- ★ 7.3: SPI error visible

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI (REVİZYON 3 -- V14)
--------------------------------------------------------------------------------
-- 1. GERİYE UYUMLULUK
--    -> V13 tüm modüller ve sinyal akışı korundu
--    -> Yeni pinler opsiyonel: OMEGA_ENABLE_PIN=0 ile V13 davranışı
--    -> Kill chain genişletildi ama mantık aynı (OR + factory mask + safe_kill)
--
-- 2. KILL CHAIN (4 KAYNAK)
--    all_kill = KILL_PIN | pf_watchdog | (aegis_anomaly & AEGIS_EN) | pvt_alarm
--    -> AEGIS alarm: AEGIS_ENABLE_PIN ile maskelenebilir (deneysel dönem)
--    -> PVT alarm: her zaman aktif (fiziksel saldırı her zaman tespit edilmeli)
--
-- 3. OMEGA CLOAK ENTEGRASYONU
--    -> AES hâlâ sys_clk'ta çalışır (timing clean)
--    -> omega_stall: pt_valid'i maskeler -> AES round başlamaz
--    -> Dummy ops: gölge datapath (shadow_state) sys_clk'ta ayrı çalışır
--    -> Clock jitter: opsiyonel, jittered_clk AES'e bağlanabilir (timing risk!)
--
-- 4. PVT -> AEGIS BAĞLANTISI
--    -> PVT çıkışı (Q8.8 AXI4-Stream) -> AEGIS giriş
--    -> AEGIS ESN: PVT pattern'ı öğrenir, anomali tespit eder
--    -> Çift alarm: PVT direkt alarm (±20%) + AEGIS AI alarm (pattern)
--
-- 5. BOOT SEQUENCE (GÜNCELLENMİŞ)
--    -> PLL Lock -> Warmup -> system_ready=1
--    -> system_ready rising_edge -> omega_prng_seed_load (one-shot)
--    -> PVT continuous measurement başlar
--    -> AEGIS ESN yerleşene kadar anomaly_irq=0 (safe default)
--
-- 6. BEKLENEN KAYNAK KULLANIMI (Artix-7 100T)
--    V13:  ~350 FF,  ~200 LUT
--    V14:  ~2500 FF, ~3500 LUT (tahmini)
--    Artix-7 100T: 126,800 FF, 63,400 LUT -> %4 kullanım (çok rahat)
--
-- 7. YENİ CONSTRAINT GEREKSİNİMLERİ
--    -> RING_OSC_IN: set_false_path (async clock domain)
--    -> OMEGA_ENABLE_PIN, AEGIS_ENABLE_PIN: set_input_delay
--    -> LED_OMEGA_ACTIVE: set_output_delay
--    -> Omega MMCM: create_generated_clock + set_clock_uncertainty 2.0
--------------------------------------------------------------------------------
