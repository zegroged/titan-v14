library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
entity tb_crc_check is end;
architecture t of tb_crc_check is
  function crc16_bit(crc_in : std_logic_vector(15 downto 0); din : std_logic) return std_logic_vector is
    variable c : std_logic_vector(15 downto 0); variable x : std_logic;
  begin
    x := crc_in(15) xor din;
    c(0) := x; c(1) := crc_in(0); c(2) := crc_in(1); c(3) := crc_in(2);
    c(4) := crc_in(3); c(5) := crc_in(4) xor x; c(6) := crc_in(5); c(7) := crc_in(6);
    c(8) := crc_in(7); c(9) := crc_in(8); c(10) := crc_in(9); c(11) := crc_in(10);
    c(12) := crc_in(11) xor x; c(13) := crc_in(12); c(14) := crc_in(13); c(15) := crc_in(14);
    return c;
  end function;
  function compute_crc(data : std_logic_vector) return std_logic_vector is
    variable crc : std_logic_vector(15 downto 0) := x"FFFF";
  begin
    for i in data'high downto data'low loop crc := crc16_bit(crc, data(i)); end loop;
    return crc;
  end function;
begin
  process
    variable hdr : std_logic_vector(55 downto 0);
    variable pld : std_logic_vector(23 downto 0);
    variable no_pld_hdr : std_logic_vector(55 downto 0);
    variable crc1, crc2, crc3 : std_logic_vector(15 downto 0);
  begin
    hdr := x"A0" & x"0003" & x"00000003";
    pld := x"051234";
    no_pld_hdr := x"20" & x"0000" & x"00000001";
    crc1 := compute_crc(no_pld_hdr);
    crc2 := compute_crc(hdr & pld);
    crc3 := compute_crc(hdr);
    report "STATUS no-payload CRC: " & to_hstring(crc1);
    report "AEGIS hdr+pld CRC: " & to_hstring(crc2);
    report "AEGIS hdr-only CRC: " & to_hstring(crc3);
    std.env.finish;
  end process;
end;