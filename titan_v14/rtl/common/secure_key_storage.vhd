--------------------------------------------------------------------------------
-- PROJECT TITAN V14: Secure Key Storage (ANAHTAR MEZARLIĞI)
-- Module: AES-256 Master Key Vault with Async Deep Wipe + Warm Reset
--------------------------------------------------------------------------------
-- AMAÇ: 256-bit master key'i güvenli saklamak ve KILL sinyali geldiğinde
--       ASENKRON silmek. Warm reset (rst_n) geldiğinde SENKRON silmek.
--
-- V15 P0-2: KEY OUTPUT GATING
--   key_out portu artık sürekli açık değil. Sadece AES motoru aktif
--   çalışırken (aes_busy='1') key dış dünyaya çıkar.
--   Side-channel saldırganının key_out hattındaki güç profilini
--   sürekli okuması önlenir.
-- V14 DEĞİŞİKLİK: Key expansion artık aes256_core içinde on-the-fly
--   yapılıyor. Bu modül sadece master key'i saklıyor ve async wipe sağlıyor.
--
-- V14.1 DEĞİŞİKLİK (GAP-2 FIX):
--   rst_n portu eklendi. Warm reset sırasında da key material temizlenir.
--   Bu sayede false-alarm kill sonrası veya normal reset sırasında
--   eski key flipflop'larda kalmaz.
--
-- GÜVENLİK:
--   1. Master Key (256-bit) FF'lerde saklanır (BRAM YOK)
--   2. KILL geldiğinde 256 bit ASENKRON temizlenir (acil imha)
--   3. rst_n='0' geldiğinde 256 bit SENKRON temizlenir (warm reset)
--   4. key_valid flag ile AES motoru kontrol edilir
--   5. DONT_TOUCH + syn_keep attributes (sentez koruması)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity secure_key_storage is
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;  -- ★ GAP-2 FIX: Warm reset (active low)
        kill_signal  : in  std_logic;
        load_key     : in  std_logic;
        master_key   : in  std_logic_vector(255 downto 0);
        aes_busy     : in  std_logic;  -- ★ V15 P0-2: AES engine active flag

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

    ---------------------------------------------------------------------------
    -- KEY MANAGEMENT PROCESS
    -- Priority: kill_signal (async) > rst_n (sync) > load_key (sync)
    ---------------------------------------------------------------------------
    process(clk, kill_signal)
    begin
        if kill_signal = '1' then
            -------------------------------------------------------------------
            -- ASYNC WIPE (ACİL İMHA): kill_signal geldi → ANINDA sil!
            -- Bu yol asenkrondur, clock gelmese bile çalışır.
            -------------------------------------------------------------------
            stored_key <= (others => '0');
            valid_flag <= '0';

        elsif rising_edge(clk) then
            if rst_n = '0' then
                ---------------------------------------------------------------
                -- SYNC WIPE (WARM RESET): rst_n düşük → senkron temizle
                -- False alarm kill veya normal reset sonrası:
                --   eski key material flipflop'larda kalmasın!
                ---------------------------------------------------------------
                stored_key <= (others => '0');
                valid_flag <= '0';

            elsif load_key = '1' then
                ---------------------------------------------------------------
                -- KEY LOAD: Yeni master key yükle
                ---------------------------------------------------------------
                stored_key <= master_key;
                valid_flag <= '1';
            end if;
        end if;
    end process;

    -- Output assignments
    -- ★ V15 P0-2: Key output gating — key sadece AES aktif iken dışı görür
    key_out   <= stored_key when aes_busy = '1' else (others => '0');
    key_valid <= valid_flag;

    -- Legacy: round_keys çıkışı (V14'te aes_core_wrapper artık direkt
    -- aes256_core kullanıyor, bu port geriye uyumluluk için tutuldu)
    round_keys <= (others => '0');

end Behavioral;
