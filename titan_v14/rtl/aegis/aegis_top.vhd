--------------------------------------------------------------------------------
-- AEGIS Phase 2.6: Top Module -- System Integration
--------------------------------------------------------------------------------
-- Integrates all AEGIS sub-modules into a single AXI4-Stream compatible
-- processing pipeline:
--
--   AXI-S Input -> [Reservoir Core] -> [Readout Layer] -> AXI-S Output
--                                          ↓
--                                   [Anomaly Detector] -> anomaly_irq
--
-- AXI4-Stream Protocol:
--   - Slave port (input):  s_axis_tdata/tvalid/tready
--   - Master port (output): m_axis_tdata/tvalid/tready
--   - Back-pressure: tready deasserted when pipeline is busy
--
-- Configuration Port:
--   - cfg_addr(7:0): 0x00-0x07=readout weights, 0x10=threshold, 0x11=clear
--   - cfg_data(15:0): write data
--   - cfg_wr_en: write strobe
--
-- Pipeline latency: ~50 cycles (reservoir: ~36 + readout: ~10 + anomaly: 1)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.esn_weight_pkg.all;

entity aegis_top is
    generic (
        WINDOW_SIZE : integer := 4;
        ADDR_BITS   : integer := 3   -- log2(ESN_N)
    );
    port (
        -- Clock and reset
        sys_clk       : in  std_logic;
        rst_n         : in  std_logic;   -- From TITAN supervisor

        -- AXI4-Stream Slave (Sensor Input)
        s_axis_tdata  : in  std_logic_vector(15 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;

        -- AXI4-Stream Master (Prediction Output)
        m_axis_tdata  : out std_logic_vector(15 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;

        -- Configuration port (register-mapped)
        cfg_addr      : in  std_logic_vector(7 downto 0);
        cfg_data      : in  std_logic_vector(15 downto 0);
        cfg_wr_en     : in  std_logic;

        -- Anomaly IRQ (to TITAN kill protocol)
        anomaly_irq   : out std_logic
    );
    attribute use_dsp : string;
    attribute use_dsp of aegis_top : entity is "no";
end entity aegis_top;

architecture rtl of aegis_top is

    -- ===== Internal signals =====

    -- Pipeline state
    type pipe_state_t is (P_IDLE, P_RESERVOIR, P_READOUT, P_OUTPUT, P_ANOMALY);
    signal pipe_state : pipe_state_t;

    -- Input latching
    signal input_latched    : std_logic_vector(15 downto 0);
    signal prev_prediction  : std_logic_vector(15 downto 0);
    signal first_sample     : std_logic;

    -- Reservoir core ↔ Readout
    signal res_state_bus    : std_logic_vector(ESN_N * 16 - 1 downto 0);
    signal res_state_valid  : std_logic;
    signal res_valid_in     : std_logic;

    -- Readout ↔ Anomaly / Output
    signal readout_pred     : std_logic_vector(15 downto 0);
    signal readout_valid    : std_logic;
    signal readout_sv       : std_logic;

    -- Anomaly detector
    signal anomaly_pred_in  : std_logic_vector(15 downto 0);
    signal anomaly_act_in   : std_logic_vector(15 downto 0);
    signal anomaly_dv       : std_logic;
    signal anomaly_flag     : std_logic;
    signal anomaly_err      : std_logic_vector(15 downto 0);
    signal anomaly_cnt      : std_logic_vector(7 downto 0);

    -- Config decoding
    signal weight_wr_en     : std_logic;
    signal weight_wr_data   : std_logic_vector(15 downto 0);
    signal weight_wr_addr   : std_logic_vector(ADDR_BITS - 1 downto 0);
    signal weight_swap      : std_logic;
    signal thresh_wr_en     : std_logic;
    signal clear_flag       : std_logic;
    signal thresh_data      : std_logic_vector(15 downto 0);

    -- AXI output staging
    signal out_data_reg     : std_logic_vector(15 downto 0);
    signal out_valid_reg    : std_logic;
    signal s_ready_reg      : std_logic;

begin

    -- ===== AXI4-Stream Ports =====
    s_axis_tready <= s_ready_reg;
    m_axis_tdata  <= out_data_reg;
    m_axis_tvalid <= out_valid_reg;
    anomaly_irq   <= anomaly_flag;

    -- ===== Sub-Module Instantiation =====

    -- (1) Reservoir Core
    u_reservoir : entity work.esn_reservoir_core
        port map (
            clk            => sys_clk,
            rst_n          => rst_n,
            sensor_data_in => input_latched,
            valid_in       => res_valid_in,
            state_out      => res_state_bus,
            state_valid    => res_state_valid
        );

    -- (2) Readout Layer
    u_readout : entity work.esn_readout
        generic map (ADDR_BITS => ADDR_BITS)
        port map (
            clk              => sys_clk,
            rst_n            => rst_n,
            state_vector     => res_state_bus,
            state_valid      => readout_sv,
            weights_wr_data  => weight_wr_data,
            weights_wr_addr  => weight_wr_addr,
            weights_wr_en    => weight_wr_en,
            weights_swap     => weight_swap,
            prediction       => readout_pred,
            prediction_valid => readout_valid
        );

    -- (3) Anomaly Detector
    u_anomaly : entity work.anomaly_detector
        generic map (WINDOW_SIZE => WINDOW_SIZE)
        port map (
            clk               => sys_clk,
            rst_n             => rst_n,
            prediction        => anomaly_pred_in,
            actual_value      => anomaly_act_in,
            data_valid        => anomaly_dv,
            threshold         => thresh_data,
            threshold_wr_en   => thresh_wr_en,
            clear_flag        => clear_flag,
            anomaly_flag      => anomaly_flag,
            error_magnitude   => anomaly_err,
            consecutive_count => anomaly_cnt
        );

    -- ===== Configuration Decoder =====
    -- 0x00..0x07: readout weight write (addr = cfg_addr[2:0])
    -- 0x08:       readout weight bank swap
    -- 0x10:       anomaly threshold write
    -- 0x11:       anomaly clear flag
    process(sys_clk, rst_n)
    begin
        if rst_n = '0' then
            weight_wr_en  <= '0';
            weight_wr_data <= (others => '0');
            weight_wr_addr <= (others => '0');
            weight_swap   <= '0';
            thresh_wr_en  <= '0';
            thresh_data   <= x"0080";  -- Default threshold 0.5
            clear_flag    <= '0';
        elsif rising_edge(sys_clk) then
            -- Defaults (single-cycle pulses)
            weight_wr_en <= '0';
            weight_swap  <= '0';
            thresh_wr_en <= '0';
            clear_flag   <= '0';

            if cfg_wr_en = '1' then
                case cfg_addr is
                    when x"00" | x"01" | x"02" | x"03" |
                         x"04" | x"05" | x"06" | x"07" =>
                        -- Readout weight write
                        weight_wr_en   <= '1';
                        weight_wr_data <= cfg_data;
                        weight_wr_addr <= cfg_addr(ADDR_BITS - 1 downto 0);

                    when x"08" =>
                        -- Weight bank swap
                        weight_swap <= '1';

                    when x"10" =>
                        -- Threshold update
                        thresh_wr_en <= '1';
                        thresh_data  <= cfg_data;

                    when x"11" =>
                        -- Clear anomaly flag
                        clear_flag <= '1';

                    when others =>
                        null;
                end case;
            end if;
        end if;
    end process;

    -- ===== Pipeline Controller =====
    process(sys_clk, rst_n)
    begin
        if rst_n = '0' then
            pipe_state     <= P_IDLE;
            input_latched  <= (others => '0');
            prev_prediction <= (others => '0');
            first_sample   <= '1';
            res_valid_in   <= '0';
            readout_sv     <= '0';
            anomaly_dv     <= '0';
            anomaly_pred_in <= (others => '0');
            anomaly_act_in  <= (others => '0');
            out_data_reg   <= (others => '0');
            out_valid_reg  <= '0';
            s_ready_reg    <= '1';

        elsif rising_edge(sys_clk) then
            -- Default: clear single-cycle pulses
            res_valid_in <= '0';
            readout_sv   <= '0';
            anomaly_dv   <= '0';

            -- AXI output handshake is managed in P_ANOMALY state
            -- to prevent race conditions with the pipeline controller

            case pipe_state is

                -- ==========================================
                -- IDLE: Accept new AXI input
                -- ==========================================
                when P_IDLE =>
                    s_ready_reg <= '1';  -- Ready for input

                    if s_axis_tvalid = '1' and s_ready_reg = '1' then
                        input_latched <= s_axis_tdata;
                        s_ready_reg   <= '0';  -- Busy
                        res_valid_in  <= '1';   -- Trigger reservoir
                        pipe_state    <= P_RESERVOIR;
                    end if;

                -- ==========================================
                -- RESERVOIR: Wait for state computation
                -- ==========================================
                when P_RESERVOIR =>
                    if res_state_valid = '1' then
                        readout_sv <= '1';  -- Trigger readout
                        pipe_state <= P_READOUT;
                    end if;

                -- ==========================================
                -- READOUT: Wait for prediction
                -- ==========================================
                when P_READOUT =>
                    if readout_valid = '1' then
                        -- Latch prediction for AXI output
                        out_data_reg <= readout_pred;

                        -- Feed anomaly detector:
                        -- Compare PREVIOUS prediction with CURRENT actual
                        if first_sample = '0' then
                            anomaly_pred_in <= prev_prediction;
                            anomaly_act_in  <= input_latched;
                            anomaly_dv      <= '1';
                        end if;

                        -- Store this prediction for next comparison
                        prev_prediction <= readout_pred;
                        first_sample    <= '0';

                        pipe_state <= P_OUTPUT;
                    end if;

                -- ==========================================
                -- OUTPUT: Push prediction to AXI master
                -- ==========================================
                when P_OUTPUT =>
                    out_valid_reg <= '1';
                    pipe_state    <= P_ANOMALY;

                -- ==========================================
                -- ANOMALY: Wait for downstream to accept, then loop
                -- ==========================================
                when P_ANOMALY =>
                    -- Wait until downstream accepts the output
                    if m_axis_tready = '1' and out_valid_reg = '1' then
                        out_valid_reg <= '0';   -- Handshake complete
                        pipe_state    <= P_IDLE;
                    end if;

            end case;
        end if;
    end process;

end architecture rtl;
