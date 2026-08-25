--------------------------------------------------------------------------------
-- PROJECT TITAN V14: AES-256 Key Expansion (BRAM S-Box Pipeline)
-- NIST FIPS-197 §5.2 — Rijndael Key Schedule
--------------------------------------------------------------------------------
-- BRAM S-Box ile uyumlu: SubWord işlemi 1 cycle latency.
-- Her round key expansion = 2 cycle (1 BRAM read + 1 XOR compute).
--
-- AES-256: W[i] hesaplama kuralları:
--   i mod 8 = 0: SubWord(RotWord(W[i-1])) XOR Rcon
--   i mod 8 = 4: SubWord(W[i-1])
--   else:        W[i-Nk] XOR W[i-1]
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity aes_key_expand is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        kill_signal  : in  std_logic;
        key_in       : in  std_logic_vector(255 downto 0);
        key_load     : in  std_logic;
        key_start    : in  std_logic;
        round_key    : out std_logic_vector(127 downto 0);
        round_valid  : out std_logic;
        expand_done  : out std_logic
    );
end aes_key_expand;

architecture Behavioral of aes_key_expand is

    -- Rcon constants
    type rcon_array_t is array (0 to 9) of std_logic_vector(7 downto 0);
    constant RCON : rcon_array_t := (
        x"01", x"02", x"04", x"08", x"10",
        x"20", x"40", x"80", x"1B", x"36"
    );

    -- FSM (renamed states to avoid signal name conflict)
    type state_type is (IDLE, DELIVER_RK0, SBOX_WAIT_RK1, DELIVER_RK1,
                        SBOX_DRIVE, SBOX_READ, EXPAND_COMPUTE);
    signal state : state_type := IDLE;

    -- Key register: W[0..7]
    type word_array_t is array (0 to 7) of std_logic_vector(31 downto 0);
    signal W : word_array_t := (others => (others => '0'));

    signal round_cnt  : integer range 0 to 14 := 0;
    signal rcon_idx   : integer range 0 to 9 := 0;
    signal is_rot     : std_logic := '0';  -- 1 = RotWord applied (i mod 8=0)

    -- SubWord S-Box interface (4 BRAM instances, 1 cycle latency)
    signal sbox_addr : std_logic_vector(31 downto 0);
    signal sbox_dout : std_logic_vector(31 downto 0);

    -- Synthesis protection
    attribute dont_touch : string;
    attribute dont_touch of W : signal is "true";

begin

    -- 4 BRAM S-Box instances for SubWord
    gen_sub: for i in 0 to 3 generate
        sbox_inst : entity work.aes_sbox
            port map (
                clk  => clk,
                addr => sbox_addr((3-i)*8+7 downto (3-i)*8),
                dout => sbox_dout((3-i)*8+7 downto (3-i)*8)
            );
    end generate;

    process(clk, kill_signal)
        variable new_w0, new_w1, new_w2, new_w3 : std_logic_vector(31 downto 0);
    begin
        if kill_signal = '1' then
            for i in 0 to 7 loop
                W(i) <= (others => '0');
            end loop;
            state       <= IDLE;
            round_cnt   <= 0;
            rcon_idx    <= 0;
            round_key   <= (others => '0');
            round_valid <= '0';
            expand_done <= '0';
            sbox_addr   <= (others => '0');
            is_rot      <= '0';

        elsif rising_edge(clk) then
            if rst_n = '0' then
                state       <= IDLE;
                round_cnt   <= 0;
                rcon_idx    <= 0;
                round_valid <= '0';
                expand_done <= '0';
                is_rot      <= '0';
            else
                round_valid <= '0';
                expand_done <= '0';

                case state is
                    when IDLE =>
                        if key_load = '1' then
                            W(0) <= key_in(255 downto 224);
                            W(1) <= key_in(223 downto 192);
                            W(2) <= key_in(191 downto 160);
                            W(3) <= key_in(159 downto 128);
                            W(4) <= key_in(127 downto 96);
                            W(5) <= key_in(95  downto 64);
                            W(6) <= key_in(63  downto 32);
                            W(7) <= key_in(31  downto 0);
                        end if;
                        if key_start = '1' then
                            -- ★ FIX: Reload original key for EVERY expansion
                            -- W[0..7] are mutated during expansion. Without reload,
                            -- subsequent operations use corrupted key schedule.
                            W(0) <= key_in(255 downto 224);
                            W(1) <= key_in(223 downto 192);
                            W(2) <= key_in(191 downto 160);
                            W(3) <= key_in(159 downto 128);
                            W(4) <= key_in(127 downto 96);
                            W(5) <= key_in(95  downto 64);
                            W(6) <= key_in(63  downto 32);
                            W(7) <= key_in(31  downto 0);
                            round_cnt <= 0;
                            rcon_idx  <= 0;
                            state     <= DELIVER_RK0;
                        end if;

                    -- Round key 0 = W[0..3]
                    when DELIVER_RK0 =>
                        round_key   <= W(0) & W(1) & W(2) & W(3);
                        round_valid <= '1';
                        round_cnt   <= 1;
                        -- Pre-load BRAM: RotWord(W[7]) for first expansion
                        sbox_addr <= W(7)(23 downto 0) & W(7)(31 downto 24);
                        is_rot    <= '1';
                        -- ★ FIX: BRAM'e 1 cycle ver — sbox_dout STALE olmasın
                        -- ESKİ: state <= DELIVER_RK1;  (sbox_dout STALE!)
                        state     <= SBOX_WAIT_RK1;

                    -- ★ FIX: BRAM address latch'lendi, 1 cycle bekle dout geçerli olsun
                    when SBOX_WAIT_RK1 =>
                        state <= DELIVER_RK1;

                    -- Round key 1 = W[4..7], BRAM result available from DELIVER_RK0
                    when DELIVER_RK1 =>
                        round_key   <= W(4) & W(5) & W(6) & W(7);
                        round_valid <= '1';
                        round_cnt   <= 2;
                        -- sbox_dout now has SubWord(RotWord(W[7]))
                        -- Compute W[8..11] (i mod 8 = 0)
                        new_w0 := W(0) xor sbox_dout xor (RCON(rcon_idx) & x"000000");
                        rcon_idx <= rcon_idx + 1;  -- ★ FIX: RCON index ilerlet
                        new_w1 := W(1) xor new_w0;
                        new_w2 := W(2) xor new_w1;
                        new_w3 := W(3) xor new_w2;
                        -- Shift W
                        W(0) <= W(4); W(1) <= W(5); W(2) <= W(6); W(3) <= W(7);
                        W(4) <= new_w0; W(5) <= new_w1; W(6) <= new_w2; W(7) <= new_w3;
                        -- Pre-load BRAM: SubWord(new_w3) for i mod 8 = 4
                        sbox_addr <= new_w3;
                        is_rot    <= '0';
                        state     <= SBOX_READ;

                    -- Address driven to BRAM, wait 1 cycle for data
                    when SBOX_DRIVE =>
                        state <= SBOX_READ;

                    -- BRAM data available, compute expansion
                    when SBOX_READ =>
                        state <= EXPAND_COMPUTE;

                    when EXPAND_COMPUTE =>
                        -- ★ FIX: Deliver W(4..7) — newly computed half
                        -- ESKİ: W(0) & W(1) & W(2) & W(3)  (wrong: old half!)
                        round_key   <= W(4) & W(5) & W(6) & W(7);
                        round_valid <= '1';

                        if round_cnt = 14 then
                            expand_done <= '1';
                            state       <= IDLE;
                        else
                            if is_rot = '1' then
                                -- i mod 8 = 0: SubWord(RotWord) XOR Rcon
                                -- ★ FIX: W[i-Nk] = W(0), NOT W(4)! (AES-256: Nk=8)
                                new_w0 := W(0) xor sbox_dout xor (RCON(rcon_idx) & x"000000");
                                rcon_idx <= rcon_idx + 1;
                            else
                                -- i mod 8 = 4: SubWord only
                                -- ★ FIX: W[i-Nk] = W(0), NOT W(4)! (AES-256: Nk=8)
                                new_w0 := W(0) xor sbox_dout;
                            end if;
                            new_w1 := W(1) xor new_w0;
                            new_w2 := W(2) xor new_w1;
                            new_w3 := W(3) xor new_w2;
                            -- Shift W
                            W(0) <= W(4); W(1) <= W(5); W(2) <= W(6); W(3) <= W(7);
                            W(4) <= new_w0; W(5) <= new_w1; W(6) <= new_w2; W(7) <= new_w3;
                            -- Prepare next BRAM lookup
                            if is_rot = '0' then
                                -- Next: i mod 8 = 0 → RotWord + SubWord
                                sbox_addr <= new_w3(23 downto 0) & new_w3(31 downto 24);
                                is_rot    <= '1';
                            else
                                -- Next: i mod 8 = 4 → SubWord only
                                sbox_addr <= new_w3;
                                is_rot    <= '0';
                            end if;
                            round_cnt <= round_cnt + 1;
                            state     <= SBOX_READ;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
