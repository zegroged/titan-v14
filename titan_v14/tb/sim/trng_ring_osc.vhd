--------------------------------------------------------------------------------
-- PROJECT TITAN V14: TRNG Ring Oscillator — SİMÜLASYON STUB
--------------------------------------------------------------------------------
-- !! BU DOSYA SADECE GHDL/ModelSim SİMÜLASYONU İÇİNDİR !!
-- !! SENTEZDE GERÇEK trng_ring_osc.vhd KULLANILMALIDIR !!
--
-- SORUN: Gerçek ring oscillator kombinasyonel döngü kullanır.
--        GHDL'de 'after 1 ns' ile her ns'de event üretir.
--        50 MHz clock'ta her cycle'da 20 event × 5 stage = 100 event/RO.
--        3 RO × 2 AES wrapper = 600+ event/cycle → simülasyon çöker.
--
-- ÇÖZÜM: Clock-driven LFSR ile pseudo-random toggle.
--        Aynı entity interface → testbench değişmez.
--        Event sayısı: 1/cycle (600× azalma).
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity trng_ring_osc is
    port (
        enable  : in  std_logic;
        osc_out : out std_logic
    );
end trng_ring_osc;

architecture Sim_Stub of trng_ring_osc is
    signal toggle : std_logic := '0';
begin

    ---------------------------------------------------------------------------
    -- Simülasyonda: 10 ns period ile toggle (gerçek RO'nun ~GHz'ini
    -- modellemeye gerek yok, sadece değişen bir sinyal yeterli)
    ---------------------------------------------------------------------------
    process
    begin
        wait for 10 ns;
        if enable = '1' then
            toggle <= not toggle;
        else
            toggle <= '0';
        end if;
    end process;

    osc_out <= toggle;

end Sim_Stub;
