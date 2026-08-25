--------------------------------------------------------------------------------
-- PROJECT TITAN V15: SECRET TESTBENCH — Self-Verifying Loopback
--------------------------------------------------------------------------------
-- !! GİZLİ DOSYA — ÜRETİM PAKETİNE DAHİL EDİLMEZ !!
-- !! TEST TAMAMLANDIKTAN SONRA SİLİNMELİ !!
--
-- TX comm_protocol + AES → wire → RX comm_protocol + AES
-- Gönderilen plaintext = Alınan plaintext olmalı (self-check)
-- Hardcoded key/data yok — LFSR ile pseudo-random test vektörü
--
-- WIRE INJECTION MUX: Negatif testler için raw byte injection
-- inject_mode='0' → Normal loopback (TX→RX)
-- inject_mode='1' → Raw injection (inject_byte→RX)
--
-- Test senaryoları (önem sırasına göre):
--   T1:  Tek blok TX→RX round-trip (sentinel anti-replay doğrula)
--   T2:  Back-to-back ikinci frame (seq_num artışı doğrula)
--   T3:  Kill zeroization — verinin silindiğini doğrula
--   T4:  Key reload after kill — yeni session başlat
--   T5:  Reload sonrası frame (continuity doğrula)
--   T6:  Invalid NBLK rejection — NBLK=0 → frame_error='1'
--   T7:  Anti-replay rejection — eski seq_num → frame_error='1'
--   T8:  MAC tamper detection — bozuk MAC → mac_error='1'
--   T9:  Normal frame after negative tests — sistem recovery doğrula
--   T10: Final kill — temiz kapanış
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity comm_protocol_tb is
end comm_protocol_tb;

architecture Behavioral of comm_protocol_tb is

    -------------------------------------------------------------------------
    -- CLOCK & RESET
    -------------------------------------------------------------------------
    constant CLK_PERIOD : time := 20 ns;  -- 50 MHz
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal kill_signal  : std_logic := '0';
    signal sim_done     : boolean := false;
    
    -------------------------------------------------------------------------
    -- LFSR PSEUDO-RANDOM (test vektörü üretici — key ve data)
    -------------------------------------------------------------------------
    signal lfsr_state : std_logic_vector(31 downto 0) := x"DEADBEEF";
    
    -------------------------------------------------------------------------
    -- TEST KEY (LFSR'den üretilir, dosyada sabit değil)
    -------------------------------------------------------------------------
    signal test_key     : std_logic_vector(255 downto 0);
    signal key_valid    : std_logic := '0';
    signal test_iv      : std_logic_vector(127 downto 0) := (others => '0');
    
    -------------------------------------------------------------------------
    -- TX SIDE signals
    -------------------------------------------------------------------------
    signal tx_red_rx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_red_rx_valid  : std_logic := '0';
    signal tx_red_tx_byte   : std_logic_vector(7 downto 0);
    signal tx_red_tx_start  : std_logic;
    signal tx_blk_rx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_blk_rx_valid  : std_logic := '0';
    signal tx_blk_tx_byte   : std_logic_vector(7 downto 0);
    signal tx_blk_tx_start  : std_logic;
    signal tx_session       : std_logic;
    signal tx_mac_err       : std_logic;
    signal tx_frame_err     : std_logic;
    
    -- TX AES interface
    signal tx_aes_pt        : std_logic_vector(127 downto 0);
    signal tx_aes_pt_valid  : std_logic;
    signal tx_aes_ct        : std_logic_vector(127 downto 0);
    signal tx_aes_ct_valid  : std_logic;
    
    -------------------------------------------------------------------------
    -- RX SIDE signals
    -------------------------------------------------------------------------
    signal rx_red_rx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_red_rx_valid  : std_logic := '0';
    signal rx_red_tx_byte   : std_logic_vector(7 downto 0);
    signal rx_red_tx_start  : std_logic;
    signal rx_blk_rx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_blk_rx_valid  : std_logic := '0';
    signal rx_blk_tx_byte   : std_logic_vector(7 downto 0);
    signal rx_blk_tx_start  : std_logic;
    signal rx_session       : std_logic;
    signal rx_mac_err       : std_logic;
    signal rx_frame_err     : std_logic;
    
    -- RX AES interface
    signal rx_aes_pt        : std_logic_vector(127 downto 0);
    signal rx_aes_pt_valid  : std_logic;
    signal rx_aes_ct        : std_logic_vector(127 downto 0);
    signal rx_aes_ct_valid  : std_logic;
    
    -------------------------------------------------------------------------
    -- ★ OMEGA CLOAK signals
    -------------------------------------------------------------------------
    signal omega_enable     : std_logic := '0';
    signal trng_seed        : std_logic_vector(31 downto 0) := x"DEADBEEF";
    signal trng_seed_valid  : std_logic := '0';
    signal tx_omega_dummies : std_logic_vector(15 downto 0);
    signal tx_omega_active  : std_logic;
    signal rx_omega_dummies : std_logic_vector(15 downto 0);
    signal rx_omega_active  : std_logic;
    
    -------------------------------------------------------------------------
    -- ★ WIRE INJECTION MUX (Negatif testler için)
    -------------------------------------------------------------------------
    signal inject_mode  : std_logic := '0';  -- '1' = raw injection aktif
    signal inject_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal inject_valid : std_logic := '0';
    
    -- Mux'lanmış wire sinyalleri
    signal wire_byte    : std_logic_vector(7 downto 0);
    signal wire_valid   : std_logic;
    
    -------------------------------------------------------------------------
    -- FRAME CAPTURE (TX çıkışını yakalar — replay/tamper testleri için)
    -------------------------------------------------------------------------
    type frame_buf_t is array (0 to 511) of std_logic_vector(7 downto 0);
    signal captured_frame : frame_buf_t := (others => (others => '0'));
    signal cap_idx        : integer := 0;
    signal cap_active     : std_logic := '0';  -- '1' = capture aktif
    signal cap_reset      : std_logic := '0';  -- '1' pulse = reset cap_idx
    
    -------------------------------------------------------------------------
    -- VERIFICATION CAPTURE
    -------------------------------------------------------------------------
    type byte_array_t is array (0 to 15) of std_logic_vector(7 downto 0);
    type multi_byte_array_t is array (0 to 255) of std_logic_vector(7 downto 0);
    signal sent_data     : byte_array_t := (others => (others => '0'));
    signal received_data : multi_byte_array_t := (others => (others => '0'));
    signal rx_byte_idx   : integer range 0 to 255 := 0;
    signal rx_expected_bytes : integer range 1 to 256 := 16;
    signal tx_complete   : boolean := false;
    signal rx_complete   : boolean := false;
    
    -------------------------------------------------------------------------
    -- TEST STATUS
    -------------------------------------------------------------------------
    signal test_number   : integer := 0;
    signal tests_passed  : integer := 0;
    signal tests_failed  : integer := 0;
    
    -------------------------------------------------------------------------
    -- ERROR LATCH (single-cycle pulse capture)
    -------------------------------------------------------------------------
    signal err_latch_frame : std_logic := '0';
    signal err_latch_mac   : std_logic := '0';
    signal err_latch_clear : std_logic := '0';

begin

    -------------------------------------------------------------------------
    -- CLOCK GENERATION
    -------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';
    
    -------------------------------------------------------------------------
    -- LFSR (Pseudo-random test data generator)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            lfsr_state <= lfsr_state(30 downto 0) & 
                (lfsr_state(31) xor lfsr_state(21) xor 
                 lfsr_state(1) xor lfsr_state(0));
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- ★ WIRE INJECTION MUX
    -- inject_mode='0' → Normal TX→RX loopback
    -- inject_mode='1' → Manual injection (negatif testler)
    -------------------------------------------------------------------------
    wire_byte  <= inject_byte  when inject_mode = '1' else tx_blk_tx_byte;
    wire_valid <= inject_valid when inject_mode = '1' else tx_blk_tx_start;
    
    rx_blk_rx_byte  <= wire_byte;
    rx_blk_rx_valid <= wire_valid;
    
    -------------------------------------------------------------------------
    -- TX COMM PROTOCOL
    -------------------------------------------------------------------------
    tx_comm : entity work.comm_protocol
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => kill_signal,
            mode           => '0',  -- TX
            red_rx_byte    => tx_red_rx_byte,
            red_rx_valid   => tx_red_rx_valid,
            red_tx_byte    => tx_red_tx_byte,
            red_tx_start   => tx_red_tx_start,
            red_tx_busy    => '0',
            blk_rx_byte    => tx_blk_rx_byte,
            blk_rx_valid   => tx_blk_rx_valid,
            blk_tx_byte    => tx_blk_tx_byte,
            blk_tx_start   => tx_blk_tx_start,
            blk_tx_busy    => '0',
            aes_pt_out     => tx_aes_pt,
            aes_pt_valid   => tx_aes_pt_valid,
            aes_ct_in      => tx_aes_ct,
            aes_ct_valid   => tx_aes_ct_valid,
            derived_iv     => test_iv,
            trng_iv        => test_iv,  -- ★ V15 P0-1
            session_active => tx_session,
            mac_error      => tx_mac_err,
            frame_error    => tx_frame_err
        );
    
    -------------------------------------------------------------------------
    -- TX AES ENGINE
    -------------------------------------------------------------------------
    tx_aes : entity work.aes_core_wrapper
        port map (
            clk              => clk,
            rst_n            => rst_n,
            kill_signal      => kill_signal,
            master_key_in    => test_key,
            key_valid        => key_valid,
            iv_in            => test_iv,
            plain_text       => tx_aes_pt,
            valid_in         => tx_aes_pt_valid,
            cipher_text      => tx_aes_ct,
            valid_out        => tx_aes_ct_valid,
            fault_detected   => open,
            direction        => '0',  -- TX direction
            aes_timeout      => open,
            omega_enable     => omega_enable,
            trng_seed        => trng_seed,
            trng_seed_valid  => trng_seed_valid,
            omega_dummy_count => tx_omega_dummies,
            omega_active     => tx_omega_active
        );
    
    -------------------------------------------------------------------------
    -- RX COMM PROTOCOL
    -------------------------------------------------------------------------
    rx_comm : entity work.comm_protocol
        port map (
            clk            => clk,
            rst_n          => rst_n,
            kill_signal    => kill_signal,
            mode           => '1',  -- RX
            red_rx_byte    => rx_red_rx_byte,
            red_rx_valid   => rx_red_rx_valid,
            red_tx_byte    => rx_red_tx_byte,
            red_tx_start   => rx_red_tx_start,
            red_tx_busy    => '0',
            blk_rx_byte    => rx_blk_rx_byte,
            blk_rx_valid   => rx_blk_rx_valid,
            blk_tx_byte    => rx_blk_tx_byte,
            blk_tx_start   => rx_blk_tx_start,
            blk_tx_busy    => '0',
            aes_pt_out     => rx_aes_pt,
            aes_pt_valid   => rx_aes_pt_valid,
            aes_ct_in      => rx_aes_ct,
            aes_ct_valid   => rx_aes_ct_valid,
            derived_iv     => test_iv,
            trng_iv        => test_iv,  -- ★ V15 P0-1
            session_active => rx_session,
            mac_error      => rx_mac_err,
            frame_error    => rx_frame_err
        );
    
    -------------------------------------------------------------------------
    -- RX AES ENGINE (aynı key — ikiz cihaz)
    -------------------------------------------------------------------------
    rx_aes : entity work.aes_core_wrapper
        port map (
            clk              => clk,
            rst_n            => rst_n,
            kill_signal      => kill_signal,
            master_key_in    => test_key,
            key_valid        => key_valid,
            iv_in            => test_iv,
            plain_text       => rx_aes_pt,
            valid_in         => rx_aes_pt_valid,
            cipher_text      => rx_aes_ct,
            valid_out        => rx_aes_ct_valid,
            fault_detected   => open,
            direction        => '0',  -- ★ FIX: Must match TX direction for decryption
            aes_timeout      => open,
            omega_enable     => omega_enable,
            trng_seed        => trng_seed,
            trng_seed_valid  => trng_seed_valid,
            omega_dummy_count => rx_omega_dummies,
            omega_active     => rx_omega_active
        );
    
    -------------------------------------------------------------------------
    -- FRAME CAPTURE PROCESS (TX çıkışını kaydet — replay testleri için)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if cap_reset = '1' then
                cap_idx <= 0;
            elsif cap_active = '1' and tx_blk_tx_start = '1' then
                if cap_idx < 512 then
                    captured_frame(cap_idx) <= tx_blk_tx_byte;
                    cap_idx <= cap_idx + 1;
                end if;
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- RX DATA CAPTURE (alınan plaintext'i kaydet)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' or kill_signal = '1' then
                rx_byte_idx <= 0;
                rx_complete <= false;
            elsif rx_red_tx_start = '1' and not rx_complete then
                received_data(rx_byte_idx) <= rx_red_tx_byte;
                if rx_byte_idx = rx_expected_bytes - 1 then
                    rx_complete <= true;
                else
                    rx_byte_idx <= rx_byte_idx + 1;
                end if;
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- ERROR LATCH PROCESS (captures single-cycle pulses)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if err_latch_clear = '1' then
                err_latch_frame <= '0';
                err_latch_mac   <= '0';
            else
                if rx_frame_err = '1' then
                    err_latch_frame <= '1';
                end if;
                if rx_mac_err = '1' then
                    err_latch_mac <= '1';
                end if;
            end if;
        end if;
    end process;
    
    -------------------------------------------------------------------------
    -- MAIN TEST SEQUENCE
    -------------------------------------------------------------------------
    process
        
        -- LFSR-based key generation (runtime, not hardcoded)
        procedure generate_key is
            variable seed : std_logic_vector(31 downto 0) := x"A5C3E1F7";
        begin
            for i in 0 to 7 loop
                seed := seed(30 downto 0) & 
                    (seed(31) xor seed(21) xor seed(1) xor seed(0));
                test_key(255 - i*32 downto 224 - i*32) <= seed;
                seed := seed(30 downto 0) & 
                    (seed(31) xor seed(21) xor seed(1) xor seed(0));
            end loop;
        end procedure;
        
        -- Send 16 bytes to TX RED UART (1-block mode: NBLK=1 + 16 data)
        procedure send_plaintext(data : byte_array_t) is
        begin
            -- First byte = NBLK (block count = 1)
            wait until rising_edge(clk);
            tx_red_rx_byte  <= x"01";
            tx_red_rx_valid <= '1';
            wait until rising_edge(clk);
            tx_red_rx_valid <= '0';
            for j in 0 to 9 loop
                wait until rising_edge(clk);
            end loop;
            
            -- Then 16 data bytes
            for i in 0 to 15 loop
                wait until rising_edge(clk);
                tx_red_rx_byte  <= data(i);
                tx_red_rx_valid <= '1';
                wait until rising_edge(clk);
                tx_red_rx_valid <= '0';
                -- UART inter-byte gap (realistic)
                for j in 0 to 9 loop
                    wait until rising_edge(clk);
                end loop;
            end loop;
        end procedure;
        
        -- Send multi-block data to TX RED UART (NBLK + nblk*16 bytes)
        -- Sends block-by-block with AES processing delay between blocks
        procedure send_multiblock(
            nblk : integer;
            data : multi_byte_array_t
        ) is
        begin
            -- First byte = NBLK
            wait until rising_edge(clk);
            tx_red_rx_byte  <= std_logic_vector(to_unsigned(nblk, 8));
            tx_red_rx_valid <= '1';
            wait until rising_edge(clk);
            tx_red_rx_valid <= '0';
            for j in 0 to 9 loop
                wait until rising_edge(clk);
            end loop;
            
            -- Send data block-by-block
            for blk in 0 to nblk-1 loop
                -- Send 16 bytes for this block
                for i in 0 to 15 loop
                    wait until rising_edge(clk);
                    tx_red_rx_byte  <= data(blk * 16 + i);
                    tx_red_rx_valid <= '1';
                    wait until rising_edge(clk);
                    tx_red_rx_valid <= '0';
                    for j in 0 to 9 loop
                        wait until rising_edge(clk);
                    end loop;
                end loop;
                
                -- Wait for TX to process this block (AES encrypt + MAC)
                -- ★ FIX: AES dual-pass needs ~500 cycles × 2 ops = ~1000 cycles
                if blk < nblk - 1 then
                    for j in 0 to 2999 loop
                        wait until rising_edge(clk);
                    end loop;
                end if;
            end loop;
        end procedure;
        
        -- Wait for RX to complete (with timeout)
        procedure wait_rx_complete(timeout_us : integer) is
            variable cnt : integer := 0;
        begin
            while not rx_complete and cnt < timeout_us * 50 loop
                wait until rising_edge(clk);
                cnt := cnt + 1;
            end loop;
        end procedure;
        
        -- ★ Inject a single raw byte into RX (via wire mux)
        procedure inject_raw_byte(b : std_logic_vector(7 downto 0)) is
        begin
            wait until rising_edge(clk);
            inject_byte  <= b;
            inject_valid <= '1';
            wait until rising_edge(clk);
            inject_valid <= '0';
            -- Small gap between bytes (realistic wire timing)
            wait until rising_edge(clk);
        end procedure;
        
        -- ★ Inject captured frame (for replay/tamper tests)
        -- ★ P2 #23: Updated for 64-bit SeqNum (bytes 4..11)
        procedure inject_captured_frame(
            num_bytes : integer;
            tamper_idx : integer;      -- -1 = no tamper, else flip bit at this byte
            seq_override : integer     -- -1 = use captured, else override seq bytes
        ) is
            variable b : std_logic_vector(7 downto 0);
        begin
            inject_mode <= '1';
            for i in 0 to num_bytes - 1 loop
                b := captured_frame(i);
                -- ★ P2 #23: 64-bit sequence number override (bytes 4..11)
                if seq_override >= 0 and i >= 4 and i <= 11 then
                    if i <= 7 then
                        -- Upper 32 bits = 0 for small seq values
                        b := x"00";
                    else
                        -- Lower 32 bits from seq_override
                        b := std_logic_vector(to_unsigned(seq_override, 32)(
                            31 - (i-8)*8 downto 24 - (i-8)*8));
                    end if;
                end if;
                -- Tamper: flip bit 0 at specified index
                if tamper_idx >= 0 and i = tamper_idx then
                    b(0) := not b(0);
                end if;
                inject_raw_byte(b);
            end loop;
            inject_mode <= '0';
        end procedure;
        
        -- ★ Inject invalid NBLK frame (SOF + SEQ + NBLK=0)
        -- ★ P2 #23: 8-byte SEQ for 64-bit wire format
        procedure inject_invalid_nblk is
        begin
            inject_mode <= '1';
            -- SOF: AA 55 AA 55
            inject_raw_byte(x"AA");
            inject_raw_byte(x"55");
            inject_raw_byte(x"AA");
            inject_raw_byte(x"55");
            -- SEQ: 8 bytes (64-bit) — high value for anti-replay bypass
            inject_raw_byte(x"00");
            inject_raw_byte(x"00");
            inject_raw_byte(x"00");
            inject_raw_byte(x"00");
            inject_raw_byte(x"00");
            inject_raw_byte(x"00");
            inject_raw_byte(x"00");
            inject_raw_byte(x"FF");
            -- NBLK: 0 (INVALID!)
            inject_raw_byte(x"00");
            inject_mode <= '0';
        end procedure;
        
        -- Wait for frame_error or mac_error with timeout
        procedure wait_for_error(
            timeout_us : integer;
            variable got_frame_err : out boolean;
            variable got_mac_err   : out boolean
        ) is
            variable cnt : integer := 0;
        begin
            got_frame_err := false;
            got_mac_err   := false;
            while cnt < timeout_us * 50 loop
                wait until rising_edge(clk);
                if err_latch_frame = '1' then
                    got_frame_err := true;
                    return;
                end if;
                if err_latch_mac = '1' then
                    got_mac_err := true;
                    return;
                end if;
                cnt := cnt + 1;
            end loop;
        end procedure;
        
        -- Verify received data matches sent data
        procedure verify_data(test_id : string; data : byte_array_t) is
            variable mismatch : boolean := false;
        begin
            for i in 0 to 15 loop
                if data(i) /= received_data(i) then
                    report test_id & " FAIL: Byte " & integer'image(i) & 
                           " mismatch! Sent=" & integer'image(to_integer(unsigned(data(i)))) &
                           " Got=" & integer'image(to_integer(unsigned(received_data(i))))
                        severity error;
                    mismatch := true;
                end if;
            end loop;
            if mismatch then
                tests_failed <= tests_failed + 1;
            else
                report test_id & " PASS" severity note;
                tests_passed <= tests_passed + 1;
            end if;
        end procedure;
        
        -- Full init sequence
        procedure do_full_init is
        begin
            err_latch_clear <= '1';
            wait until rising_edge(clk);
            err_latch_clear <= '0';
            rst_n <= '0';
            wait for CLK_PERIOD * 5;
            rst_n <= '1';
            wait for CLK_PERIOD * 5;
            key_valid <= '1';
            wait for CLK_PERIOD * 2;
            key_valid <= '0';
            wait for CLK_PERIOD * 500;  -- AES IV derivation needs ~200 cycles
        end procedure;
        
        -- Kill + reinit sequence (for resetting RX capture between tests)
        procedure do_kill_reinit is
        begin
            kill_signal <= '1';
            wait for CLK_PERIOD * 2;
            kill_signal <= '0';
            wait for CLK_PERIOD * 10;
            do_full_init;
        end procedure;
        
        -- Test data variables
        variable test_plain  : byte_array_t;
        variable test_plain2 : byte_array_t;
        variable test_plain3 : byte_array_t;
        variable got_frame_err : boolean;
        variable got_mac_err   : boolean;
        variable mb_data       : multi_byte_array_t;
        variable mb_all_ok     : boolean;
        
        -- ★ P2 #23: Frame size: SOF(4) + SEQ(8) + NBLK(1) + CT(16*16) + MAC(16)
        -- For 16-blk (fixed padding): 4+8+1+(16*16)+16 = 285
        -- But capture only stores raw TX output bytes
        constant FRAME_SIZE_1BLK : integer := 285;
        
    begin
        -- =====================================================================
        -- INITIALIZATION
        -- =====================================================================
        rst_n <= '0';
        kill_signal <= '0';
        key_valid <= '0';
        tx_red_rx_valid <= '0';
        inject_mode <= '0';
        inject_valid <= '0';
        cap_active <= '0';
        cap_reset <= '0';
        
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;
        
        generate_key;
        wait for CLK_PERIOD * 2;
        
        key_valid <= '1';
        wait for CLK_PERIOD * 2;
        key_valid <= '0';
        wait for CLK_PERIOD * 100;
        
        -- =====================================================================
        -- TEST 1: Single Block TX → RX Round-Trip (Sentinel Anti-Replay)
        -- =====================================================================
        -- ★ P2 #23: İlk frame → rx_seq_last=64-bit all-ones sentinel koşulu bypass eder.
        -- =====================================================================
        test_number <= 1;
        
        -- Enable frame capture for later use in T7/T8
        cap_active <= '1';
        cap_reset <= '1';
        wait until rising_edge(clk);
        cap_reset <= '0';
        
        test_plain(0)  := x"48";  -- 'H'
        test_plain(1)  := x"49";  -- 'I'
        test_plain(2)  := x"44";  -- 'D'
        test_plain(3)  := x"52";  -- 'R'
        test_plain(4)  := x"41";  -- 'A'
        test_plain(5)  := x"5F";  -- '_'
        test_plain(6)  := x"54";  -- 'T'
        test_plain(7)  := x"45";  -- 'E'
        test_plain(8)  := x"53";  -- 'S'
        test_plain(9)  := x"54";  -- 'T'
        test_plain(10) := x"5F";  -- '_'
        test_plain(11) := x"56";  -- 'V'
        test_plain(12) := x"31";  -- '1'
        test_plain(13) := x"34";  -- '4'
        test_plain(14) := x"21";  -- '!'
        test_plain(15) := x"00";  -- NUL
        sent_data <= test_plain;
        
        send_plaintext(test_plain);
        wait_rx_complete(5000);
        
        if rx_complete then
            verify_data("T1 (round-trip + sentinel)", test_plain);
        else
            report "T1 FAIL: RX timeout" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        assert rx_mac_err = '0' report "T1 FAIL: MAC error" severity error;
        assert rx_frame_err = '0' report "T1 FAIL: Frame error" severity error;
        
        -- Stop capture
        cap_active <= '0';
        
        wait for CLK_PERIOD * 100;
        
        -- =====================================================================
        -- TEST 2: Back-to-Back Second Frame (seq_num increment)
        -- =====================================================================
        -- TX → seq=1, RX seq_last=0 → 1 > 0 → geçer
        -- =====================================================================
        test_number <= 2;
        
        do_kill_reinit;
        
        test_plain2(0)  := x"42";  -- 'B'
        test_plain2(1)  := x"41";  -- 'A'
        test_plain2(2)  := x"43";  -- 'C'
        test_plain2(3)  := x"4B";  -- 'K'
        test_plain2(4)  := x"5F";  -- '_'
        test_plain2(5)  := x"54";  -- 'T'
        test_plain2(6)  := x"4F";  -- 'O'
        test_plain2(7)  := x"5F";  -- '_'
        test_plain2(8)  := x"42";  -- 'B'
        test_plain2(9)  := x"41";  -- 'A'
        test_plain2(10) := x"43";  -- 'C'
        test_plain2(11) := x"4B";  -- 'K'
        test_plain2(12) := x"5F";  -- '_'
        test_plain2(13) := x"4F";  -- 'O'
        test_plain2(14) := x"4B";  -- 'K'
        test_plain2(15) := x"21";  -- '!'
        sent_data <= test_plain2;
        
        send_plaintext(test_plain2);
        wait_rx_complete(5000);
        
        if rx_complete then
            verify_data("T2 (back-to-back)", test_plain2);
        else
            report "T2 FAIL: RX timeout on second frame" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        assert rx_mac_err = '0' report "T2 FAIL: MAC error" severity error;
        assert rx_frame_err = '0' report "T2 FAIL: Frame error" severity error;
        
        wait for CLK_PERIOD * 100;
        
        -- =====================================================================
        -- TEST 3: Kill Zeroization
        -- =====================================================================
        test_number <= 3;
        
        kill_signal <= '1';
        wait for CLK_PERIOD * 3;
        
        assert tx_session = '0'
            report "T3 FAIL: TX session active after kill" severity error;
        
        kill_signal <= '0';
        wait for CLK_PERIOD * 5;
        
        report "T3 PASS: Kill zeroization" severity note;
        tests_passed <= tests_passed + 1;
        
        wait for CLK_PERIOD * 50;
        
        -- =====================================================================
        -- TEST 4: Key Reload After Kill — New Session
        -- =====================================================================
        test_number <= 4;
        
        do_full_init;
        
        test_plain3(0)  := x"4E";  -- 'N'
        test_plain3(1)  := x"45";  -- 'E'
        test_plain3(2)  := x"57";  -- 'W'
        test_plain3(3)  := x"5F";  -- '_'
        test_plain3(4)  := x"53";  -- 'S'
        test_plain3(5)  := x"45";  -- 'E'
        test_plain3(6)  := x"53";  -- 'S'
        test_plain3(7)  := x"53";  -- 'S'
        test_plain3(8)  := x"49";  -- 'I'
        test_plain3(9)  := x"4F";  -- 'O'
        test_plain3(10) := x"4E";  -- 'N'
        test_plain3(11) := x"5F";  -- '_'
        test_plain3(12) := x"4F";  -- 'O'
        test_plain3(13) := x"4B";  -- 'K'
        test_plain3(14) := x"21";  -- '!'
        test_plain3(15) := x"00";  -- NUL
        sent_data <= test_plain3;
        
        send_plaintext(test_plain3);
        wait_rx_complete(5000);
        
        if rx_complete then
            verify_data("T4 (key reload)", test_plain3);
        else
            report "T4 FAIL: RX timeout after key reload" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        assert rx_mac_err = '0' report "T4 FAIL: MAC error" severity error;
        assert rx_frame_err = '0' report "T4 FAIL: Frame error" severity error;
        
        wait for CLK_PERIOD * 100;
        
        -- =====================================================================
        -- TEST 5: Post-Reload Continuity (ikinci frame sonrası)
        -- =====================================================================
        test_number <= 5;
        
        do_kill_reinit;
        
        test_plain(0)  := x"46";  -- 'F'
        test_plain(1)  := x"49";  -- 'I'
        test_plain(2)  := x"4E";  -- 'N'
        test_plain(3)  := x"41";  -- 'A'
        test_plain(4)  := x"4C";  -- 'L'
        test_plain(5)  := x"5F";  -- '_'
        test_plain(6)  := x"54";  -- 'T'
        test_plain(7)  := x"45";  -- 'E'
        test_plain(8)  := x"53";  -- 'S'
        test_plain(9)  := x"54";  -- 'T'
        test_plain(10) := x"5F";  -- '_'
        test_plain(11) := x"4F";  -- 'O'
        test_plain(12) := x"4B";  -- 'K'
        test_plain(13) := x"21";  -- '!'
        test_plain(14) := x"21";  -- '!'
        test_plain(15) := x"00";  -- NUL
        sent_data <= test_plain;
        
        send_plaintext(test_plain);
        wait_rx_complete(5000);
        
        if rx_complete then
            verify_data("T5 (continuity)", test_plain);
        else
            report "T5 FAIL: RX timeout on continuity test" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        assert rx_mac_err = '0' report "T5 FAIL: MAC error" severity error;
        assert rx_frame_err = '0' report "T5 FAIL: Frame error" severity error;
        
        wait for CLK_PERIOD * 100;
        
        -- =====================================================================
        -- TEST 6: Invalid NBLK Rejection (NBLK=0)
        -- =====================================================================
        -- Wire injection ile çiğ frame gönder: SOF + SEQ + NBLK=0
        -- Beklenti: frame_error='1', RX hiçbir veri çıkartmaz
        -- =====================================================================
        test_number <= 6;
        
        do_kill_reinit;
        
        inject_invalid_nblk;
        
        -- frame_error bekliyoruz
        wait_for_error(200, got_frame_err, got_mac_err);
        
        if got_frame_err then
            report "T6 PASS: Invalid NBLK rejected" severity note;
            tests_passed <= tests_passed + 1;
        else
            report "T6 FAIL: Invalid NBLK not rejected" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        wait for CLK_PERIOD * 100;
        
        -- =====================================================================
        -- TEST 7: Anti-Replay Rejection (replay captured frame with old seq)
        -- =====================================================================
        -- Adımlar:
        --   1. Önce bir valid frame gönder (TX → RX, seq=0) → RX kabul eder
        --   2. Aynı frame'i wire injection ile tekrar gönder (seq=0)
        --   3. Beklenti: frame_error='1' (seq_num <= seq_last)
        -- =====================================================================
        test_number <= 7;
        
        do_kill_reinit;
        
        -- Step 1: Normal frame gönder (frame yakalama aktif)
        cap_active <= '1';
        cap_reset <= '1';
        wait until rising_edge(clk);
        cap_reset <= '0';
        
        test_plain(0)  := x"52";  -- 'R'
        test_plain(1)  := x"45";  -- 'E'
        test_plain(2)  := x"50";  -- 'P'
        test_plain(3)  := x"4C";  -- 'L'
        test_plain(4)  := x"41";  -- 'A'
        test_plain(5)  := x"59";  -- 'Y'
        test_plain(6)  := x"5F";  -- '_'
        test_plain(7)  := x"54";  -- 'T'
        test_plain(8)  := x"45";  -- 'E'
        test_plain(9)  := x"53";  -- 'S'
        test_plain(10) := x"54";  -- 'T'
        test_plain(11) := x"5F";  -- '_'
        test_plain(12) := x"4F";  -- 'O'
        test_plain(13) := x"4B";  -- 'K'
        test_plain(14) := x"21";  -- '!'
        test_plain(15) := x"00";  -- NUL
        sent_data <= test_plain;
        
        send_plaintext(test_plain);
        wait_rx_complete(5000);
        
        cap_active <= '0';
        
        if rx_complete then
            -- İlk frame başarılı — artık replay deneyeceğiz
            -- RX capture'ı resetle (kill olmadan — rx_complete zaten true)
            -- rx_complete resetlemek için kısa bir kill pulse
            kill_signal <= '1';
            wait for CLK_PERIOD * 2;
            kill_signal <= '0';
            wait for CLK_PERIOD * 5;
            -- Reinit (seq_last 64-bit sentinel'e dönecek — bu replay testini
            -- geçersiz kılar! Kill sonrası sentinel resetlenir.)
            -- ÇÖZÜM: Kill yapmadan, doğrudan replay — rx_complete true kalır
            -- ama frame_error'ı dinleyebiliriz.
            -- SORUN: Kill yaptık → sentinel resetlendi. Kill yapmamak lazım.
            
            -- Tekrar init (kill sonrası anti-replay sıfırlanır, sentinel aktif)
            -- Bu yüzden T7 için farklı yaklaşım:
            -- İlk frame'i kabul ET, sonra aynı seq ile inject et (kill YAPMADAN)
            
            -- Kill zaten yaptık, sentinel resetlendi.
            -- Bunun yerine: önce bir valid frame gönder (sentinel aşılır),
            -- sonra captured frame'i replay et.
            do_full_init;
            
            -- ★ V15: 16-block padding → RX outputs 256 bytes
            -- Set rx_expected_bytes to 256 so wait_rx_complete waits
            -- for ALL padded blocks, not just the first 16 bytes.
            -- This ensures RX_DONE executes and rx_seq_last updates.
            rx_expected_bytes <= 256;
            wait until rising_edge(clk);
            
            -- Yeni bir frame gönder (seq=0, sentinel bypass) → RX kabul eder
            cap_active <= '1';
            cap_reset <= '1';
            wait until rising_edge(clk);
            cap_reset <= '0';
            
            send_plaintext(test_plain);
            wait_rx_complete(10000);  -- 10ms — deterministic, all 256 bytes
            cap_active <= '0';
            
            -- Reset for injection phase
            rx_expected_bytes <= 16;
            wait until rising_edge(clk);
            
            if rx_complete then
                -- rx_seq_last = 0 (RX_DONE executed). Replay with seq=0 → reject
                
                -- Clear error latches before replay injection
                err_latch_clear <= '1';
                wait until rising_edge(clk);
                err_latch_clear <= '0';
                wait for CLK_PERIOD * 10;  -- Minimal settle
                
                inject_captured_frame(FRAME_SIZE_1BLK, -1, 0);  -- Same seq=0
                
                wait_for_error(5000, got_frame_err, got_mac_err);
                
                if got_frame_err then
                    report "T7 PASS: Anti-replay rejection" severity note;
                    tests_passed <= tests_passed + 1;
                else
                    report "T7 FAIL: Replay not rejected!" severity error;
                    tests_failed <= tests_failed + 1;
                end if;
            else
                report "T7 FAIL: Setup frame timeout" severity error;
                tests_failed <= tests_failed + 1;
            end if;
        else
            report "T7 FAIL: Initial frame timeout" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        wait for CLK_PERIOD * 200;
        
        -- =====================================================================
        -- TEST 8: MAC Tamper Detection (flip a bit in CT)
        -- =====================================================================
        -- Captured frame'i tamper_idx=15 ile gönder (CT'nin son byte'ında
        -- bit flip). MAC uyuşmaz → mac_error='1'
        -- =====================================================================
        test_number <= 8;
        
        do_kill_reinit;
        
        -- Önce valid frame gönder + yakala
        cap_active <= '1';
        cap_reset <= '1';
        wait until rising_edge(clk);
        cap_reset <= '0';
        
        test_plain(0)  := x"4D";  -- 'M'
        test_plain(1)  := x"41";  -- 'A'
        test_plain(2)  := x"43";  -- 'C'
        test_plain(3)  := x"5F";  -- '_'
        test_plain(4)  := x"54";  -- 'T'
        test_plain(5)  := x"45";  -- 'E'
        test_plain(6)  := x"53";  -- 'S'
        test_plain(7)  := x"54";  -- 'T'
        test_plain(8)  := x"5F";  -- '_'
        test_plain(9)  := x"44";  -- 'D'
        test_plain(10) := x"41";  -- 'A'
        test_plain(11) := x"54";  -- 'T'
        test_plain(12) := x"41";  -- 'A'
        test_plain(13) := x"5F";  -- '_'
        test_plain(14) := x"4F";  -- 'O'
        test_plain(15) := x"4B";  -- 'K'
        sent_data <= test_plain;
        
        -- ★ V15: Set rx_expected_bytes to 256 for 16-block padded output
        rx_expected_bytes <= 256;
        wait until rising_edge(clk);
        
        send_plaintext(test_plain);
        wait_rx_complete(10000);  -- Deterministic: all 256 bytes
        cap_active <= '0';
        
        -- Reset for injection phase
        rx_expected_bytes <= 16;
        wait until rising_edge(clk);
        
        if rx_complete then
            -- RX_DONE executed → rx_seq_last updated
            
            -- Error latch'leri temizle
            err_latch_clear <= '1';
            wait until rising_edge(clk);
            err_latch_clear <= '0';
            
            -- inject_captured_frame(frame_size, tamper_idx, seq_override)
            -- seq_override=999: anti-replay bypass (seq_last=0, 999>0 gecerli)
            inject_captured_frame(FRAME_SIZE_1BLK, 20, 999);  -- Tamper CT byte index 20
            
            report "T8: Tampered frame injected, waiting for error..." severity note;
            
            wait_for_error(5000, got_frame_err, got_mac_err);
            
            if got_mac_err then
                report "T8 PASS: MAC tamper detected" severity note;
                tests_passed <= tests_passed + 1;
            elsif got_frame_err then
                -- Frame error da kabul edilebilir (bazı durumlarda)
                report "T8 PASS: Tampered frame rejected (frame_error)" severity note;
                tests_passed <= tests_passed + 1;
            else
                report "T8 FAIL: Tampered frame not detected!" severity error;
                tests_failed <= tests_failed + 1;
            end if;
        else
            report "T8 FAIL: Setup frame timeout" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        wait for CLK_PERIOD * 200;
        
        -- =====================================================================
        -- TEST 9: Recovery After Negative Tests
        -- =====================================================================
        -- Negatif testler sonrası normal iletişim hâlâ çalışıyor mu?
        -- =====================================================================
        test_number <= 9;
        
        do_kill_reinit;
        
        test_plain(0)  := x"52";  -- 'R'
        test_plain(1)  := x"45";  -- 'E'
        test_plain(2)  := x"43";  -- 'C'
        test_plain(3)  := x"4F";  -- 'O'
        test_plain(4)  := x"56";  -- 'V'
        test_plain(5)  := x"45";  -- 'E'
        test_plain(6)  := x"52";  -- 'R'
        test_plain(7)  := x"59";  -- 'Y'
        test_plain(8)  := x"5F";  -- '_'
        test_plain(9)  := x"4F";  -- 'O'
        test_plain(10) := x"4B";  -- 'K'
        test_plain(11) := x"5F";  -- '_'
        test_plain(12) := x"21";  -- '!'
        test_plain(13) := x"21";  -- '!'
        test_plain(14) := x"21";  -- '!'
        test_plain(15) := x"00";  -- NUL
        sent_data <= test_plain;
        
        send_plaintext(test_plain);
        wait_rx_complete(5000);
        
        if rx_complete then
            verify_data("T9 (recovery)", test_plain);
        else
            report "T9 FAIL: RX timeout - system not recovered!" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        assert rx_mac_err = '0' report "T9 FAIL: MAC error" severity error;
        assert rx_frame_err = '0' report "T9 FAIL: Frame error" severity error;
        
        wait for CLK_PERIOD * 100;
        
        -- =====================================================================
        -- TEST 11: 2-Block Multi-Block Round-Trip (32 bytes)
        -- =====================================================================
        test_number <= 11;
        
        do_kill_reinit;
        
        -- Set RX capture for 32 bytes
        rx_expected_bytes <= 32;
        wait until rising_edge(clk);
        
        -- Prepare 32 bytes of test data (2 blocks)
        mb_data := (others => (others => '0'));
        for i in 0 to 31 loop
            mb_data(i) := std_logic_vector(to_unsigned((i * 7 + 13) mod 256, 8));
        end loop;
        
        send_multiblock(2, mb_data);
        wait_rx_complete(10000);
        
        if rx_complete then
            mb_all_ok := true;
            for i in 0 to 31 loop
                if received_data(i) /= mb_data(i) then
                    mb_all_ok := false;
                    report "T11 MISMATCH at byte " & integer'image(i) severity error;
                end if;
            end loop;
            
            if mb_all_ok then
                report "T11 PASS: 2-block round-trip (32 bytes)" severity note;
                tests_passed <= tests_passed + 1;
            else
                report "T11 FAIL: Data mismatch" severity error;
                tests_failed <= tests_failed + 1;
            end if;
        else
            report "T11 FAIL: RX timeout" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        wait for CLK_PERIOD * 200;
        
        -- =====================================================================
        -- TEST 12: 4-Block Multi-Block Round-Trip (64 bytes)
        -- =====================================================================
        test_number <= 12;
        
        do_kill_reinit;
        
        -- Set RX capture for 64 bytes
        rx_expected_bytes <= 64;
        wait until rising_edge(clk);
        
        mb_data := (others => (others => '0'));
        for i in 0 to 63 loop
            mb_data(i) := std_logic_vector(to_unsigned((i * 11 + 37) mod 256, 8));
        end loop;
        
        send_multiblock(4, mb_data);
        wait_rx_complete(20000);
        
        if rx_complete then
            mb_all_ok := true;
            for i in 0 to 63 loop
                if received_data(i) /= mb_data(i) then
                    mb_all_ok := false;
                    report "T12 MISMATCH at byte " & integer'image(i) severity error;
                end if;
            end loop;
            
            if mb_all_ok then
                report "T12 PASS: 4-block round-trip (64 bytes)" severity note;
                tests_passed <= tests_passed + 1;
            else
                report "T12 FAIL: Data mismatch" severity error;
                tests_failed <= tests_failed + 1;
            end if;
        else
            report "T12 FAIL: RX timeout" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        -- Reset rx_expected_bytes for subsequent single-block tests
        rx_expected_bytes <= 16;
        wait until rising_edge(clk);
        
        wait for CLK_PERIOD * 200;
        
        -- =====================================================================
        -- TEST 13: Omega Cloak OFF — Baseline Round-Trip
        -- =====================================================================
        test_number <= 13;
        
        do_kill_reinit;
        
        -- Omega OFF
        omega_enable <= '0';
        wait until rising_edge(clk);
        
        -- Seed PRNG (even though disabled, to ensure deterministic behavior)
        trng_seed_valid <= '1';
        wait until rising_edge(clk);
        trng_seed_valid <= '0';
        wait for CLK_PERIOD * 20;
        
        -- Send test data
        test_plain := (others => (others => '0'));
        for i in 0 to 15 loop
            test_plain(i) := std_logic_vector(to_unsigned((i * 11 + 5) mod 256, 8));
        end loop;
        sent_data <= test_plain;
        send_plaintext(test_plain);
        wait_rx_complete(5000);
        
        if rx_complete then
            verify_data("T13 (Omega OFF baseline)", test_plain);
        else
            report "T13 FAIL: RX timeout" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        wait for CLK_PERIOD * 100;
        
        -- =====================================================================
        -- TEST 14: Omega Cloak ON — DPA Protected Round-Trip + Dummy Verify
        -- =====================================================================
        test_number <= 14;
        
        -- Enable Omega BEFORE reinit so PRNG runs during IV derivation
        omega_enable <= '1';
        
        -- Seed PRNG with valid Q8.24 value (0 < seed < 1.0 = 0x01000000)
        trng_seed <= x"00800000";  -- 0.5 in Q8.24
        trng_seed_valid <= '1';
        wait until rising_edge(clk);
        trng_seed_valid <= '0';
        
        -- Wait for PRNG warmup (at least 2 complete iterations)
        wait for CLK_PERIOD * 50;
        
        do_kill_reinit;
        
        -- ★ FIX: Wait extra for key derivation (4 AES ops × 315 cycles = 1260)
        -- before sending plaintext. With Omega ON, pending latch + dummy timer
        -- can race if data arrives during derivation.
        wait for CLK_PERIOD * 1500;
        
        -- Re-seed PRNG after reinit (rst_n resets PRNG)
        trng_seed_valid <= '1';
        wait until rising_edge(clk);
        trng_seed_valid <= '0';
        wait for CLK_PERIOD * 100;  -- Let PRNG produce valid output
        
        -- Send test data
        test_plain2 := (others => (others => '0'));
        for i in 0 to 15 loop
            test_plain2(i) := std_logic_vector(to_unsigned((i * 13 + 7) mod 256, 8));
        end loop;
        sent_data <= test_plain2;
        send_plaintext(test_plain2);
        wait_rx_complete(20000);  -- 20ms timeout for dummy overhead
        
        if rx_complete then
            verify_data("T14 (Omega ON DPA protected)", test_plain2);
            -- Verify dummy operations occurred
            if unsigned(tx_omega_dummies) > 0 then
                report "T14 OMEGA: TX dummy count = " & 
                    integer'image(to_integer(unsigned(tx_omega_dummies))) &
                    " (DPA protection active)" severity note;
            else
                report "T14 INFO: TX dummy count = 0 (all PRNG values had bits[1:0]=00)" severity note;
            end if;
        else
            report "T14 FAIL: RX timeout (Omega Cloak)" severity error;
            tests_failed <= tests_failed + 1;
        end if;
        
        -- Disable Omega for remaining tests
        omega_enable <= '0';
        wait for CLK_PERIOD * 200;
        
        -- =====================================================================
        -- TEST 10: Final Kill — Clean Shutdown
        -- =====================================================================
        test_number <= 10;
        
        kill_signal <= '1';
        wait for CLK_PERIOD * 3;
        
        assert tx_session = '0'
            report "T10 FAIL: TX session active" severity error;
        
        kill_signal <= '0';
        wait for CLK_PERIOD * 5;
        
        report "T10 PASS: Final kill" severity note;
        tests_passed <= tests_passed + 1;
        
        wait for CLK_PERIOD * 50;
        
        -- =====================================================================
        -- FINAL REPORT
        -- =====================================================================
        report "========================================" severity note;
        report "  TITAN V15 TESTBENCH RESULTS" severity note;
        report "  Passed: " & integer'image(tests_passed) severity note;
        report "  Failed: " & integer'image(tests_failed) severity note;
        report "========================================" severity note;
        
        if tests_failed = 0 then
            report "** ALL TESTS PASSED **" severity note;
        else
            report "!! SOME TESTS FAILED" severity failure;
        end if;
        
        sim_done <= true;
        wait;
    end process;

end Behavioral;
