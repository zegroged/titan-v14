library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_mask_determinism is
end tb_mask_determinism;

architecture Behavioral of tb_mask_determinism is
    signal clk, rst_n      : std_logic := '0';
    signal kill_signal      : std_logic := '0';
    signal key_in           : std_logic_vector(255 downto 0) := (others => '0');
    signal key_load         : std_logic := '0';
    signal plaintext        : std_logic_vector(127 downto 0) := (others => '0');
    signal start            : std_logic := '0';
    signal ciphertext       : std_logic_vector(127 downto 0);
    signal done, busy       : std_logic;
    signal trng_mask        : std_logic_vector(127 downto 0) := (others => '0');
    signal fault_detected   : std_logic;
    signal sim_done         : boolean := false;
    constant CLK_PERIOD     : time := 10 ns;
    signal ct_mask0         : std_logic_vector(127 downto 0);
    signal ct_mask1         : std_logic_vector(127 downto 0);
begin

    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';

    u_aes : entity work.aes256_core
        port map (
            clk => clk, rst_n => rst_n, kill_signal => kill_signal,
            key_in => key_in, key_load => key_load, plaintext => plaintext,
            start => start, ciphertext => ciphertext, done => done,
            busy => busy, trng_mask => trng_mask, fault_detected => fault_detected
        );

    process
    begin
        rst_n <= '0'; wait for CLK_PERIOD * 5;
        rst_n <= '1'; wait for CLK_PERIOD * 5;

        key_in <= x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        
        -- TEST 1: mask=0
        trng_mask <= (others => '0');
        key_load <= '1'; wait until rising_edge(clk); key_load <= '0';
        wait for CLK_PERIOD * 5;
        plaintext <= x"00112233445566778899aabbccddeeff";
        start <= '1'; wait until rising_edge(clk); start <= '0';
        wait until done = '1'; wait until rising_edge(clk);
        ct_mask0 <= ciphertext;
        report "CT mask0: " & to_hstring(ciphertext) severity note;
        wait for CLK_PERIOD * 10;

        -- TEST 2: mask=DEADBEEF (reload key with new mask)
        trng_mask <= x"DEADBEEF12345678ABCDEF0123456789";
        key_load <= '1'; wait until rising_edge(clk); key_load <= '0';
        wait for CLK_PERIOD * 5;
        plaintext <= x"00112233445566778899aabbccddeeff";
        start <= '1'; wait until rising_edge(clk); start <= '0';
        wait until done = '1'; wait until rising_edge(clk);
        ct_mask1 <= ciphertext;
        report "CT mask1: " & to_hstring(ciphertext) severity note;
        wait for CLK_PERIOD * 5;

        if ct_mask0 = ct_mask1 then
            report "DETERMINISTIC: both masks produce same output" severity note;
        else
            report "BUG: different masks produce DIFFERENT outputs!" severity error;
        end if;

        sim_done <= true; wait;
    end process;
end Behavioral;
