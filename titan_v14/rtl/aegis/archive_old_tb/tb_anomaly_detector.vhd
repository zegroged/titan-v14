--------------------------------------------------------------------------------
-- AEGIS Phase 2.5: Testbench for Anomaly Detector
--------------------------------------------------------------------------------
-- Test scenarios:
--   1. Normal data (under threshold) -> no false positives
--   2. Single spike (1 over threshold) -> flag stays low (debounce)
--   3. Sustained anomaly (WINDOW_SIZE consecutive) -> flag goes high
--   4. Flag latches after clear_flag deassert
--   5. Runtime threshold update
--   6. Software clear resets flag and counter
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_anomaly_detector is
end entity tb_anomaly_detector;

architecture sim of tb_anomaly_detector is

    constant CLK_P   : time := 20 ns;
    constant WIN_SZ  : integer := 4;

    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';
    signal prediction   : std_logic_vector(15 downto 0) := (others => '0');
    signal actual_value : std_logic_vector(15 downto 0) := (others => '0');
    signal data_valid   : std_logic := '0';
    signal threshold    : std_logic_vector(15 downto 0) := (others => '0');
    signal thresh_wr    : std_logic := '0';
    signal clear_flag   : std_logic := '0';
    signal anomaly_flag : std_logic;
    signal error_mag    : std_logic_vector(15 downto 0);
    signal consec_cnt   : std_logic_vector(7 downto 0);

    signal running : boolean := true;

    -- Helper: generate one data sample
    procedure push_sample(
        signal pred   : out std_logic_vector(15 downto 0);
        signal actual : out std_logic_vector(15 downto 0);
        signal valid  : out std_logic;
        constant p    : in  integer;
        constant a    : in  integer
    ) is
    begin
        pred   <= std_logic_vector(to_signed(p, 16));
        actual <= std_logic_vector(to_signed(a, 16));
        valid  <= '1';
        wait for CLK_P;
        valid  <= '0';
        wait for CLK_P;
    end procedure;

begin

    clk_gen : process
    begin
        while running loop
            clk <= '0'; wait for CLK_P/2;
            clk <= '1'; wait for CLK_P/2;
        end loop;
        wait;
    end process;

    dut : entity work.anomaly_detector
        generic map (WINDOW_SIZE => WIN_SZ)
        port map (
            clk               => clk,
            rst_n             => rst_n,
            prediction        => prediction,
            actual_value      => actual_value,
            data_valid        => data_valid,
            threshold         => threshold,
            threshold_wr_en   => thresh_wr,
            clear_flag        => clear_flag,
            anomaly_flag      => anomaly_flag,
            error_magnitude   => error_mag,
            consecutive_count => consec_cnt
        );

    stim : process
        variable pc : integer := 0;
        variable fc : integer := 0;
    begin
        rst_n <= '0';
        wait for CLK_P * 5;
        rst_n <= '1';
        wait for CLK_P * 2;

        -- Set threshold = 0.5 (0x0080 = 128 in Q8.8)
        threshold <= x"0080";
        thresh_wr <= '1';
        wait for CLK_P;
        thresh_wr <= '0';
        wait for CLK_P;

        -- ===== TEST 1: Normal data (small error) =====
        report "TEST 1: Normal data (no false positives)" severity note;
        -- pred=1.0 (256), actual=0.8 (205) -> error=0.2 < 0.5
        for i in 0 to 5 loop
            push_sample(prediction, actual_value, data_valid, 256, 205);
        end loop;

        if anomaly_flag = '0' then
            pc := pc + 1;
            report "  PASS: flag stays low during normal data" severity note;
        else
            fc := fc + 1;
            report "  FAIL: false positive!" severity error;
        end if;

        -- ===== TEST 2: Single spike (should NOT trigger) =====
        report "TEST 2: Single spike (debounce)" severity note;
        -- One sample over threshold: pred=2.0, actual=0.0 -> error=2.0 > 0.5
        push_sample(prediction, actual_value, data_valid, 512, 0);
        -- Then back to normal
        push_sample(prediction, actual_value, data_valid, 256, 205);
        push_sample(prediction, actual_value, data_valid, 256, 205);

        if anomaly_flag = '0' then
            pc := pc + 1;
            report "  PASS: single spike debounced" severity note;
        else
            fc := fc + 1;
            report "  FAIL: flag triggered on single spike!" severity error;
        end if;

        -- Check counter reset after normal samples
        if unsigned(consec_cnt) = 0 then
            pc := pc + 1;
            report "  PASS: counter reset after normal data" severity note;
        else
            fc := fc + 1;
            report "  FAIL: counter not reset" severity error;
        end if;

        -- ===== TEST 3: Sustained anomaly (WINDOW_SIZE consecutive) =====
        report "TEST 3: Sustained anomaly (flag should latch)" severity note;
        -- 4 consecutive over-threshold samples
        for i in 0 to WIN_SZ - 1 loop
            push_sample(prediction, actual_value, data_valid, 512, 0);
        end loop;

        if anomaly_flag = '1' then
            pc := pc + 1;
            report "  PASS: flag raised after window_size exceedances" severity note;
        else
            fc := fc + 1;
            report "  FAIL: flag not raised!" severity error;
        end if;

        -- ===== TEST 4: Latch holds (flag stays even with normal data) =====
        report "TEST 4: Latch persistence" severity note;
        push_sample(prediction, actual_value, data_valid, 256, 256);
        push_sample(prediction, actual_value, data_valid, 256, 256);

        if anomaly_flag = '1' then
            pc := pc + 1;
            report "  PASS: flag latched (survives normal data)" severity note;
        else
            fc := fc + 1;
            report "  FAIL: flag cleared without software clear!" severity error;
        end if;

        -- ===== TEST 5: Software clear =====
        report "TEST 5: Software clear" severity note;
        clear_flag <= '1';
        wait for CLK_P;
        clear_flag <= '0';
        wait for CLK_P;

        if anomaly_flag = '0' then
            pc := pc + 1;
            report "  PASS: flag cleared by software" severity note;
        else
            fc := fc + 1;
            report "  FAIL: flag not cleared!" severity error;
        end if;

        -- ===== TEST 6: Runtime threshold change =====
        report "TEST 6: Runtime threshold update" severity note;
        -- Raise threshold to 3.0 (768). Now error=2.0 < 3.0 -> no anomaly
        threshold <= std_logic_vector(to_unsigned(768, 16));
        thresh_wr <= '1';
        wait for CLK_P;
        thresh_wr <= '0';
        wait for CLK_P;

        for i in 0 to WIN_SZ - 1 loop
            push_sample(prediction, actual_value, data_valid, 512, 0);
        end loop;

        if anomaly_flag = '0' then
            pc := pc + 1;
            report "  PASS: higher threshold prevents trigger" severity note;
        else
            fc := fc + 1;
            report "  FAIL: triggered despite raised threshold!" severity error;
        end if;

        -- ===== TEST 7: Error magnitude check =====
        report "TEST 7: Error magnitude value" severity note;
        -- pred=1.5(384), actual=0.5(128) -> |error|=1.0(256)=0x0100
        push_sample(prediction, actual_value, data_valid, 384, 128);

        if unsigned(error_mag) = 256 then
            pc := pc + 1;
            report "  PASS: error magnitude = 0x0100 (1.0)" severity note;
        else
            fc := fc + 1;
            report "  FAIL: error_mag=0x" & integer'image(to_integer(unsigned(error_mag)))
                severity error;
        end if;

        -- Summary
        report "========================================" severity note;
        report " ANOMALY DETECTOR: 8 checks" severity note;
        report "   PASS: " & integer'image(pc) severity note;
        report "   FAIL: " & integer'image(fc) severity note;
        report "========================================" severity note;

        if fc = 0 then
            report "ALL TESTS PASSED!" severity note;
        else
            report "SOME TESTS FAILED!" severity error;
        end if;

        running <= false;
        wait;
    end process;

end architecture sim;
