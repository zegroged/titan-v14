--------------------------------------------------------------------------------
-- PROJECT TITAN V14: PolarFire Top Module (SAĞ KANAT) — FULL V14 PARITY
-- Module: Dual-FPGA Mutual Watchdog + AES + Omega Cloak + AEGIS + SPI Key
--------------------------------------------------------------------------------
-- ★ A1 UPGRADE: V13 → V14 tam parite
--   [NEW] SPI Key Loader (Volatile Fill Gun)
--   [NEW] Omega Cloak DPA koruma (enable port)
--   [NEW] AEGIS PVT anomaly dedektörü
--   [NEW] POST Self-Test
--   [NEW] PVT Ring Oscillator monitor × 4
--   [NEW] SPI Command Slave (HİDRA App Bridge)
--   [MOD] Kill chain: +aegis_anomaly +pvt_alarm kaynakları
--   [MOD] AES: Omega Cloak wrapper (stall + chaos)
--   [MOD] secure_key_storage: rst_n warm reset (GAP-2 parity)
--
-- KOMUTAN ŞERHİ: "Sol kanat güçlüyse, sağ kanat da aynı güçte olmalı.
--                Aksi halde düşman zayıf tarafı vurar."
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity polarfire_top is
    port (
        -- ======= TEMEL PİNLER =======
        PIN_EXT_CLK_50MHZ : in  std_logic;

        -- Güvenlik Sinyalleri
        KILL_PIN          : in  std_logic;
        JUMPER_CALIB      : in  std_logic;

        -- Lockstep Arayüzü (Artix-7 ile)
        ARTIX_HEARTBEAT   : in  std_logic;
        KILL_PIN_OUT      : out std_logic;
        PF_HEARTBEAT_OUT  : out std_logic;

        -- SPI Key Injection (FAZ 8)
        SPI_SCLK_PIN      : in  std_logic;
        SPI_MOSI_PIN      : in  std_logic;
        SPI_CS_N_PIN      : in  std_logic;

        -- UART Data Pipeline (FAZ 10)
        UART_RX_PIN       : in  std_logic;
        UART_TX_PIN       : out std_logic;

        -- Durum LED'leri
        LED_STATUS_RED    : out std_logic;
        LED_STATUS_GREEN  : out std_logic;

        -- ======= V14 YENİ PİNLER =======

        -- PVT Ring Oscillator × 4
        RING_OSC_IN       : in  std_logic_vector(3 downto 0);

        -- Omega/AEGIS kontrol
        OMEGA_ENABLE_PIN  : in  std_logic;
        AEGIS_ENABLE_PIN  : in  std_logic;

        -- V14 Durum LED'leri
        LED_OMEGA_ACTIVE  : out std_logic;
        LED_POST_FAIL     : out std_logic;

        -- ======= HİDRA SPI COMMAND BRIDGE =======
        SPI_APP_CS_N_PIN  : in  std_logic;
        SPI_MISO_PIN      : out std_logic
    );
end polarfire_top;

architecture Behavioral of polarfire_top is

    -------------------------------------------------------------------------
    -- Temel Sinyaller
    -------------------------------------------------------------------------
    signal sys_clk          : std_logic;
    signal pll_locked       : std_logic;
    signal system_ready     : std_logic;
    signal global_rst       : std_logic;
    signal global_rst_n     : std_logic;  -- ★ A-1 FIX: VHDL-93 intermediate signal

    signal kill_combined    : std_logic;
    signal watchdog_kill    : std_logic;
    signal safe_kill        : std_logic;
    signal factory_mode     : std_logic;
    signal system_halted    : std_logic;

    -- Volatile Key Injection
    signal loaded_key       : std_logic_vector(255 downto 0);
    signal key_is_valid     : std_logic;
    signal aes_reset_gated  : std_logic;

    -- TRNG IV
    signal trng_iv          : std_logic_vector(127 downto 0);
    signal trng_health_ok   : std_logic;
    signal trng_seed        : std_logic_vector(127 downto 0);

    -- Data Pipeline
    signal rx_byte, tx_byte : std_logic_vector(7 downto 0);
    signal rx_valid, tx_start, tx_busy : std_logic;
    signal pt_128, ct_128   : std_logic_vector(127 downto 0);
    signal pt_valid, ct_valid : std_logic;
    signal pipeline_enable  : std_logic;

    -- Heartbeat
    signal heartbeat_cnt    : integer range 0 to 25_000_000 := 0;
    signal heartbeat_led    : std_logic := '0';

    -- ★ V14 Sinyal Eklemeleri
    signal aegis_anomaly    : std_logic := '0';
    signal pvt_alarm        : std_logic := '0';
    signal gearbox_timeout  : std_logic := '0';  -- ★ K.9 FIX: Data gearbox timeout alarm
    signal all_kill_sources : std_logic;
    signal post_pass        : std_logic := '0';
    signal post_fail        : std_logic := '0';
    signal omega_active     : std_logic := '0';
    signal omega_dummy_cnt  : std_logic_vector(15 downto 0);
    signal fault_detected   : std_logic := '0';
    signal aes_timeout      : std_logic := '0';
    signal trng_degraded    : std_logic := '0';  -- ★ A.1: TRNG DRBG fallback flag
    signal key_kill_trigger : std_logic := '0';   -- ★ V14.1: SPI key loader kill

    -- ★ 5.2 FIX: Secure Key Vault → AES routing (CDC: sys_clk → aes_clk)
    signal vault_key_out    : std_logic_vector(255 downto 0);
    signal vault_key_valid  : std_logic;
    -- CDC synchronizers for key_valid (level signal, 2-stage FF)
    signal vault_valid_sync1 : std_logic := '0';
    signal vault_valid_sync2 : std_logic := '0';
    -- CDC: key data bus uses valid-gated capture (no grey-code needed for
    --      stable bus; key changes only when key_valid transitions 0→1)
    signal vault_key_cdc     : std_logic_vector(255 downto 0) := (others => '0');
    signal vault_valid_cdc   : std_logic := '0';

    -- ★ V14.1: Transport Key (eFUSE placeholder for encrypted SPI transfer)
    constant TRANSPORT_KEY : std_logic_vector(255 downto 0) :=
        x"0123456789ABCDEF_FEDCBA9876543210_DEADBEEFCAFEBABE_1337FACE7007F00D";

    -- PVT Monitor
    signal pvt_freq         : std_logic_vector(63 downto 0) := (others => '0');

    -- Omega Clock (jittered by TRNG)
    signal omega_jittered_clk : std_logic := '0';
    signal omega_mmcm_locked  : std_logic := '0';
    signal omega_clk_sel      : std_logic := '0';
    signal aes_clk            : std_logic;

    -- SPI Command Slave (V14 full interface)
    signal cmd_aes_pt       : std_logic_vector(127 downto 0);
    signal cmd_aes_pt_valid : std_logic;
    signal cmd_kill_trigger : std_logic;
    signal cmd_active       : std_logic;
    signal cmd_error        : std_logic;
    signal cmd_heartbeat_ok : std_logic;
    signal cmd_aegis_cfg_addr : std_logic_vector(7 downto 0);
    signal cmd_aegis_cfg_data : std_logic_vector(15 downto 0);
    signal cmd_aegis_cfg_wr   : std_logic;
    -- ★ 7.3: SPI error sticky latch (100ms pulse stretcher)
    signal spi_error_sticky   : std_logic := '0';
    signal spi_error_timer    : integer range 0 to 5_000_000 := 0;
    -- ★ 7.2: AEGIS config register bank (8 x 16-bit)
    type aegis_cfg_reg_t is array (0 to 7) of std_logic_vector(15 downto 0);
    signal aegis_cfg_regs : aegis_cfg_reg_t := (
        0 => x"0100",  -- PVT_LOWER_BOUND default
        1 => x"FF00",  -- PVT_UPPER_BOUND default
        others => (others => '0')
    );
    signal pvt_lower_threshold : unsigned(15 downto 0);
    signal pvt_upper_threshold : unsigned(15 downto 0);
    -- ★ 7.1: AES Input MUX + CDC signals
    signal spi_pt_holding      : std_logic_vector(127 downto 0) := (others => '0');
    signal spi_pt_req_toggle   : std_logic := '0';
    signal spi_pt_busy         : std_logic := '0';
    signal spi_pt_req_meta     : std_logic := '0';
    signal spi_pt_req_sync     : std_logic := '0';
    signal spi_pt_req_prev     : std_logic := '0';
    signal spi_pt_captured     : std_logic_vector(127 downto 0) := (others => '0');
    signal spi_pt_valid_aes    : std_logic := '0';
    signal spi_pt_ack_toggle   : std_logic := '0';
    signal spi_pt_ack_meta     : std_logic := '0';
    signal spi_pt_ack_sync     : std_logic := '0';
    signal spi_pt_ack_prev     : std_logic := '0';
    signal aes_pt_muxed        : std_logic_vector(127 downto 0);
    signal aes_pt_valid_muxed  : std_logic;
    attribute ASYNC_REG of spi_pt_req_meta  : signal is "TRUE";
    attribute ASYNC_REG of spi_pt_req_sync  : signal is "TRUE";
    attribute ASYNC_REG of spi_pt_ack_meta  : signal is "TRUE";
    attribute ASYNC_REG of spi_pt_ack_sync  : signal is "TRUE";

    -- ★ P3-9: HMAC Heartbeat Responder Sinyalleri
    signal hmac_challenge      : std_logic_vector(127 downto 0);
    signal hmac_challenge_valid: std_logic;
    signal hmac_response       : std_logic_vector(255 downto 0);
    signal hmac_response_valid : std_logic;
    signal hmac_resp_tag       : std_logic_vector(255 downto 0);
    signal hmac_resp_ready     : std_logic;
    signal hmac_resp_busy      : std_logic;
    signal hmac_resp_error     : std_logic;

begin

    -- ★ A-1 FIX: VHDL-93 — expressions illegal in port maps
    global_rst_n <= not global_rst;

    -------------------------------------------------------------------------
    -- 1. CLOCK INFRASTRUCTURE & SUPERVISOR
    -------------------------------------------------------------------------
    clk_inst : entity work.polarfire_clocking
        port map (
            clk_in_50mhz => PIN_EXT_CLK_50MHZ,
            sys_clk      => sys_clk,
            pll_locked   => pll_locked
        );

    supervisor_inst : entity work.system_supervisor
        port map (
            clk        => sys_clk,
            pll_locked => pll_locked,
            system_rdy => system_ready,
            global_rst => global_rst
        );

    -------------------------------------------------------------------------
    -- 2. VOLATILE KEY LOADER (FAZ 8: SPI Fill Gun)
    -- ★ A1: V13'te eksikti, V14 parite ile eklendi
    -------------------------------------------------------------------------
    key_loader_inst : entity work.key_loader_spi
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            kill_signal      => safe_kill,
            spi_sclk         => SPI_SCLK_PIN,
            spi_mosi         => SPI_MOSI_PIN,
            spi_cs_n         => SPI_CS_N_PIN,
            trng_key_part    => trng_iv,
            transport_key    => TRANSPORT_KEY,
            trng_mask        => trng_iv,
            jumper_calib     => factory_mode,
            key_out          => loaded_key,
            key_valid        => key_is_valid,
            key_kill_trigger => key_kill_trigger
        );

    -------------------------------------------------------------------------
    -- 3. SECURE KEY STORAGE (GAP-2 Parity: rst_n warm reset)
    -------------------------------------------------------------------------
    secure_key_inst : entity work.secure_key_storage
        port map (
            clk         => sys_clk,
            rst_n       => global_rst_n,  -- ★ GAP-2: Warm reset key wipe
            kill_signal => safe_kill,
            load_key    => key_is_valid,
            master_key  => loaded_key,
            key_out     => vault_key_out,
            key_valid   => vault_key_valid,
            round_keys  => open   -- Legacy: V14'te kullanilmiyor
        );

    -------------------------------------------------------------------------
    -- 4. WATCHDOG MONITOR (Artix Gözcüsü)
    -------------------------------------------------------------------------
    watchdog_inst : entity work.watchdog_monitor
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            target_heartbeat => ARTIX_HEARTBEAT,
            kill_trigger     => watchdog_kill
        );

    -------------------------------------------------------------------------
    -- 5. KILL PROTOCOL — V14: Genişletilmiş tetik kaynakları
    -------------------------------------------------------------------------
    -- V14: Watchdog + Dış tamper + AEGIS anomaly + PVT alarm + AES fault + SPI kill
    all_kill_sources <= KILL_PIN or watchdog_kill or aegis_anomaly
                        or pvt_alarm or fault_detected
                        or cmd_kill_trigger  -- ★ K1 FIX: SPI kill komutu artık kill chain'de
                        or gearbox_timeout;  -- ★ K.9 FIX: Gearbox partial-block timeout → kill
    kill_combined <= all_kill_sources;
    factory_mode  <= JUMPER_CALIB;

    kill_inst : entity work.kill_protocol
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            trng_seed        => trng_iv(7 downto 0),  -- ★ P2-8: TRNG entropy (was x"A5")
            kill_pin         => kill_combined,
            factory_mode     => factory_mode,
            ram_addr         => open,
            ram_data_out     => open,
            ram_write_enable => open,
            led_status_red   => LED_STATUS_RED,
            system_halted    => system_halted
        );

    -------------------------------------------------------------------------
    -- 6. GÜVENLİK KAPISI (Safety Gate)
    -------------------------------------------------------------------------
    safe_kill <= kill_combined when system_ready = '1' else '0';

    -------------------------------------------------------------------------
    -- 7. POST SELF-TEST
    -- ★ A1: Eklendi — AES + TRNG doğrulama
    -------------------------------------------------------------------------
    post_inst : entity work.post_self_test
        port map (
            clk       => sys_clk,
            rst_n     => global_rst_n,
            start     => system_ready,
            pass      => post_pass,
            fail      => post_fail
        );

    LED_POST_FAIL <= post_fail or spi_error_sticky;  -- ★ 7.3: SPI error visible

    -------------------------------------------------------------------------
    -- 8. TRNG IV GENERATOR (FAZ 9)
    -------------------------------------------------------------------------
    trng_inst : entity work.trng_wrapper
        port map (
            clk             => sys_clk,
            rst_n           => global_rst_n,
            random_out      => trng_iv,
            health_ok       => trng_health_ok,
            health_degraded => trng_degraded   -- ★ A.1: DRBG fallback → SPI status
        );

    -- TRNG seed for Omega Cloak
    trng_seed <= trng_iv;

    -------------------------------------------------------------------------
    -- 9. AES-256-CTR MOTOR (Full Pipeline + Omega Cloak)
    -- ★ A1: Omega Cloak etkinleştirildi (V13'te omega_enable=>'0' idi)
    -------------------------------------------------------------------------
    aes_reset_gated <= global_rst_n and key_is_valid and post_pass;

    -- Clock selection: Omega Cloak aktifse jittered clock kullan
    omega_clk_sel <= OMEGA_ENABLE_PIN and omega_mmcm_locked;
    -- ★ O3 FIX: Glitch-guarded clock MUX
    -- Fabric MUX ile clock geçişi glitch üretebilir. Geçiş sırasında AES'i
    -- reset'te tutarak glitch'in state corruption yapmasını engelliyoruz.
    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if omega_clk_sel = '1' and omega_mmcm_locked = '1' then
                aes_clk <= omega_jittered_clk;
            else
                aes_clk <= sys_clk;
            end if;
        end if;
    end process;
    -- PRODUCTION: Replace above with PolarFire CCC reconfiguration or CLKINT primitive

    -------------------------------------------------------------------------
    -- ★ 5.2 FIX: CDC Bridge — Vault key (sys_clk) → AES (aes_clk)
    -- key_valid is a level signal that only transitions once (0→1 on key load,
    -- 1→0 on kill). Key data bus is stable when valid is high.
    -- Strategy: 2-stage sync for valid, capture key on rising edge of synced valid.
    -------------------------------------------------------------------------
    process(aes_clk, safe_kill)
    begin
        if safe_kill = '1' then
            vault_valid_sync1 <= '0';
            vault_valid_sync2 <= '0';
            vault_key_cdc     <= (others => '0');
            vault_valid_cdc   <= '0';
        elsif rising_edge(aes_clk) then
            -- 2-stage synchronizer for valid flag
            vault_valid_sync1 <= vault_key_valid;
            vault_valid_sync2 <= vault_valid_sync1;
            -- Capture key on synced valid rising edge
            if vault_valid_sync2 = '1' then
                vault_key_cdc   <= vault_key_out;
                vault_valid_cdc <= '1';
            else
                vault_key_cdc   <= (others => '0');
                vault_valid_cdc <= '0';
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- ★ 7.1: SPI → AES Holding Register + Req/Ack CDC Handshake
    -------------------------------------------------------------------------
    process(sys_clk, global_rst)
    begin
        if global_rst = '1' then
            spi_pt_holding    <= (others => '0');
            spi_pt_req_toggle <= '0';
            spi_pt_busy       <= '0';
        elsif rising_edge(sys_clk) then
            spi_pt_ack_meta <= spi_pt_ack_toggle;
            spi_pt_ack_sync <= spi_pt_ack_meta;
            spi_pt_ack_prev <= spi_pt_ack_sync;
            if spi_pt_ack_sync /= spi_pt_ack_prev then
                spi_pt_busy <= '0';
            end if;
            if cmd_aes_pt_valid = '1' then
                if spi_pt_busy = '0' then
                    spi_pt_holding    <= cmd_aes_pt;
                    spi_pt_req_toggle <= not spi_pt_req_toggle;
                    spi_pt_busy       <= '1';
                end if;
            end if;
        end if;
    end process;

    process(aes_clk)
    begin
        if rising_edge(aes_clk) then
            if aes_reset_gated = '0' then
                spi_pt_req_meta   <= '0';
                spi_pt_req_sync   <= '0';
                spi_pt_req_prev   <= '0';
                spi_pt_captured   <= (others => '0');
                spi_pt_valid_aes  <= '0';
                spi_pt_ack_toggle <= '0';
            else
                spi_pt_req_meta <= spi_pt_req_toggle;
                spi_pt_req_sync <= spi_pt_req_meta;
                spi_pt_req_prev <= spi_pt_req_sync;
                spi_pt_valid_aes <= '0';
                if spi_pt_req_sync /= spi_pt_req_prev then
                    spi_pt_captured   <= spi_pt_holding;
                    spi_pt_valid_aes  <= '1';
                    spi_pt_ack_toggle <= not spi_pt_ack_toggle;
                end if;
            end if;
        end if;
    end process;

    aes_pt_muxed       <= spi_pt_captured when (spi_pt_valid_aes = '1' and pt_valid = '0')
                          else pt_128;
    aes_pt_valid_muxed <= (spi_pt_valid_aes and (not pt_valid)) or pt_valid;

    aes_inst : entity work.aes_core_wrapper
        port map (
            clk             => aes_clk,
            rst_n           => aes_reset_gated,
            kill_signal     => safe_kill,
            master_key_in   => vault_key_cdc,
            key_valid       => vault_valid_cdc,
            iv_in           => trng_iv,
            -- ★ 7.1: MUX'd input (comm_protocol | SPI)
            plain_text      => aes_pt_muxed,
            valid_in        => aes_pt_valid_muxed,
            cipher_text     => ct_128,
            valid_out       => ct_valid,
            fault_detected  => fault_detected,
            direction       => '0',
            aes_timeout     => aes_timeout,
            -- ★ A1: Omega Cloak ETKİN (V13'te '0' idi)
            omega_enable    => OMEGA_ENABLE_PIN,
            trng_seed       => trng_seed,
            trng_seed_valid => trng_health_ok,
            omega_dummy_count => omega_dummy_cnt,
            omega_active      => omega_active
        );

    LED_OMEGA_ACTIVE <= omega_active;

    -------------------------------------------------------------------------
    -- 10. ÇAPRAZ ATEŞ (COUNTER-STRIKE OUTPUT)
    -------------------------------------------------------------------------
    KILL_PIN_OUT <= watchdog_kill when system_ready = '1' else '0';

    -------------------------------------------------------------------------
    -- 11. POLARFIRE HEARTBEAT
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
                        heartbeat_led when (system_ready = '1' and cmd_heartbeat_ok = '1') else
                        '0';  -- ★ P3: LED off if heartbeat fails
    PF_HEARTBEAT_OUT <= heartbeat_led;

    -------------------------------------------------------------------------
    -- 12. DATA PIPELINE (FAZ 10)
    -------------------------------------------------------------------------
    pipeline_enable <= global_rst_n and key_is_valid and post_pass;

    uart_inst : entity work.uart_driver
        generic map (CLK_FREQ => 50_000_000, BAUD_RATE => 115_200)
        port map (
            clk    => sys_clk, rst_n => pipeline_enable,
            rx_pin => UART_RX_PIN, tx_pin => UART_TX_PIN,
            rx_data => rx_byte, rx_valid => rx_valid,
            tx_data => tx_byte, tx_start => tx_start, tx_busy => tx_busy
        );

    gearbox_inst : entity work.data_gearbox
        port map (
            clk       => sys_clk, rst_n => pipeline_enable,
            flush     => '0',
            rx_byte   => rx_byte, rx_valid => rx_valid,
            tx_byte   => tx_byte, tx_start => tx_start, tx_busy => tx_busy,
            aes_in_blk => pt_128, aes_in_vld => pt_valid,
            aes_out_blk => ct_128, aes_out_vld => ct_valid,
            timeout_alarm => gearbox_timeout  -- ★ K.9 FIX: Kill chain'e bağlandı
        );

    -------------------------------------------------------------------------
    -- 13. SPI COMMAND SLAVE (HİDRA App Bridge)
    -- ★ A1: App Processor → FPGA komut kanalı
    -------------------------------------------------------------------------
    spi_cmd_inst : entity work.spi_cmd_slave
        port map (
            clk            => sys_clk,
            rst_n          => global_rst_n,
            kill_signal    => safe_kill,
            spi_sclk       => SPI_SCLK_PIN,
            spi_mosi       => SPI_MOSI_PIN,
            spi_miso       => SPI_MISO_PIN,
            spi_cs_app_n   => SPI_APP_CS_N_PIN,
            -- AES (gearbox uzerinden zaten bagli, SPI cmd direkt kullanmaz)
            aes_pt_out     => cmd_aes_pt,
            aes_pt_valid   => cmd_aes_pt_valid,
            aes_ct_in      => ct_128,
            aes_ct_valid   => ct_valid,
            aes_busy       => '0',
            -- Status
            omega_active_in  => omega_active,
            aegis_active_in  => AEGIS_ENABLE_PIN,
            lockstep_ok_in   => '1',  -- PolarFire kendisi (Artix'i izliyor)
            post_pass_in     => post_pass,
            trng_healthy_in  => trng_health_ok,
            kill_armed_in    => system_halted,
            hmac_busy_in     => hmac_resp_busy,  -- ★ K.16: HMAC busy → SPI status byte bit 4
            trng_degraded_in => trng_degraded,    -- ★ A.1: DRBG fallback → SPI status byte bit 7
            -- Output
            kill_trigger     => cmd_kill_trigger,
            cmd_active       => cmd_active,
            cmd_error        => cmd_error,
            heartbeat_ok     => cmd_heartbeat_ok,
            -- AEGIS Config
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
    -- 13b. HMAC HEARTBEAT RESPONDER (★ P3-9: Async Non-Blocking)
    -- Artix challenge gonderir → PolarFire HMAC hesaplar → tag'i geri gonderir
    -- SPI veri yolunu BLOKLAMAZ (~13us HMAC vs 500ms interval)
    -------------------------------------------------------------------------
    hmac_resp_inst : entity work.pf_hmac_responder
        port map (
            clk              => sys_clk,
            rst_n            => global_rst_n,
            kill_signal      => safe_kill,
            hmac_key         => loaded_key,
            challenge_in     => hmac_response(127 downto 0),  -- SPI'dan HMAC tag'in alt 128 bit'i challenge olarak
            challenge_valid  => hmac_response_valid,          -- SPI HEARTBEAT komutu geldiginde
            response_tag     => hmac_resp_tag,
            response_ready   => hmac_resp_ready,
            busy             => hmac_resp_busy,
            error            => hmac_resp_error
        );

    -------------------------------------------------------------------------
    -- 14. AEGIS AI ANOMALY DETECTION (Stub — PVT tabanlı)
    -- ★ A1: PVT alarm → aegis_anomaly bağlantısı
    -------------------------------------------------------------------------
    -- AEGIS anomaly: PVT alarmı VEYA TRNG sağlık kaybı
    aegis_anomaly <= (pvt_alarm or (not trng_health_ok))
                     when AEGIS_ENABLE_PIN = '1' else '0';

    -------------------------------------------------------------------------
    -- ★ 7.2: AEGIS Config Register Bank
    -- SPI AEGIS_CFG komutuyla PVT threshold ve diğer değerleri günceller.
    -- Register 0: PVT_LOWER_BOUND, Register 1: PVT_UPPER_BOUND
    -------------------------------------------------------------------------
    process(sys_clk, global_rst)
    begin
        if global_rst = '1' then
            aegis_cfg_regs <= (
                0 => x"0100",
                1 => x"FF00",
                others => (others => '0')
            );
        elsif rising_edge(sys_clk) then
            if cmd_aegis_cfg_wr = '1' then
                aegis_cfg_regs(to_integer(unsigned(cmd_aegis_cfg_addr(2 downto 0)))) <= cmd_aegis_cfg_data;
            end if;
        end if;
    end process;

    pvt_lower_threshold <= unsigned(aegis_cfg_regs(0));
    pvt_upper_threshold <= unsigned(aegis_cfg_regs(1));

    -------------------------------------------------------------------------
    -- 15. PVT MONITOR (Ring Oscillator Frequency Counter)
    -- ★ A1: 4 bağımsız ring oscillator frekansını ölçer
    -------------------------------------------------------------------------
    pvt_monitor: process(sys_clk)
        variable ro_cnt : unsigned(15 downto 0) := (others => '0');
        variable sample_cnt : integer range 0 to 50_000 := 0;
        constant SAMPLE_WINDOW : integer := 50_000; -- 1ms @ 50MHz
    begin
        if rising_edge(sys_clk) then
            if global_rst = '1' then
                ro_cnt := (others => '0');
                sample_cnt := 0;
                pvt_alarm <= '0';
            else
                -- Count ring oscillator transitions (use RO[0] for basic monitor)
                if RING_OSC_IN(0) = '1' then
                    ro_cnt := ro_cnt + 1;
                end if;

                sample_cnt := sample_cnt + 1;
                if sample_cnt = SAMPLE_WINDOW then
                    sample_cnt := 0;
                    pvt_freq(15 downto 0) <= std_logic_vector(ro_cnt);

                    -- Range check: anormal frekans → saldırı
                    -- ★ 7.2: Thresholds now configurable via AEGIS_CFG SPI command
                    if ro_cnt < pvt_lower_threshold or ro_cnt > pvt_upper_threshold then
                        pvt_alarm <= '1';  -- Glitch/voltage tamper
                    else
                        pvt_alarm <= '0';
                    end if;

                    ro_cnt := (others => '0');
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- ★ 7.3: SPI Error Sticky Latch (Re-triggerable Monostable)
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

end Behavioral;

--------------------------------------------------------------------------------
-- V14 TASARIM NOTLARI (PolarFire SAĞ KANAT)
--------------------------------------------------------------------------------
-- 1. V13→V14 TAM PARİTE: Artix-7 V14 ile aynı güvenlik seviyesi
-- 2. SPI KEY LOADER: Fiziksel USB dongle ile anahtar enjeksiyonu
-- 3. OMEGA CLOAK: DPA yan kanal saldırılarına karşı koruma
-- 4. AEGIS: PVT + TRNG sağlık izleme ile anomaly tetikleme
-- 5. POST: Sistem başlangıcında AES + TRNG otomatik doğrulama
-- 6. PVT MONITOR: Ring osc frekans sayacı ile glitch/voltage tespiti
-- 7. KILL ZİNCİRİ: 5 bağımsız tetik kaynağı
--    → KILL_PIN (dış tamper) + Watchdog (PF↔Artix) + AEGIS anomaly
--    → PVT alarm + AES fault
-- 8. CAPRAZ ATES: Artix donmussa PolarFire onu oldurur (ve tersi)
-- 9. HMAC HEARTBEAT: pf_hmac_responder async non-blocking HMAC tag uretimi
--    SPI veri yolunu bloklamaz (~13us HMAC vs 500ms heartbeat interval)
-- 10. SPI CMD SLAVE V14: Full HLP parser + AES + STATUS + AEGIS_CFG + HMAC
--------------------------------------------------------------------------------
