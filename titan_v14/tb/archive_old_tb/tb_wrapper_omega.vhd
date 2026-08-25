library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_wrapper_omega is
end tb_wrapper_omega;

architecture Behavioral of tb_wrapper_omega is
    signal clk, rst_n      : std_logic := '0';
    signal kill_signal      : std_logic := '0';
    signal master_key       : std_logic_vector(255 downto 0) := x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    signal key_valid        : std_logic := '0';
    signal iv_in            : std_logic_vector(127 downto 0) := (others => '0');
    signal plain_text       : std_logic_vector(127 downto 0) := (others => '0');
    signal valid_in         : std_logic := '0';
    signal cipher_text      : std_logic_vector(127 downto 0);
    signal valid_out        : std_logic;
    signal fault_detected   : std_logic;
    signal direction        : std_logic := '0';
    signal aes_timeout      : std_logic;
    signal omega_enable     : std_logic := '0';
    signal trng_seed        : std_logic_vector(31 downto 0) := x"00800000";
    signal trng_seed_valid  : std_logic := '0';
    signal omega_dummies    : std_logic_vector(15 downto 0);
    signal omega_active     : std_logic;
    signal sim_done         : boolean := false;
    constant CLK_PERIOD     : time := 10 ns;
begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    uut : entity work.aes_core_wrapper
        port map (
            clk              => clk,
            rst_n            => rst_n,
            kill_signal      => kill_signal,
            master_key_in    => master_key,
            key_valid        => key_valid,
            iv_in            => iv_in,
            plain_text       => plain_text,
            valid_in         => valid_in,
            cipher_text      => cipher_text,
            valid_out        => valid_out,
            fault_detected   => fault_detected,
            direction        => direction,
            aes_timeout      => aes_timeout,
            omega_enable     => omega_enable,
            trng_seed        => trng_seed,
            trng_seed_valid  => trng_seed_valid,
            omega_dummy_count => omega_dummies,
            omega_active     => omega_active
        );

    process
    begin
        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        -- TEST 1: Omega OFF — baseline
        report "TEST1: Omega OFF" severity note;
        omega_enable <= '0';
        key_valid <= '1';
        wait until rising_edge(clk);
        key_valid <= '0';
        wait for CLK_PERIOD * 2000;  -- Wait for full key derivation

        -- Check if wrapper is ready
        report "TEST1: Sending data (omega OFF)" severity note;
        plain_text <= x"DEADBEEFCAFEBABE1234567890ABCDEF";
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0';

        for i in 1 to 2000 loop
            wait until rising_edge(clk);
            if valid_out = '1' then
                report "TEST1 PASS: valid_out at cycle " & integer'image(i) severity note;
                exit;
            end if;
            if aes_timeout = '1' then
                report "TEST1 FAIL: AES timeout at cycle " & integer'image(i) severity error;
                exit;
            end if;
            if i = 2000 then
                report "TEST1 FAIL: no response in 2000 cycles" severity error;
            end if;
        end loop;

        wait for CLK_PERIOD * 20;

        -- TEST 2: Omega ON — kill + reinit
        report "TEST2: Omega ON" severity note;
        omega_enable <= '1';
        -- Seed PRNG
        trng_seed_valid <= '1';
        wait until rising_edge(clk);
        trng_seed_valid <= '0';
        wait for CLK_PERIOD * 50;

        -- Kill and reinit
        kill_signal <= '1';
        wait for CLK_PERIOD * 2;
        kill_signal <= '0';
        wait for CLK_PERIOD * 10;

        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        key_valid <= '1';
        wait until rising_edge(clk);
        key_valid <= '0';

        -- Re-seed PRNG after reset
        trng_seed_valid <= '1';
        wait until rising_edge(clk);
        trng_seed_valid <= '0';

        wait for CLK_PERIOD * 2000;  -- Wait for key derivation

        report "TEST2: Sending data (omega ON)" severity note;
        plain_text <= x"1111222233334444AAAABBBBCCCCDDDD";
        valid_in <= '1';
        wait until rising_edge(clk);
        valid_in <= '0';

        for i in 1 to 5000 loop
            wait until rising_edge(clk);
            if valid_out = '1' then
                report "TEST2 PASS: valid_out at cycle " & integer'image(i) severity note;
                exit;
            end if;
            if aes_timeout = '1' then
                report "TEST2 FAIL: AES timeout at cycle " & integer'image(i) severity error;
                exit;
            end if;
            if i = 5000 then
                report "TEST2 FAIL: no response in 5000 cycles" severity error;
            end if;
        end loop;

        wait for CLK_PERIOD * 20;
        report "=== ALL TESTS COMPLETE ===" severity note;
        sim_done <= true;
        wait;
    end process;

end Behavioral;
