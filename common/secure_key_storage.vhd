--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Secure Key Storage (ANAHTAR MEZARLIĞI)
-- Module: AES-256 Master Key Vault with Async Deep Wipe
--------------------------------------------------------------------------------
-- AMAÇ: 256-bit master key'i güvenli saklamak ve KILL sinyali geldiğinde
--       ASENKRON silmek.
--
-- V14 DEĞİŞİKLİK: Key expansion artık aes256_core içinde on-the-fly
--   yapılıyor. Bu modül sadece master key'i saklıyor ve async wipe sağlıyor.
--
-- GÜVENLİK:
--   1. Master Key (256-bit) FF'lerde saklanır (BRAM YOK)
--   2. KILL geldiğinde 256 bit ASENKRON temizlenir
--   3. key_valid flag ile AES motoru kontrol edilir
--   4. DONT_TOUCH + syn_keep attributes (sentez koruması)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity secure_key_storage is
    port (
        clk          : in  std_logic;
        kill_signal  : in  std_logic;
        load_key     : in  std_logic;
        master_key   : in  std_logic_vector(255 downto 0);

        -- Çıkışlar
        key_out      : out std_logic_vector(255 downto 0);
        key_valid    : out std_logic;

        -- Legacy uyumluluk (artix7_top_v14 için)
        round_keys   : out std_logic_vector(1919 downto 0)
    );
end secure_key_storage;

architecture Behavioral of secure_key_storage is

    -------------------------------------------------------------------------
    -- Key register (256-bit, distributed FF)
    -------------------------------------------------------------------------
    signal stored_key  : std_logic_vector(255 downto 0) := (others => '0');
    signal valid_flag  : std_logic := '0';

    -------------------------------------------------------------------------
    -- Sentez koruması
    -------------------------------------------------------------------------
    attribute keep : string;
    attribute keep of stored_key : signal is "true";
    attribute keep of valid_flag : signal is "true";

    attribute dont_touch : string;
    attribute dont_touch of stored_key : signal is "true";
    attribute dont_touch of valid_flag : signal is "true";

    attribute ram_style : string;
    attribute ram_style of stored_key : signal is "distributed";

    -- Microchip Synplify
    attribute syn_keep : boolean;
    attribute syn_keep of stored_key : signal is true;
    attribute syn_keep of valid_flag : signal is true;

    attribute syn_preserve : boolean;
    attribute syn_preserve of stored_key : signal is true;
    attribute syn_preserve of valid_flag : signal is true;

begin

    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            -- ASYNC wipe: Tüm key material anında silinir
            stored_key <= (others => '0');
            valid_flag <= '0';

        elsif rising_edge(clk) then
            if load_key = '1' then
                stored_key <= master_key;
                valid_flag <= '1';
            end if;
        end if;
    end process;

    -- Output assignments
    key_out   <= stored_key;
    key_valid <= valid_flag;

    -- Legacy: round_keys çıkışı (V14'te aes_core_wrapper artık direkt
    -- aes256_core kullanıyor, bu port geriye uyumluluk için tutuldu)
    round_keys <= (others => '0');

end Behavioral;
