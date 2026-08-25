--------------------------------------------------------------------------------
-- AEGIS Phase 2.3: ESN Reservoir Core (Time-Multiplexed)
--------------------------------------------------------------------------------
-- N-neuron Echo State Network with:
--   - Combinational Q8.8 multiply (use_dsp="no", single-cycle)
--   - CSR sparse weight traversal (zero-skipping)
--   - Leaky integrator with tanh activation
--   - Time-multiplexed: 1 multiplier serves all neurons sequentially
--
-- Cycle count per update: sum_i(3 + nnz_per_row[i]) + 1
-- For N=8, NNZ=11: ~36 cycles
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.tanh_lut_pkg.all;
use work.esn_weight_pkg.all;

entity esn_reservoir_core is
    port (
        clk            : in  std_logic;
        rst_n          : in  std_logic;
        sensor_data_in : in  std_logic_vector(15 downto 0);
        valid_in       : in  std_logic;
        state_out      : out std_logic_vector(ESN_N * 16 - 1 downto 0);
        state_valid    : out std_logic
    );
    attribute use_dsp : string;
    attribute use_dsp of esn_reservoir_core : entity is "no";
end entity esn_reservoir_core;

architecture rtl of esn_reservoir_core is

    constant FRAC_BITS : integer := 8;
    constant ROUND_BIAS : signed(31 downto 0) := to_signed(2**(FRAC_BITS-1), 32); -- 128

    -- State register array
    type state_array_t is array (0 to ESN_N - 1) of signed(15 downto 0);
    signal state_reg : state_array_t := (others => (others => '0'));

    -- FSM
    type fsm_t is (S_IDLE, S_MAC_IN, S_MAC_W, S_TANH, S_LEAK, S_DONE);
    signal fsm : fsm_t;

    -- Datapath registers
    signal input_reg   : signed(15 downto 0);
    signal neuron_idx  : integer range 0 to ESN_N - 1;
    signal w_ptr       : integer range 0 to ESN_NNZ;
    signal w_end       : integer range 0 to ESN_NNZ;
    signal acc         : signed(31 downto 0);
    signal tanh_out_r  : signed(15 downto 0);
    signal valid_r     : std_logic;

begin

    -- Wire state registers to output bus
    gen_out : for i in 0 to ESN_N - 1 generate
        state_out((i + 1) * 16 - 1 downto i * 16) <=
            std_logic_vector(state_reg(i));
    end generate;
    state_valid <= valid_r;

    -- Main FSM process
    process(clk, rst_n)
        variable product   : signed(31 downto 0);
        variable shifted   : signed(31 downto 0);
        variable tanh_in   : signed(15 downto 0);
        variable tanh_val  : signed(15 downto 0);
        variable addr_tmp  : signed(15 downto 0);
        variable addr_slv  : std_logic_vector(15 downto 0);
        variable addr_int  : integer;
        variable diff_v    : signed(16 downto 0);
        variable diff_sat  : signed(15 downto 0);
        variable leak_prod : signed(31 downto 0);
        variable new_st_v  : signed(16 downto 0);
    begin
        if rst_n = '0' then
            fsm        <= S_IDLE;
            state_reg  <= (others => (others => '0'));
            input_reg  <= (others => '0');
            acc        <= (others => '0');
            tanh_out_r <= (others => '0');
            neuron_idx <= 0;
            w_ptr      <= 0;
            w_end      <= 0;
            valid_r    <= '0';

        elsif rising_edge(clk) then
            valid_r <= '0';

            case fsm is

                -- ==========================================
                -- IDLE: Wait for valid input
                -- ==========================================
                when S_IDLE =>
                    if valid_in = '1' then
                        input_reg  <= signed(sensor_data_in);
                        neuron_idx <= 0;
                        fsm        <= S_MAC_IN;
                    end if;

                -- ==========================================
                -- MAC_IN: acc = W_in[i] * input
                -- ==========================================
                when S_MAC_IN =>
                    product := signed(ESN_W_IN(neuron_idx)) * input_reg;
                    acc     <= product;
                    w_ptr   <= ESN_W_ROW_PTR(neuron_idx);
                    w_end   <= ESN_W_ROW_PTR(neuron_idx + 1);
                    fsm     <= S_MAC_W;

                -- ==========================================
                -- MAC_W: acc += W[ptr] * state[col[ptr]]
                -- Skip if row has no nonzero entries
                -- ==========================================
                when S_MAC_W =>
                    if w_ptr < w_end then
                        product := signed(ESN_W_VALUES(w_ptr))
                                 * state_reg(ESN_W_COL_IDX(w_ptr));
                        acc   <= acc + product;
                        w_ptr <= w_ptr + 1;
                        -- Stay in S_MAC_W until all done
                    else
                        fsm <= S_TANH;
                    end if;

                -- ==========================================
                -- TANH: tanh_in = acc >> 8, apply LUT
                -- ==========================================
                when S_TANH =>
                    -- Shift Q16.16 accumulator to Q8.8 (truncation)
                    shifted := shift_right(acc, FRAC_BITS);
                    if shifted > to_signed(32767, 32) then
                        tanh_in := to_signed(32767, 16);
                    elsif shifted < to_signed(-32768, 32) then
                        tanh_in := to_signed(-32768, 16);
                    else
                        tanh_in := shifted(15 downto 0);
                    end if;

                    -- tanh LUT lookup (combinational from package)
                    if tanh_in <= to_signed(-1024, 16) then
                        tanh_out_r <= to_signed(-256, 16);
                    elsif tanh_in >= to_signed(1024, 16) then
                        tanh_out_r <= to_signed(256, 16);
                    else
                        addr_tmp := tanh_in + to_signed(1024, 16);
                        addr_slv := std_logic_vector(addr_tmp);
                        addr_int := to_integer(unsigned(
                            addr_slv(10 downto 3)));
                        if addr_int > 255 then
                            addr_int := 255;
                        end if;
                        tanh_out_r <= signed(TANH_ROM(addr_int));
                    end if;

                    fsm <= S_LEAK;

                -- ==========================================
                -- LEAK: new = old + leak*(tanh - old)
                -- ==========================================
                when S_LEAK =>
                    -- diff = tanh_out - state[i], saturate to 16-bit
                    diff_v := resize(tanh_out_r, 17) -
                              resize(state_reg(neuron_idx), 17);
                    if diff_v > to_signed(32767, 17) then
                        diff_sat := to_signed(32767, 16);
                    elsif diff_v < to_signed(-32768, 17) then
                        diff_sat := to_signed(-32768, 16);
                    else
                        diff_sat := diff_v(15 downto 0);
                    end if;

                    -- leak_term = LEAK_RATE * diff >> 8 (truncation)
                    leak_prod := signed(ESN_LEAK) * diff_sat;
                    shifted   := shift_right(leak_prod, FRAC_BITS);

                    -- new_state = old + leak_term, saturate
                    new_st_v := resize(state_reg(neuron_idx), 17) +
                                resize(shifted(15 downto 0), 17);
                    if new_st_v > to_signed(32767, 17) then
                        state_reg(neuron_idx) <= to_signed(32767, 16);
                    elsif new_st_v < to_signed(-32768, 17) then
                        state_reg(neuron_idx) <= to_signed(-32768, 16);
                    else
                        state_reg(neuron_idx) <= new_st_v(15 downto 0);
                    end if;

                    -- Next neuron or done
                    if neuron_idx = ESN_N - 1 then
                        fsm <= S_DONE;
                    else
                        neuron_idx <= neuron_idx + 1;
                        fsm        <= S_MAC_IN;
                    end if;

                -- ==========================================
                -- DONE: Assert valid for 1 cycle
                -- ==========================================
                when S_DONE =>
                    valid_r <= '1';
                    fsm     <= S_IDLE;

            end case;
        end if;
    end process;

end architecture rtl;
