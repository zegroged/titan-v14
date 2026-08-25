--------------------------------------------------------------------------------
-- AEGIS Phase 2.5: Anomaly Detector (Threshold Comparator)
--------------------------------------------------------------------------------
-- Compares ESN prediction vs actual sensor data.
-- If |prediction - actual| > threshold for WINDOW_SIZE consecutive
-- samples, raises a LATCHING anomaly flag.
--
-- Features:
--   - Signed absolute error: |prediction - actual|
--   - Programmable threshold (runtime-writable register)
--   - Debounce window (consecutive exceedance counter)
--   - Latching flag: once set, holds until software clear
--   - Connects to TITAN kill protocol via anomaly_flag output
--
-- Latency: 1 clock cycle (registered comparator)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity anomaly_detector is
    generic (
        WINDOW_SIZE : integer := 4   -- Consecutive over-threshold samples needed
    );
    port (
        clk              : in  std_logic;
        rst_n            : in  std_logic;

        -- Data inputs (trigger on valid pulse)
        prediction       : in  std_logic_vector(15 downto 0);  -- Q8.8
        actual_value     : in  std_logic_vector(15 downto 0);  -- Q8.8
        data_valid       : in  std_logic;

        -- Programmable threshold
        threshold        : in  std_logic_vector(15 downto 0);  -- Q8.8
        threshold_wr_en  : in  std_logic;

        -- Software clear for latched flag
        clear_flag       : in  std_logic;

        -- Outputs
        anomaly_flag     : out std_logic;                       -- Latching!
        error_magnitude  : out std_logic_vector(15 downto 0);   -- |pred-actual|
        consecutive_count: out std_logic_vector(7 downto 0)     -- Counter value
    );
end entity anomaly_detector;

architecture rtl of anomaly_detector is

    -- Threshold register
    signal thresh_reg  : unsigned(15 downto 0) := x"0080";  -- Default 0.5

    -- Error and comparison
    signal error_reg   : unsigned(15 downto 0);
    signal over_thresh : std_logic;

    -- Debounce counter
    signal consec_cnt  : integer range 0 to 255;

    -- Latching flag
    signal flag_reg    : std_logic;

begin

    anomaly_flag      <= flag_reg;
    error_magnitude   <= std_logic_vector(error_reg);
    consecutive_count <= std_logic_vector(to_unsigned(consec_cnt, 8));

    process(clk, rst_n)
        variable diff    : signed(16 downto 0);  -- 17-bit for overflow-safe subtract
        variable abs_err : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            thresh_reg  <= x"0080";  -- 0.5 default
            error_reg   <= (others => '0');
            over_thresh <= '0';
            consec_cnt  <= 0;
            flag_reg    <= '0';

        elsif rising_edge(clk) then

            -- ==========================================
            -- Threshold register update (anytime)
            -- ==========================================
            if threshold_wr_en = '1' then
                thresh_reg <= unsigned(threshold);
            end if;

            -- ==========================================
            -- Software clear of latched flag
            -- ==========================================
            if clear_flag = '1' then
                flag_reg   <= '0';
                consec_cnt <= 0;
            end if;

            -- ==========================================
            -- Main comparison (on valid data pulse)
            -- ==========================================
            if data_valid = '1' then
                -- Signed subtraction: prediction - actual
                diff := resize(signed(prediction), 17) -
                        resize(signed(actual_value), 17);

                -- Absolute value
                if diff < 0 then
                    abs_err := unsigned(-diff(15 downto 0));
                else
                    abs_err := unsigned(diff(15 downto 0));
                end if;

                -- Handle edge case: most negative signed value
                if diff = to_signed(-32768, 17) then
                    abs_err := x"7FFF";
                end if;

                error_reg <= abs_err;

                -- Threshold comparison
                if abs_err > thresh_reg then
                    -- Over threshold: increment consecutive counter
                    over_thresh <= '1';
                    if consec_cnt < 255 then
                        consec_cnt <= consec_cnt + 1;
                    end if;

                    -- Check if window filled
                    if consec_cnt + 1 >= WINDOW_SIZE then
                        flag_reg <= '1';  -- LATCH: stays high until clear
                    end if;
                else
                    -- Under threshold: reset consecutive counter
                    over_thresh <= '0';
                    consec_cnt  <= 0;
                    -- Note: flag_reg is NOT cleared here (latching behavior)
                end if;
            end if;

        end if;
    end process;

end architecture rtl;
