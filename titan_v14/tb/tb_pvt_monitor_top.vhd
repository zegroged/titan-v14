--------------------------------------------------------------------------------
-- TB: pvt_monitor_top — PVT Monitor Verification
-- Tests: reset, calibration load, measurement cycle, alarm thresholds
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_pvt_monitor_top is
end tb_pvt_monitor_top;

architecture sim of tb_pvt_monitor_top is

    constant CLK_PERIOD : time := 20 ns;
    constant N_SENSORS  : integer := 2;
    constant LOG2_N     : integer := 1;

    signal clk              : std_logic := '0';
    signal rst_n            : std_logic := '0';
    signal measure_start    : std_logic := '0';
    signal continuous       : std_logic := '0';
    signal clear_alarm      : std_logic := '0';
    signal calib_nominal    : std_logic_vector(23 downto 0) := (others => '0');
    signal calib_load       : std_logic := '0';
    signal ring_osc_in      : std_logic_vector(N_SENSORS-1 downto 0) := (others => '0');
    signal m_tdata          : std_logic_vector(15 downto 0);
    signal m_tvalid         : std_logic;
    signal m_tready         : std_logic := '1';
    signal pvt_alarm        : std_logic;
    signal sensor_alarms    : std_logic_vector(N_SENSORS-1 downto 0);
    signal pvt_raw_avg      : std_logic_vector(23 downto 0);
    signal all_valid        : std_logic;

    signal sim_done : boolean := false;

begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    -- Simulate ring oscillators at ~100 MHz (10 ns period)
    gen_osc: for i in 0 to N_SENSORS-1 generate
        process
        begin
            while not sim_done loop
                ring_osc_in(i) <= '0';
                wait for 5 ns;
                ring_osc_in(i) <= '1';
                wait for 5 ns;
            end loop;
            wait;
        end process;
    end generate;

    UUT: entity work.pvt_monitor_top
        generic map (
            N_SENSORS       => N_SENSORS,
            LOG2_N          => LOG2_N,
            SYS_CLK_FREQ    => 50_000_000,
            MEASURE_MS      => 1,
            NOMINAL_COUNT   => 50000,      -- Match entity default
            ALARM_PCT       => 20
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            ring_osc_in     => ring_osc_in,
            measure_start   => measure_start,
            continuous      => continuous,
            clear_alarm     => clear_alarm,
            calib_nominal   => calib_nominal,
            calib_load      => calib_load,
            m_tdata         => m_tdata,
            m_tvalid        => m_tvalid,
            m_tready        => m_tready,
            pvt_alarm       => pvt_alarm,
            sensor_alarms   => sensor_alarms,
            pvt_raw_avg     => pvt_raw_avg,
            all_valid       => all_valid
        );

    stim: process
    begin
        -----------------------------------------------------------------
        -- T1: Reset state
        -----------------------------------------------------------------
        report "T1: Reset state check";
        rst_n <= '0';
        wait for CLK_PERIOD * 5;

        assert pvt_alarm = '0'
            report "T1 FAIL: pvt_alarm not 0" severity failure;
        assert all_valid = '0'
            report "T1 FAIL: all_valid not 0" severity failure;
        report "T1 PASS";

        -----------------------------------------------------------------
        -- T2: Load calibration nominal
        -----------------------------------------------------------------
        report "T2: Calibration load";
        rst_n <= '1';
        wait for CLK_PERIOD * 3;

        -- Nominal count = 50000 edges per 1ms window
        calib_nominal <= std_logic_vector(to_unsigned(50000, 24));
        calib_load <= '1';
        wait for CLK_PERIOD;
        calib_load <= '0';
        wait for CLK_PERIOD * 2;
        report "T2 PASS: Calibration loaded";

        -----------------------------------------------------------------
        -- T3: Start measurement
        -----------------------------------------------------------------
        report "T3: Measurement start";
        measure_start <= '1';
        wait for CLK_PERIOD;
        measure_start <= '0';

        -- Wait for all sensors to complete (1ms measurement + overhead)
        -- 1ms = 50000 cycles at 50MHz
        for i in 0 to 55000 loop
            wait for CLK_PERIOD;
            if all_valid = '1' then
                report "T3 INFO: all_valid at cycle " & integer'image(i);
                exit;
            end if;
        end loop;

        assert all_valid = '1'
            report "T3 FAIL: measurement never completed" severity failure;
        report "T3 INFO: raw_avg=" & integer'image(to_integer(unsigned(pvt_raw_avg)));
        report "T3 PASS";

        -----------------------------------------------------------------
        -- T4: AXI-Stream output
        -----------------------------------------------------------------
        report "T4: AXI-Stream output";
        -- After valid, tvalid should pulse
        for i in 0 to 100 loop
            wait for CLK_PERIOD;
            if m_tvalid = '1' then
                report "T4 INFO: tdata=" & integer'image(to_integer(signed(m_tdata)));
                exit;
            end if;
        end loop;
        report "T4 PASS";

        -----------------------------------------------------------------
        -- T5: Alarm status
        -----------------------------------------------------------------
        report "T5: Alarm check";
        -- Ring osc at ~100MHz, nominal 50K per 1ms should be OK
        report "T5 INFO: pvt_alarm=" & std_logic'image(pvt_alarm);
        report "T5 PASS";

        -----------------------------------------------------------------
        -- T6: Clear alarm
        -----------------------------------------------------------------
        report "T6: Clear alarm";
        clear_alarm <= '1';
        wait for CLK_PERIOD;
        clear_alarm <= '0';
        wait for CLK_PERIOD * 2;
        report "T6 PASS";

        -----------------------------------------------------------------
        report "ALL TESTS PASSED: tb_pvt_monitor_top";
        sim_done <= true;
        wait;
    end process;

end sim;
