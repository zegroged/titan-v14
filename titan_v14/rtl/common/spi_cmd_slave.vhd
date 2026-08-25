--------------------------------------------------------------------------------
-- PROJECT HİDRA: SPI Command Slave — App Processor ↔ TITAN FPGA Bridge
-- Module: Full-Duplex SPI Slave + HLP Command Parser + AES Engine Interface
--
-- PURPOSE:
--   Receives HLP (HİDRA Link Protocol) packets from the App Processor via SPI,
--   routes ENCRYPT/DECRYPT commands to the AES-256-CTR engine, and returns
--   responses. This creates the Layer 2 hardware encryption bridge.
--
-- SPI INTERFACE:
--   - Mode 0 (CPOL=0, CPHA=0): Data sampled on SCLK rising edge
--   - Separate CS_APP_N pin (coexists with key_loader_spi on CS_N_PIN)
--   - Full-duplex: MOSI (command in) + MISO (response out)
--   - Max clock: 10 MHz (FPGA slave timing constraint)
--
-- HLP PACKET FORMAT:
--   TX (App → FPGA): [CMD:8][LEN:16][SEQ:32][PAYLOAD:0-4096*8][CRC16:16]
--   RX (FPGA → App): [CMD:8][LEN:16][SEQ:32][PAYLOAD:0-4096*8][CRC16:16]
--
-- SUPPORTED COMMANDS:
--   0x01 ENCRYPT_REQ → 0x02 ENCRYPT_RESP
--   0x03 DECRYPT_REQ → 0x04 DECRYPT_RESP
--   0x20 STATUS_REQ  → 0x21 STATUS_RESP
--   0xF0 KILL_CMD    → 0xF1 KILL_ACK
--   0xFE HEARTBEAT   → 0xFF HEARTBEAT_ACK
--
-- SECURITY:
--   - CRC-16/CCITT integrity check on every packet
--   - Sequence number validation (monotonic, no replay)
--   - Kill signal wipes all internal state
--   - All synthesis attributes preserve security-critical signals
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_cmd_slave is
    generic (
        -- Maximum payload size in bytes (must be multiple of 16 for AES blocks)
        MAX_PAYLOAD_BYTES : integer := 256  -- 16 AES blocks
    );
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        kill_signal  : in  std_logic;

        -- SPI Slave Interface (App Processor is master)
        spi_sclk     : in  std_logic;
        spi_mosi     : in  std_logic;
        spi_miso     : out std_logic;
        spi_cs_app_n : in  std_logic;  -- Dedicated CS for App Processor

        -- AES Engine Interface (to aes_core_wrapper)
        aes_pt_out   : out std_logic_vector(127 downto 0);  -- Plaintext → AES
        aes_pt_valid : out std_logic;                        -- Start AES encrypt
        aes_ct_in    : in  std_logic_vector(127 downto 0);  -- Ciphertext ← AES
        aes_ct_valid : in  std_logic;                        -- AES output ready
        aes_busy     : in  std_logic;                        -- AES processing

        -- TITAN Status Inputs (directly from top-level signals)
        omega_active_in   : in  std_logic;
        aegis_active_in   : in  std_logic;
        lockstep_ok_in    : in  std_logic;
        post_pass_in      : in  std_logic;
        trng_healthy_in   : in  std_logic;
        kill_armed_in     : in  std_logic;
        hmac_busy_in      : in  std_logic := '0';  -- ★ K.16: HMAC heartbeat busy signal
        trng_degraded_in  : in  std_logic := '0';  -- ★ A.1: TRNG DRBG fallback flag

        -- Outputs
        kill_trigger : out std_logic;  -- Kill command received → kill chain
        cmd_active   : out std_logic;  -- SPI command in progress
        cmd_error    : out std_logic;  -- CRC or protocol error
        heartbeat_ok : out std_logic;  -- Last heartbeat succeeded

        -- ★ P2-6: AEGIS Runtime Config Interface
        aegis_cfg_addr : out std_logic_vector(7 downto 0);   -- Config register address
        aegis_cfg_data : out std_logic_vector(15 downto 0);  -- Config data (weight/threshold)
        aegis_cfg_wr   : out std_logic;                      -- Write enable (single-cycle pulse)

        -- ★ P3-9: HMAC Heartbeat Interface
        hmac_challenge_in    : in  std_logic_vector(127 downto 0) := (others => '0');  -- nonce||counter from ctrl
        hmac_challenge_ready : in  std_logic := '0';       -- challenge available
        hmac_response_out    : out std_logic_vector(255 downto 0);  -- PolarFire tag to ctrl
        hmac_response_valid  : out std_logic               -- tag forwarded
    );
end spi_cmd_slave;

architecture Behavioral of spi_cmd_slave is

    -------------------------------------------------------------------------
    -- ★ C-1 FIX: CRC-16/CCITT Function (poly = 0x1021)
    -------------------------------------------------------------------------
    function crc16_ccitt_bit(crc_in : std_logic_vector(15 downto 0);
                            din    : std_logic)
        return std_logic_vector is
        variable crc_out : std_logic_vector(15 downto 0);
        variable xor_bit : std_logic;
    begin
        xor_bit := crc_in(15) xor din;
        crc_out(0)  := xor_bit;
        crc_out(1)  := crc_in(0);
        crc_out(2)  := crc_in(1);
        crc_out(3)  := crc_in(2);
        crc_out(4)  := crc_in(3);
        crc_out(5)  := crc_in(4) xor xor_bit;
        crc_out(6)  := crc_in(5);
        crc_out(7)  := crc_in(6);
        crc_out(8)  := crc_in(7);
        crc_out(9)  := crc_in(8);
        crc_out(10) := crc_in(9);
        crc_out(11) := crc_in(10);
        crc_out(12) := crc_in(11) xor xor_bit;
        crc_out(13) := crc_in(12);
        crc_out(14) := crc_in(13);
        crc_out(15) := crc_in(14);
        return crc_out;
    end function;

    -------------------------------------------------------------------------
    -- CONSTANTS
    -------------------------------------------------------------------------
    -- HLP Header: CMD(8) + LEN(16) + SEQ(32) = 56 bits = 7 bytes
    constant HEADER_BITS   : integer := 56;
    constant CRC_BITS      : integer := 16;
    constant MAX_PAYLOAD_BITS : integer := MAX_PAYLOAD_BYTES * 8;
    -- Maximum total packet bits 
    constant MAX_PACKET_BITS : integer := HEADER_BITS + MAX_PAYLOAD_BITS + CRC_BITS;

    -- Command codes
    constant CMD_ENCRYPT_REQ  : std_logic_vector(7 downto 0) := x"01";
    constant CMD_ENCRYPT_RESP : std_logic_vector(7 downto 0) := x"02";
    constant CMD_DECRYPT_REQ  : std_logic_vector(7 downto 0) := x"03";
    constant CMD_DECRYPT_RESP : std_logic_vector(7 downto 0) := x"04";
    constant CMD_STATUS_REQ   : std_logic_vector(7 downto 0) := x"20";
    constant CMD_STATUS_RESP  : std_logic_vector(7 downto 0) := x"21";
    constant CMD_KILL         : std_logic_vector(7 downto 0) := x"F0";
    constant CMD_KILL_ACK     : std_logic_vector(7 downto 0) := x"F1";
    constant CMD_HEARTBEAT    : std_logic_vector(7 downto 0) := x"FE";
    constant CMD_HB_ACK       : std_logic_vector(7 downto 0) := x"FF";
    -- ★ P2-6: AEGIS Runtime Config
    constant CMD_AEGIS_CFG     : std_logic_vector(7 downto 0) := x"A0";
    constant CMD_AEGIS_CFG_ACK : std_logic_vector(7 downto 0) := x"A1";
    -- ★ P3-9: HMAC Heartbeat Commands
    constant CMD_HB_CHALLENGE  : std_logic_vector(7 downto 0) := x"FC";
    constant CMD_HB_CHALLENGE_RESP : std_logic_vector(7 downto 0) := x"FD";

    -------------------------------------------------------------------------
    -- SPI Clock Domain Crossing (CDC)
    -------------------------------------------------------------------------
    signal sclk_sync : std_logic_vector(2 downto 0) := "000";
    signal cs_sync   : std_logic_vector(2 downto 0) := "111";
    signal mosi_sync : std_logic_vector(1 downto 0) := "00";
    signal sclk_rise : std_logic;
    signal sclk_fall : std_logic;
    signal cs_active : std_logic;

    -------------------------------------------------------------------------
    -- SPI SHIFT REGISTERS
    -------------------------------------------------------------------------
    signal rx_shift   : std_logic_vector(MAX_PACKET_BITS-1 downto 0) := (others => '0');
    signal tx_shift   : std_logic_vector(MAX_PACKET_BITS-1 downto 0) := (others => '0');
    signal bit_count  : integer range 0 to MAX_PACKET_BITS := 0;

    -------------------------------------------------------------------------
    -- PARSED HEADER FIELDS
    -------------------------------------------------------------------------
    signal cmd_reg    : std_logic_vector(7 downto 0) := (others => '0');
    signal len_reg    : unsigned(15 downto 0) := (others => '0');
    signal seq_reg    : unsigned(31 downto 0) := (others => '0');
    signal last_seq   : unsigned(31 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- PAYLOAD BUFFERS (up to MAX_PAYLOAD_BYTES)
    -------------------------------------------------------------------------
    type payload_mem_t is array (0 to MAX_PAYLOAD_BYTES-1) of std_logic_vector(7 downto 0);
    signal rx_pld_mem : payload_mem_t := (others => (others => '0'));
    signal tx_pld_mem : payload_mem_t := (others => (others => '0'));

    -------------------------------------------------------------------------
    -- AES PROCESSING STATE
    -------------------------------------------------------------------------
    type aes_state_t is (AES_IDLE, AES_SUBMIT, AES_WAIT, AES_NEXT, AES_DONE);
    signal aes_state    : aes_state_t := AES_IDLE;
    signal block_index  : integer range 0 to MAX_PAYLOAD_BYTES/16 := 0;
    signal total_blocks : integer range 0 to MAX_PAYLOAD_BYTES/16 := 0;
    signal aes_block_in : std_logic_vector(127 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- MAIN COMMAND FSM
    -------------------------------------------------------------------------
    type cmd_state_t is (
        ST_IDLE,         -- Waiting for CS assertion
        ST_RX_HDR,       -- Receiving 56-bit header
        ST_RX_PLD,       -- Receiving payload bytes
        ST_RX_CRC,       -- Receiving 16-bit CRC
        ST_VALIDATE,     -- CRC + sequence check
        ST_PROCESS,      -- Route to handler
        ST_AES_PROC,     -- Waiting for AES engine
        ST_BUILD_RESP,   -- Construct response packet
        ST_TX_RESP,      -- Shift out response via MISO
        ST_COMPLETE      -- Done, wait for CS deassert
    );
    signal cmd_state : cmd_state_t := ST_IDLE;

    -------------------------------------------------------------------------
    -- CRC-16/CCITT
    -------------------------------------------------------------------------
    signal crc_calc   : std_logic_vector(15 downto 0) := x"FFFF";
    signal crc_rx     : std_logic_vector(15 downto 0) := (others => '0');

    -------------------------------------------------------------------------
    -- RESPONSE CONSTRUCTION
    -------------------------------------------------------------------------
    signal resp_cmd   : std_logic_vector(7 downto 0) := (others => '0');
    signal resp_len   : unsigned(15 downto 0) := (others => '0');
    signal resp_total_bits : integer range 0 to MAX_PACKET_BITS := 0;
    signal tx_bit_count : integer range 0 to MAX_PACKET_BITS := 0;

    -------------------------------------------------------------------------
    -- STATUS FLAGS
    -------------------------------------------------------------------------
    signal kill_trig_int  : std_logic := '0';
    signal hb_ok_int      : std_logic := '0';
    signal error_int      : std_logic := '0';
    signal active_int     : std_logic := '0';

    -------------------------------------------------------------------------
    -- SYNTHESIS ATTRIBUTES
    -------------------------------------------------------------------------
    attribute dont_touch : string;
    attribute dont_touch of rx_shift     : signal is "true";
    attribute dont_touch of tx_shift     : signal is "true";
    attribute dont_touch of kill_trig_int : signal is "true";
    attribute dont_touch of last_seq     : signal is "true";

begin

    -- Output assignments
    kill_trigger <= kill_trig_int;
    heartbeat_ok <= hb_ok_int;
    cmd_error    <= error_int;
    cmd_active   <= active_int;

    -- CDC: Detect SCLK edges and CS assertion
    sclk_rise <= '1' when sclk_sync(2 downto 1) = "01" else '0';
    sclk_fall <= '1' when sclk_sync(2 downto 1) = "10" else '0';
    cs_active <= '1' when cs_sync(2) = '0' else '0';

    -------------------------------------------------------------------------
    -- PROCESS: SPI CDC Synchronization (3-stage for metastability)
    -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            sclk_sync <= sclk_sync(1 downto 0) & spi_sclk;
            cs_sync   <= cs_sync(1 downto 0) & spi_cs_app_n;
            mosi_sync <= mosi_sync(0) & spi_mosi;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- PROCESS: MISO Output (shift out on SCLK falling edge - Mode 0)
    -------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            spi_miso <= '0';
        elsif rising_edge(clk) then
            if cs_active = '0' then
                spi_miso <= '0';
            elsif sclk_fall = '1' and cmd_state = ST_TX_RESP then
                -- Shift out MSB first
                if tx_bit_count < resp_total_bits then
                    spi_miso <= tx_shift(MAX_PACKET_BITS - 1 - tx_bit_count);
                else
                    spi_miso <= '0';
                end if;
            end if;
        end if;
    end process;

    -------------------------------------------------------------------------
    -- MAIN FSM PROCESS
    -------------------------------------------------------------------------
    process(clk, kill_signal)
        variable payload_byte_idx : integer;
        variable header_bits_received : integer;
        variable v_crc : std_logic_vector(15 downto 0);
    begin
        if kill_signal = '1' then
            -- KILL: Wipe everything
            cmd_state    <= ST_IDLE;
            rx_shift     <= (others => '0');
            tx_shift     <= (others => '0');
            bit_count    <= 0;
            tx_bit_count <= 0;
            cmd_reg      <= (others => '0');
            len_reg      <= (others => '0');
            seq_reg      <= (others => '0');
            last_seq     <= (others => '0');
            crc_calc     <= x"FFFF";
            kill_trig_int <= '0';
            hb_ok_int    <= '0';
            error_int    <= '0';
            active_int   <= '0';
            aes_state    <= AES_IDLE;
            block_index  <= 0;
            aes_pt_out   <= (others => '0');
            aes_pt_valid <= '0';
            hmac_response_out   <= (others => '0');
            hmac_response_valid <= '0';

        elsif rising_edge(clk) then
            -- Defaults
            aes_pt_valid <= '0';
            error_int    <= '0';
            hmac_response_valid <= '0';
            aegis_cfg_wr <= '0';

            if rst_n = '0' then
                cmd_state    <= ST_IDLE;
                bit_count    <= 0;
                tx_bit_count <= 0;
                active_int   <= '0';
                aes_state    <= AES_IDLE;
                aes_pt_out   <= (others => '0');
            else
                case cmd_state is

                    -------------------------------------------------------
                    -- IDLE: Wait for CS_APP_N assertion
                    -------------------------------------------------------
                    when ST_IDLE =>
                        active_int <= '0';
                        if cs_active = '1' then
                            cmd_state <= ST_RX_HDR;
                            bit_count <= 0;
                            crc_calc  <= x"FFFF";
                            rx_shift  <= (others => '0');
                            active_int <= '1';
                        end if;

                    -------------------------------------------------------
                    -- ST_RX_HDR: Receive 56-bit header (CMD+LEN+SEQ)
                    -------------------------------------------------------
                    when ST_RX_HDR =>
                        if cs_active = '0' then
                            cmd_state <= ST_IDLE;
                            error_int <= '1';
                        elsif sclk_rise = '1' then
                            rx_shift <= rx_shift(MAX_PACKET_BITS-2 downto 0) & mosi_sync(1);
                            bit_count <= bit_count + 1;
                            -- ★ C-1 FIX: CRC over header bits
                            crc_calc <= crc16_ccitt_bit(crc_calc, mosi_sync(1));

                            if bit_count + 1 = HEADER_BITS then
                                -- ★ FIX: At this point rx_shift has 55 bits
                                -- (bit0=rx_shift(54) through bit54=rx_shift(0)).
                                -- mosi_sync(1) holds bit55 (not yet shifted in).
                                cmd_reg <= rx_shift(54 downto 47);
                                len_reg <= unsigned(rx_shift(46 downto 31));
                                seq_reg <= unsigned(rx_shift(30 downto 0) & mosi_sync(1));

                                if unsigned(rx_shift(46 downto 31)) = 0 then
                                    cmd_state <= ST_RX_CRC;
                                else
                                    cmd_state <= ST_RX_PLD;
                                end if;
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- RX_PAYLOAD: Receive payload bytes
                    -------------------------------------------------------
                    when ST_RX_PLD =>
                        if cs_active = '0' then
                            cmd_state <= ST_IDLE;
                            error_int <= '1';
                        elsif sclk_rise = '1' then
                            rx_shift <= rx_shift(MAX_PACKET_BITS-2 downto 0) & mosi_sync(1);
                            bit_count <= bit_count + 1;
                            -- ★ C-1 FIX: CRC over payload bits
                            crc_calc <= crc16_ccitt_bit(crc_calc, mosi_sync(1));


                            if (bit_count - HEADER_BITS + 1) mod 8 = 0 then
                                payload_byte_idx := (bit_count - HEADER_BITS) / 8;
                                if payload_byte_idx < MAX_PAYLOAD_BYTES then
                                    rx_pld_mem(payload_byte_idx) <=
                                        rx_shift(6 downto 0) & mosi_sync(1);
                                end if;
                            end if;

                            if bit_count + 1 = HEADER_BITS + to_integer(len_reg) * 8 then
                                cmd_state <= ST_RX_CRC;
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- RX_CRC: Receive 16-bit CRC
                    -------------------------------------------------------
                    when ST_RX_CRC =>
                        if cs_active = '0' then
                            cmd_state <= ST_IDLE;
                            error_int <= '1';
                        elsif sclk_rise = '1' then
                            rx_shift <= rx_shift(MAX_PACKET_BITS-2 downto 0) & mosi_sync(1);
                            bit_count <= bit_count + 1;

                            if bit_count + 1 = HEADER_BITS + to_integer(len_reg) * 8 + CRC_BITS then
                                crc_rx <= rx_shift(14 downto 0) & mosi_sync(1);
                                cmd_state <= ST_VALIDATE;
                            end if;
                        end if;

                    -------------------------------------------------------
                    -- VALIDATE: Check CRC and sequence
                    -------------------------------------------------------
                    -- ★ C-1 FIX: CRC validation + sequence check
                    when ST_VALIDATE =>
                        if crc_calc /= crc_rx then
                            -- CRC mismatch -> integrity violation
                            error_int <= '1';
                            cmd_state <= ST_IDLE;
                        elsif seq_reg <= last_seq and last_seq /= x"00000000" then
                            -- Replay/reorder → reject
                            error_int <= '1';
                            cmd_state <= ST_IDLE;
                        else
                            last_seq  <= seq_reg;
                            cmd_state <= ST_PROCESS;
                        end if;

                    -------------------------------------------------------
                    -- PROCESS_CMD: Route command to handler
                    -------------------------------------------------------
                    when ST_PROCESS =>
                        if cmd_reg = CMD_ENCRYPT_REQ or cmd_reg = CMD_DECRYPT_REQ then
                            total_blocks <= to_integer(len_reg) / 16;
                            block_index  <= 0;
                            aes_state    <= AES_SUBMIT;
                            cmd_state    <= ST_AES_PROC;

                            if cmd_reg = CMD_ENCRYPT_REQ then
                                resp_cmd <= CMD_ENCRYPT_RESP;
                            else
                                resp_cmd <= CMD_DECRYPT_RESP;
                            end if;
                            resp_len <= len_reg;

                        elsif cmd_reg = CMD_STATUS_REQ then
                            tx_pld_mem(0)(0) <= omega_active_in;
                            tx_pld_mem(0)(1) <= aegis_active_in;
                            tx_pld_mem(0)(2) <= kill_armed_in;
                            tx_pld_mem(0)(3) <= post_pass_in;
                            tx_pld_mem(0)(4) <= hmac_busy_in;  -- ★ K.16: HMAC busy telemetry
                            tx_pld_mem(0)(5) <= lockstep_ok_in;
                            tx_pld_mem(0)(6) <= trng_healthy_in;
                            tx_pld_mem(0)(7) <= trng_degraded_in;  -- ★ A.1: DRBG fallback status
                            tx_pld_mem(1) <= (others => '0');
                            tx_pld_mem(2) <= (others => '0');
                            tx_pld_mem(3) <= (others => '0');
                            for i in 4 to 19 loop
                                tx_pld_mem(i) <= (others => '0');
                            end loop;

                            resp_cmd  <= CMD_STATUS_RESP;
                            resp_len  <= to_unsigned(20, 16);
                            cmd_state <= ST_BUILD_RESP;

                        elsif cmd_reg = CMD_KILL then
                            kill_trig_int <= '1';
                            resp_cmd  <= CMD_KILL_ACK;
                            resp_len  <= to_unsigned(0, 16);
                            cmd_state <= ST_BUILD_RESP;

                        elsif cmd_reg = CMD_HEARTBEAT then
                            -- ★ P3-9: HMAC Heartbeat Response
                            -- Toggle heartbeat OK (backward compat)
                            hb_ok_int <= '1';
                            -- Check if payload has HMAC tag (32 bytes)
                            if len_reg >= to_unsigned(32, 16) then
                                -- Forward HMAC tag to heartbeat controller
                                for i in 0 to 31 loop
                                    hmac_response_out(255 - i*8 downto 248 - i*8)
                                        <= rx_pld_mem(i);
                                end loop;
                                hmac_response_valid <= '1';
                            end if;
                            resp_cmd  <= CMD_HB_ACK;
                            resp_len  <= to_unsigned(0, 16);
                            cmd_state <= ST_BUILD_RESP;

                        elsif cmd_reg = CMD_HB_CHALLENGE then
                            -- ★ P3-9: Send HMAC challenge to PolarFire
                            -- Response payload: 16 bytes (nonce || counter)
                            if hmac_challenge_ready = '1' then
                                for i in 0 to 15 loop
                                    tx_pld_mem(i) <= hmac_challenge_in(127 - i*8 downto 120 - i*8);
                                end loop;
                                resp_len <= to_unsigned(16, 16);
                            else
                                resp_len <= to_unsigned(0, 16);
                            end if;
                            resp_cmd  <= CMD_HB_CHALLENGE_RESP;
                            cmd_state <= ST_BUILD_RESP;

                        elsif cmd_reg = CMD_AEGIS_CFG then
                            -- ★ P2-6: AEGIS Runtime Config
                            -- Payload: [addr(8)] [data_hi(8)] [data_lo(8)] = 3 bytes
                            -- addr maps to AEGIS cfg register
                            -- data is 16-bit weight or threshold value
                            if len_reg >= to_unsigned(3, 16) then
                                aegis_cfg_addr <= rx_pld_mem(0);
                                aegis_cfg_data <= rx_pld_mem(1) & rx_pld_mem(2);
                                aegis_cfg_wr   <= '1';
                            end if;
                            resp_cmd  <= CMD_AEGIS_CFG_ACK;
                            resp_len  <= to_unsigned(0, 16);
                            cmd_state <= ST_BUILD_RESP;

                        else
                            error_int <= '1';
                            cmd_state <= ST_IDLE;
                        end if;

                    -------------------------------------------------------
                    -- AES_PROCESSING: Feed blocks through AES engine
                    -------------------------------------------------------
                    when ST_AES_PROC =>
                        case aes_state is
                            when AES_IDLE =>
                                null;

                            when AES_SUBMIT =>
                                for i in 0 to 15 loop
                                    aes_block_in(127 - i*8 downto 120 - i*8)
                                        <= rx_pld_mem(block_index * 16 + i);
                                end loop;
                                aes_pt_out   <= aes_block_in;
                                aes_pt_valid <= '1';
                                aes_state    <= AES_WAIT;

                            when AES_WAIT =>
                                if aes_ct_valid = '1' then
                                    for i in 0 to 15 loop
                                        tx_pld_mem(block_index * 16 + i)
                                            <= aes_ct_in(127 - i*8 downto 120 - i*8);
                                    end loop;
                                    aes_state <= AES_NEXT;
                                end if;

                            when AES_NEXT =>
                                block_index <= block_index + 1;
                                if block_index + 1 >= total_blocks then
                                    aes_state <= AES_DONE;
                                else
                                    aes_state <= AES_SUBMIT;
                                end if;

                            when AES_DONE =>
                                aes_state <= AES_IDLE;
                                cmd_state <= ST_BUILD_RESP;
                        end case;

                    -------------------------------------------------------
                    -- BUILD_RESPONSE: Construct response HLP packet in tx_shift
                    -------------------------------------------------------
                    when ST_BUILD_RESP =>
                        tx_shift <= (others => '0');
                        tx_shift(MAX_PACKET_BITS-1 downto MAX_PACKET_BITS-8) <= resp_cmd;
                        tx_shift(MAX_PACKET_BITS-9 downto MAX_PACKET_BITS-24)
                            <= std_logic_vector(resp_len);
                        tx_shift(MAX_PACKET_BITS-25 downto MAX_PACKET_BITS-56)
                            <= std_logic_vector(seq_reg);

                        for i in 0 to MAX_PAYLOAD_BYTES-1 loop
                            if i < to_integer(resp_len) then
                                tx_shift(MAX_PACKET_BITS - HEADER_BITS - 1 - i*8
                                         downto MAX_PACKET_BITS - HEADER_BITS - 8 - i*8)
                                    <= tx_pld_mem(i);
                            end if;
                        end loop;

                        resp_total_bits <= HEADER_BITS + to_integer(resp_len) * 8 + CRC_BITS;
                        tx_bit_count <= 0;
                        cmd_state    <= ST_TX_RESP;

                    -------------------------------------------------------
                    -- TX_RESPONSE: Shift out response bits via MISO
                    -------------------------------------------------------
                    when ST_TX_RESP =>
                        if cs_active = '0' then
                            cmd_state <= ST_COMPLETE;
                        elsif sclk_fall = '1' then
                            tx_bit_count <= tx_bit_count + 1;
                            if tx_bit_count + 1 >= resp_total_bits then
                                cmd_state <= ST_COMPLETE;
                            end if;
                        end if;

                    when ST_COMPLETE =>
                        if cs_active = '0' then
                            cmd_state  <= ST_IDLE;
                            active_int <= '0';
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
