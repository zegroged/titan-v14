--------------------------------------------------------------------------------
-- AEGIS Phase 2.4: ESN Readout Layer (Programmable)
--------------------------------------------------------------------------------
-- Computes dot product: prediction = SUM(W_out[i] * state[i]) for i=0..N-1
--
-- Features:
--   - Double-buffered weight storage (atomic swap, glitch-free updates)
--   - Time-multiplexed dot product (single combinational multiply)
--   - Runtime weight update via write port (SPI/UART compatible)
--   - Distributed RAM weights (register-based, fast read)
--
-- Double-Buffer Strategy:
--   Bank 0 and Bank 1 alternate as active/shadow.
--   Writes go to shadow bank. On weights_swap pulse, roles switch.
--   Prediction always reads from active bank -- never interrupted.
--
-- Cycle count: N + 2 (1 init + N MACs + 1 output)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.esn_weight_pkg.all;

entity esn_readout is
    generic (
        ADDR_BITS : integer := 3   -- log2(ESN_N), default log2(8)=3
    );
    port (
        clk              : in  std_logic;
        rst_n            : in  std_logic;

        -- State input from reservoir
        state_vector     : in  std_logic_vector(ESN_N * 16 - 1 downto 0);
        state_valid      : in  std_logic;  -- Trigger prediction

        -- Weight programming port
        weights_wr_data  : in  std_logic_vector(15 downto 0);
        weights_wr_addr  : in  std_logic_vector(ADDR_BITS - 1 downto 0);
        weights_wr_en    : in  std_logic;
        weights_swap     : in  std_logic;  -- Swap active/shadow banks

        -- Prediction output
        prediction       : out std_logic_vector(15 downto 0);
        prediction_valid : out std_logic
    );
    attribute use_dsp : string;
    attribute use_dsp of esn_readout : entity is "no";
end entity esn_readout;

architecture rtl of esn_readout is

    -- Weight banks (double-buffered, distributed RAM = registers)
    type weight_bank_t is array (0 to ESN_N - 1) of signed(15 downto 0);
    signal bank_0      : weight_bank_t := (others => (others => '0'));
    signal bank_1      : weight_bank_t := (others => (others => '0'));
    signal active_bank : std_logic := '0';  -- '0' = bank_0 active

    -- Attribute to prevent BRAM inference (use distributed/registers)
    attribute ram_style : string;
    attribute ram_style of bank_0 : signal is "distributed";
    attribute ram_style of bank_1 : signal is "distributed";

    -- FSM
    type fsm_t is (S_IDLE, S_MAC, S_OUTPUT);
    signal fsm : fsm_t;

    -- Datapath
    signal mac_idx    : integer range 0 to ESN_N - 1;
    signal acc        : signed(31 downto 0);
    signal pred_reg   : std_logic_vector(15 downto 0);
    signal valid_reg  : std_logic;

    -- Extract one neuron state from the wide bus
    function get_state(sv : std_logic_vector; idx : integer)
        return signed is
    begin
        return signed(sv((idx + 1) * 16 - 1 downto idx * 16));
    end function;

begin

    prediction       <= pred_reg;
    prediction_valid <= valid_reg;

    process(clk, rst_n)
        variable wr_addr_int : integer;
        variable weight_val  : signed(15 downto 0);
        variable state_val   : signed(15 downto 0);
        variable product     : signed(31 downto 0);
        variable shifted     : signed(31 downto 0);
    begin
        if rst_n = '0' then
            bank_0      <= (others => (others => '0'));
            bank_1      <= (others => (others => '0'));
            active_bank <= '0';
            fsm         <= S_IDLE;
            acc         <= (others => '0');
            mac_idx     <= 0;
            pred_reg    <= (others => '0');
            valid_reg   <= '0';

        elsif rising_edge(clk) then
            valid_reg <= '0';

            -- ==========================================
            -- Weight Write (shadow bank, always active)
            -- ==========================================
            if weights_wr_en = '1' then
                wr_addr_int := to_integer(unsigned(weights_wr_addr));
                if active_bank = '0' then
                    -- Bank 0 is active -> write to bank 1 (shadow)
                    bank_1(wr_addr_int) <= signed(weights_wr_data);
                else
                    -- Bank 1 is active -> write to bank 0 (shadow)
                    bank_0(wr_addr_int) <= signed(weights_wr_data);
                end if;
            end if;

            -- ==========================================
            -- Bank Swap (atomic, only when IDLE)
            -- ==========================================
            if weights_swap = '1' and fsm = S_IDLE then
                active_bank <= not active_bank;
            end if;

            -- ==========================================
            -- Prediction FSM
            -- ==========================================
            case fsm is

                when S_IDLE =>
                    if state_valid = '1' then
                        acc     <= (others => '0');
                        mac_idx <= 0;
                        fsm     <= S_MAC;
                    end if;

                when S_MAC =>
                    -- Read weight from active bank
                    if active_bank = '0' then
                        weight_val := bank_0(mac_idx);
                    else
                        weight_val := bank_1(mac_idx);
                    end if;

                    -- Read state
                    state_val := get_state(state_vector, mac_idx);

                    -- MAC: acc += weight * state (Q16.16)
                    product := weight_val * state_val;
                    acc     <= acc + product;

                    if mac_idx = ESN_N - 1 then
                        fsm <= S_OUTPUT;
                    else
                        mac_idx <= mac_idx + 1;
                    end if;

                when S_OUTPUT =>
                    -- Shift Q16.16 to Q8.8, saturate
                    shifted := shift_right(acc, 8);
                    if shifted > to_signed(32767, 32) then
                        pred_reg <= x"7FFF";
                    elsif shifted < to_signed(-32768, 32) then
                        pred_reg <= x"8000";
                    else
                        pred_reg <= std_logic_vector(shifted(15 downto 0));
                    end if;

                    valid_reg <= '1';
                    fsm       <= S_IDLE;

            end case;
        end if;
    end process;

end architecture rtl;
