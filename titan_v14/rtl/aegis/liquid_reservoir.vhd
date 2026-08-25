--------------------------------------------------------------------------------
-- PROJECT OMEGA: Liquid State Reservoir
-- OTOMATİK ÜRETİLMİŞ DOSYA - ELLE DEĞİŞTİRMEYİN!
--------------------------------------------------------------------------------
-- Generated: 2026-02-06 18:25:58
-- Random Seed: 907053
-- Nodes: 128
-- Connections per node: 3
-- Injection ratio: 20.0%
--
-- ⚠️ UYARI: Bu dosya COMBINATORIAl LOOP içerir!
--   Vivado: set_property ALLOW_COMBINATORIAL_LOOPS TRUE
--
-- KAOS AĞI YAPISI:
--   Input Layer  → Plaintext injection
--   Reservoir    → Kaotik okyanus (clock-less)
--   Readout      → Sampling (clock-ed)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity liquid_reservoir is
    port (
        -------------------------------------------------------------------
        -- Sampling Clock (Sadece readout için - reservoir clock-less!)
        -------------------------------------------------------------------
        clk         : in  std_logic;
        rst_n       : in  std_logic;
        
        -------------------------------------------------------------------
        -- Input (Plaintext damlatma)
        -------------------------------------------------------------------
        plain_text  : in  std_logic_vector(7 downto 0);
        
        -------------------------------------------------------------------
        -- Output (Kaotik fırtınanın fotoğrafı)
        -------------------------------------------------------------------
        cipher_text : out std_logic_vector(127 downto 0)
    );
end liquid_reservoir;

architecture Behavioral of liquid_reservoir is

    -------------------------------------------------------------------
    -- Reservoir State (Tüm düğümlerin anlık durumu)
    -------------------------------------------------------------------
    signal nodes : std_logic_vector(127 downto 0);

    -------------------------------------------------------------------
    -- Sentez Koruma (Vivado/Libero)
    -------------------------------------------------------------------
    attribute keep : string;
    attribute keep of nodes : signal is "true";
    
    attribute dont_touch : string;
    attribute dont_touch of nodes : signal is "true";

begin

    -------------------------------------------------------------------
    -- KAOS AĞI (Combinatorial Loop Network)
    -------------------------------------------------------------------
    -- Her düğüm rastgele 3 komşuya bağlı
    -- %20 düğüme plaintext bit'i enjekte edilir
    -------------------------------------------------------------------

    -------------------------------------------------------------------
    -- Node 0: Komşular [29, 127, 5]
    -------------------------------------------------------------------
    node_0_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(29),
            inputs(1) => nodes(127),
            inputs(2) => nodes(5),
            inject    => '0',
            output    => nodes(0)
        );

    -------------------------------------------------------------------
    -- Node 1: Komşular [75, 124, 54]
    -------------------------------------------------------------------
    node_1_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(75),
            inputs(1) => nodes(124),
            inputs(2) => nodes(54),
            inject    => '0',
            output    => nodes(1)
        );

    -------------------------------------------------------------------
    -- Node 2: Komşular [21, 49, 116]
    -------------------------------------------------------------------
    node_2_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(21),
            inputs(1) => nodes(49),
            inputs(2) => nodes(116),
            inject    => plain_text(2),
            output    => nodes(2)
        );

    -------------------------------------------------------------------
    -- Node 3: Komşular [46, 36, 104]
    -------------------------------------------------------------------
    node_3_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(46),
            inputs(1) => nodes(36),
            inputs(2) => nodes(104),
            inject    => '0',
            output    => nodes(3)
        );

    -------------------------------------------------------------------
    -- Node 4: Komşular [58, 47, 69]
    -------------------------------------------------------------------
    node_4_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(58),
            inputs(1) => nodes(47),
            inputs(2) => nodes(69),
            inject    => '0',
            output    => nodes(4)
        );

    -------------------------------------------------------------------
    -- Node 5: Komşular [42, 124, 19]
    -------------------------------------------------------------------
    node_5_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(42),
            inputs(1) => nodes(124),
            inputs(2) => nodes(19),
            inject    => '0',
            output    => nodes(5)
        );

    -------------------------------------------------------------------
    -- Node 6: Komşular [66, 15, 17]
    -------------------------------------------------------------------
    node_6_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(66),
            inputs(1) => nodes(15),
            inputs(2) => nodes(17),
            inject    => '0',
            output    => nodes(6)
        );

    -------------------------------------------------------------------
    -- Node 7: Komşular [14, 18, 73]
    -------------------------------------------------------------------
    node_7_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(14),
            inputs(1) => nodes(18),
            inputs(2) => nodes(73),
            inject    => '0',
            output    => nodes(7)
        );

    -------------------------------------------------------------------
    -- Node 8: Komşular [64, 25, 95]
    -------------------------------------------------------------------
    node_8_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(64),
            inputs(1) => nodes(25),
            inputs(2) => nodes(95),
            inject    => plain_text(0),
            output    => nodes(8)
        );

    -------------------------------------------------------------------
    -- Node 9: Komşular [58, 71, 107]
    -------------------------------------------------------------------
    node_9_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(58),
            inputs(1) => nodes(71),
            inputs(2) => nodes(107),
            inject    => plain_text(1),
            output    => nodes(9)
        );

    -------------------------------------------------------------------
    -- Node 10: Komşular [16, 38, 35]
    -------------------------------------------------------------------
    node_10_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(16),
            inputs(1) => nodes(38),
            inputs(2) => nodes(35),
            inject    => '0',
            output    => nodes(10)
        );

    -------------------------------------------------------------------
    -- Node 11: Komşular [95, 55, 87]
    -------------------------------------------------------------------
    node_11_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(95),
            inputs(1) => nodes(55),
            inputs(2) => nodes(87),
            inject    => '0',
            output    => nodes(11)
        );

    -------------------------------------------------------------------
    -- Node 12: Komşular [106, 94, 9]
    -------------------------------------------------------------------
    node_12_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(106),
            inputs(1) => nodes(94),
            inputs(2) => nodes(9),
            inject    => '0',
            output    => nodes(12)
        );

    -------------------------------------------------------------------
    -- Node 13: Komşular [20, 103, 126]
    -------------------------------------------------------------------
    node_13_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(20),
            inputs(1) => nodes(103),
            inputs(2) => nodes(126),
            inject    => '0',
            output    => nodes(13)
        );

    -------------------------------------------------------------------
    -- Node 14: Komşular [65, 95, 110]
    -------------------------------------------------------------------
    node_14_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(65),
            inputs(1) => nodes(95),
            inputs(2) => nodes(110),
            inject    => '0',
            output    => nodes(14)
        );

    -------------------------------------------------------------------
    -- Node 15: Komşular [123, 105, 4]
    -------------------------------------------------------------------
    node_15_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(123),
            inputs(1) => nodes(105),
            inputs(2) => nodes(4),
            inject    => plain_text(7),
            output    => nodes(15)
        );

    -------------------------------------------------------------------
    -- Node 16: Komşular [40, 34, 20]
    -------------------------------------------------------------------
    node_16_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(40),
            inputs(1) => nodes(34),
            inputs(2) => nodes(20),
            inject    => '0',
            output    => nodes(16)
        );

    -------------------------------------------------------------------
    -- Node 17: Komşular [108, 84, 81]
    -------------------------------------------------------------------
    node_17_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(108),
            inputs(1) => nodes(84),
            inputs(2) => nodes(81),
            inject    => '0',
            output    => nodes(17)
        );

    -------------------------------------------------------------------
    -- Node 18: Komşular [63, 1, 40]
    -------------------------------------------------------------------
    node_18_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(63),
            inputs(1) => nodes(1),
            inputs(2) => nodes(40),
            inject    => '0',
            output    => nodes(18)
        );

    -------------------------------------------------------------------
    -- Node 19: Komşular [88, 69, 93]
    -------------------------------------------------------------------
    node_19_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(88),
            inputs(1) => nodes(69),
            inputs(2) => nodes(93),
            inject    => '0',
            output    => nodes(19)
        );

    -------------------------------------------------------------------
    -- Node 20: Komşular [54, 113, 92]
    -------------------------------------------------------------------
    node_20_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(54),
            inputs(1) => nodes(113),
            inputs(2) => nodes(92),
            inject    => '0',
            output    => nodes(20)
        );

    -------------------------------------------------------------------
    -- Node 21: Komşular [22, 89, 50]
    -------------------------------------------------------------------
    node_21_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(22),
            inputs(1) => nodes(89),
            inputs(2) => nodes(50),
            inject    => '0',
            output    => nodes(21)
        );

    -------------------------------------------------------------------
    -- Node 22: Komşular [117, 4, 120]
    -------------------------------------------------------------------
    node_22_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(117),
            inputs(1) => nodes(4),
            inputs(2) => nodes(120),
            inject    => '0',
            output    => nodes(22)
        );

    -------------------------------------------------------------------
    -- Node 23: Komşular [53, 61, 25]
    -------------------------------------------------------------------
    node_23_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(53),
            inputs(1) => nodes(61),
            inputs(2) => nodes(25),
            inject    => '0',
            output    => nodes(23)
        );

    -------------------------------------------------------------------
    -- Node 24: Komşular [18, 99, 88]
    -------------------------------------------------------------------
    node_24_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(18),
            inputs(1) => nodes(99),
            inputs(2) => nodes(88),
            inject    => '0',
            output    => nodes(24)
        );

    -------------------------------------------------------------------
    -- Node 25: Komşular [4, 42, 92]
    -------------------------------------------------------------------
    node_25_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(4),
            inputs(1) => nodes(42),
            inputs(2) => nodes(92),
            inject    => '0',
            output    => nodes(25)
        );

    -------------------------------------------------------------------
    -- Node 26: Komşular [40, 68, 102]
    -------------------------------------------------------------------
    node_26_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(40),
            inputs(1) => nodes(68),
            inputs(2) => nodes(102),
            inject    => '0',
            output    => nodes(26)
        );

    -------------------------------------------------------------------
    -- Node 27: Komşular [114, 124, 122]
    -------------------------------------------------------------------
    node_27_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(114),
            inputs(1) => nodes(124),
            inputs(2) => nodes(122),
            inject    => '0',
            output    => nodes(27)
        );

    -------------------------------------------------------------------
    -- Node 28: Komşular [59, 34, 118]
    -------------------------------------------------------------------
    node_28_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(59),
            inputs(1) => nodes(34),
            inputs(2) => nodes(118),
            inject    => '0',
            output    => nodes(28)
        );

    -------------------------------------------------------------------
    -- Node 29: Komşular [63, 12, 92]
    -------------------------------------------------------------------
    node_29_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(63),
            inputs(1) => nodes(12),
            inputs(2) => nodes(92),
            inject    => '0',
            output    => nodes(29)
        );

    -------------------------------------------------------------------
    -- Node 30: Komşular [75, 124, 113]
    -------------------------------------------------------------------
    node_30_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(75),
            inputs(1) => nodes(124),
            inputs(2) => nodes(113),
            inject    => '0',
            output    => nodes(30)
        );

    -------------------------------------------------------------------
    -- Node 31: Komşular [51, 53, 100]
    -------------------------------------------------------------------
    node_31_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(51),
            inputs(1) => nodes(53),
            inputs(2) => nodes(100),
            inject    => '0',
            output    => nodes(31)
        );

    -------------------------------------------------------------------
    -- Node 32: Komşular [7, 113, 22]
    -------------------------------------------------------------------
    node_32_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(7),
            inputs(1) => nodes(113),
            inputs(2) => nodes(22),
            inject    => '0',
            output    => nodes(32)
        );

    -------------------------------------------------------------------
    -- Node 33: Komşular [10, 27, 52]
    -------------------------------------------------------------------
    node_33_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(10),
            inputs(1) => nodes(27),
            inputs(2) => nodes(52),
            inject    => '0',
            output    => nodes(33)
        );

    -------------------------------------------------------------------
    -- Node 34: Komşular [73, 123, 38]
    -------------------------------------------------------------------
    node_34_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(73),
            inputs(1) => nodes(123),
            inputs(2) => nodes(38),
            inject    => '0',
            output    => nodes(34)
        );

    -------------------------------------------------------------------
    -- Node 35: Komşular [59, 55, 61]
    -------------------------------------------------------------------
    node_35_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(59),
            inputs(1) => nodes(55),
            inputs(2) => nodes(61),
            inject    => '0',
            output    => nodes(35)
        );

    -------------------------------------------------------------------
    -- Node 36: Komşular [13, 46, 0]
    -------------------------------------------------------------------
    node_36_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(13),
            inputs(1) => nodes(46),
            inputs(2) => nodes(0),
            inject    => '0',
            output    => nodes(36)
        );

    -------------------------------------------------------------------
    -- Node 37: Komşular [122, 60, 72]
    -------------------------------------------------------------------
    node_37_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(122),
            inputs(1) => nodes(60),
            inputs(2) => nodes(72),
            inject    => '0',
            output    => nodes(37)
        );

    -------------------------------------------------------------------
    -- Node 38: Komşular [19, 77, 51]
    -------------------------------------------------------------------
    node_38_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(19),
            inputs(1) => nodes(77),
            inputs(2) => nodes(51),
            inject    => plain_text(6),
            output    => nodes(38)
        );

    -------------------------------------------------------------------
    -- Node 39: Komşular [70, 17, 15]
    -------------------------------------------------------------------
    node_39_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(70),
            inputs(1) => nodes(17),
            inputs(2) => nodes(15),
            inject    => '0',
            output    => nodes(39)
        );

    -------------------------------------------------------------------
    -- Node 40: Komşular [37, 84, 11]
    -------------------------------------------------------------------
    node_40_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(37),
            inputs(1) => nodes(84),
            inputs(2) => nodes(11),
            inject    => '0',
            output    => nodes(40)
        );

    -------------------------------------------------------------------
    -- Node 41: Komşular [63, 112, 46]
    -------------------------------------------------------------------
    node_41_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(63),
            inputs(1) => nodes(112),
            inputs(2) => nodes(46),
            inject    => '0',
            output    => nodes(41)
        );

    -------------------------------------------------------------------
    -- Node 42: Komşular [74, 39, 27]
    -------------------------------------------------------------------
    node_42_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(74),
            inputs(1) => nodes(39),
            inputs(2) => nodes(27),
            inject    => plain_text(2),
            output    => nodes(42)
        );

    -------------------------------------------------------------------
    -- Node 43: Komşular [29, 120, 86]
    -------------------------------------------------------------------
    node_43_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(29),
            inputs(1) => nodes(120),
            inputs(2) => nodes(86),
            inject    => '0',
            output    => nodes(43)
        );

    -------------------------------------------------------------------
    -- Node 44: Komşular [46, 40, 34]
    -------------------------------------------------------------------
    node_44_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(46),
            inputs(1) => nodes(40),
            inputs(2) => nodes(34),
            inject    => '0',
            output    => nodes(44)
        );

    -------------------------------------------------------------------
    -- Node 45: Komşular [25, 49, 46]
    -------------------------------------------------------------------
    node_45_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(25),
            inputs(1) => nodes(49),
            inputs(2) => nodes(46),
            inject    => '0',
            output    => nodes(45)
        );

    -------------------------------------------------------------------
    -- Node 46: Komşular [122, 11, 6]
    -------------------------------------------------------------------
    node_46_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(122),
            inputs(1) => nodes(11),
            inputs(2) => nodes(6),
            inject    => plain_text(6),
            output    => nodes(46)
        );

    -------------------------------------------------------------------
    -- Node 47: Komşular [33, 35, 62]
    -------------------------------------------------------------------
    node_47_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(33),
            inputs(1) => nodes(35),
            inputs(2) => nodes(62),
            inject    => '0',
            output    => nodes(47)
        );

    -------------------------------------------------------------------
    -- Node 48: Komşular [82, 102, 27]
    -------------------------------------------------------------------
    node_48_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(82),
            inputs(1) => nodes(102),
            inputs(2) => nodes(27),
            inject    => plain_text(0),
            output    => nodes(48)
        );

    -------------------------------------------------------------------
    -- Node 49: Komşular [111, 84, 80]
    -------------------------------------------------------------------
    node_49_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(111),
            inputs(1) => nodes(84),
            inputs(2) => nodes(80),
            inject    => plain_text(1),
            output    => nodes(49)
        );

    -------------------------------------------------------------------
    -- Node 50: Komşular [61, 86, 25]
    -------------------------------------------------------------------
    node_50_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(61),
            inputs(1) => nodes(86),
            inputs(2) => nodes(25),
            inject    => '0',
            output    => nodes(50)
        );

    -------------------------------------------------------------------
    -- Node 51: Komşular [4, 76, 109]
    -------------------------------------------------------------------
    node_51_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(4),
            inputs(1) => nodes(76),
            inputs(2) => nodes(109),
            inject    => '0',
            output    => nodes(51)
        );

    -------------------------------------------------------------------
    -- Node 52: Komşular [55, 82, 122]
    -------------------------------------------------------------------
    node_52_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(55),
            inputs(1) => nodes(82),
            inputs(2) => nodes(122),
            inject    => '0',
            output    => nodes(52)
        );

    -------------------------------------------------------------------
    -- Node 53: Komşular [32, 68, 35]
    -------------------------------------------------------------------
    node_53_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(32),
            inputs(1) => nodes(68),
            inputs(2) => nodes(35),
            inject    => '0',
            output    => nodes(53)
        );

    -------------------------------------------------------------------
    -- Node 54: Komşular [47, 71, 93]
    -------------------------------------------------------------------
    node_54_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(47),
            inputs(1) => nodes(71),
            inputs(2) => nodes(93),
            inject    => '0',
            output    => nodes(54)
        );

    -------------------------------------------------------------------
    -- Node 55: Komşular [102, 123, 35]
    -------------------------------------------------------------------
    node_55_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(102),
            inputs(1) => nodes(123),
            inputs(2) => nodes(35),
            inject    => '0',
            output    => nodes(55)
        );

    -------------------------------------------------------------------
    -- Node 56: Komşular [106, 94, 31]
    -------------------------------------------------------------------
    node_56_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(106),
            inputs(1) => nodes(94),
            inputs(2) => nodes(31),
            inject    => plain_text(0),
            output    => nodes(56)
        );

    -------------------------------------------------------------------
    -- Node 57: Komşular [42, 16, 0]
    -------------------------------------------------------------------
    node_57_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(42),
            inputs(1) => nodes(16),
            inputs(2) => nodes(0),
            inject    => '0',
            output    => nodes(57)
        );

    -------------------------------------------------------------------
    -- Node 58: Komşular [52, 117, 101]
    -------------------------------------------------------------------
    node_58_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(52),
            inputs(1) => nodes(117),
            inputs(2) => nodes(101),
            inject    => plain_text(2),
            output    => nodes(58)
        );

    -------------------------------------------------------------------
    -- Node 59: Komşular [85, 99, 48]
    -------------------------------------------------------------------
    node_59_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(85),
            inputs(1) => nodes(99),
            inputs(2) => nodes(48),
            inject    => '0',
            output    => nodes(59)
        );

    -------------------------------------------------------------------
    -- Node 60: Komşular [122, 100, 15]
    -------------------------------------------------------------------
    node_60_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(122),
            inputs(1) => nodes(100),
            inputs(2) => nodes(15),
            inject    => '0',
            output    => nodes(60)
        );

    -------------------------------------------------------------------
    -- Node 61: Komşular [91, 5, 69]
    -------------------------------------------------------------------
    node_61_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(91),
            inputs(1) => nodes(5),
            inputs(2) => nodes(69),
            inject    => '0',
            output    => nodes(61)
        );

    -------------------------------------------------------------------
    -- Node 62: Komşular [114, 14, 48]
    -------------------------------------------------------------------
    node_62_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(114),
            inputs(1) => nodes(14),
            inputs(2) => nodes(48),
            inject    => '0',
            output    => nodes(62)
        );

    -------------------------------------------------------------------
    -- Node 63: Komşular [57, 6, 45]
    -------------------------------------------------------------------
    node_63_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(57),
            inputs(1) => nodes(6),
            inputs(2) => nodes(45),
            inject    => '0',
            output    => nodes(63)
        );

    -------------------------------------------------------------------
    -- Node 64: Komşular [75, 102, 61]
    -------------------------------------------------------------------
    node_64_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(75),
            inputs(1) => nodes(102),
            inputs(2) => nodes(61),
            inject    => '0',
            output    => nodes(64)
        );

    -------------------------------------------------------------------
    -- Node 65: Komşular [24, 29, 32]
    -------------------------------------------------------------------
    node_65_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(24),
            inputs(1) => nodes(29),
            inputs(2) => nodes(32),
            inject    => plain_text(1),
            output    => nodes(65)
        );

    -------------------------------------------------------------------
    -- Node 66: Komşular [23, 19, 1]
    -------------------------------------------------------------------
    node_66_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(23),
            inputs(1) => nodes(19),
            inputs(2) => nodes(1),
            inject    => '0',
            output    => nodes(66)
        );

    -------------------------------------------------------------------
    -- Node 67: Komşular [97, 11, 94]
    -------------------------------------------------------------------
    node_67_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(97),
            inputs(1) => nodes(11),
            inputs(2) => nodes(94),
            inject    => plain_text(3),
            output    => nodes(67)
        );

    -------------------------------------------------------------------
    -- Node 68: Komşular [3, 8, 101]
    -------------------------------------------------------------------
    node_68_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(3),
            inputs(1) => nodes(8),
            inputs(2) => nodes(101),
            inject    => '0',
            output    => nodes(68)
        );

    -------------------------------------------------------------------
    -- Node 69: Komşular [3, 50, 7]
    -------------------------------------------------------------------
    node_69_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(3),
            inputs(1) => nodes(50),
            inputs(2) => nodes(7),
            inject    => '0',
            output    => nodes(69)
        );

    -------------------------------------------------------------------
    -- Node 70: Komşular [19, 79, 15]
    -------------------------------------------------------------------
    node_70_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(19),
            inputs(1) => nodes(79),
            inputs(2) => nodes(15),
            inject    => '0',
            output    => nodes(70)
        );

    -------------------------------------------------------------------
    -- Node 71: Komşular [29, 31, 55]
    -------------------------------------------------------------------
    node_71_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(29),
            inputs(1) => nodes(31),
            inputs(2) => nodes(55),
            inject    => '0',
            output    => nodes(71)
        );

    -------------------------------------------------------------------
    -- Node 72: Komşular [103, 113, 84]
    -------------------------------------------------------------------
    node_72_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(103),
            inputs(1) => nodes(113),
            inputs(2) => nodes(84),
            inject    => plain_text(0),
            output    => nodes(72)
        );

    -------------------------------------------------------------------
    -- Node 73: Komşular [25, 18, 57]
    -------------------------------------------------------------------
    node_73_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(25),
            inputs(1) => nodes(18),
            inputs(2) => nodes(57),
            inject    => '0',
            output    => nodes(73)
        );

    -------------------------------------------------------------------
    -- Node 74: Komşular [22, 92, 34]
    -------------------------------------------------------------------
    node_74_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(22),
            inputs(1) => nodes(92),
            inputs(2) => nodes(34),
            inject    => plain_text(2),
            output    => nodes(74)
        );

    -------------------------------------------------------------------
    -- Node 75: Komşular [83, 46, 93]
    -------------------------------------------------------------------
    node_75_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(83),
            inputs(1) => nodes(46),
            inputs(2) => nodes(93),
            inject    => '0',
            output    => nodes(75)
        );

    -------------------------------------------------------------------
    -- Node 76: Komşular [67, 81, 34]
    -------------------------------------------------------------------
    node_76_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(67),
            inputs(1) => nodes(81),
            inputs(2) => nodes(34),
            inject    => plain_text(4),
            output    => nodes(76)
        );

    -------------------------------------------------------------------
    -- Node 77: Komşular [68, 64, 81]
    -------------------------------------------------------------------
    node_77_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(68),
            inputs(1) => nodes(64),
            inputs(2) => nodes(81),
            inject    => '0',
            output    => nodes(77)
        );

    -------------------------------------------------------------------
    -- Node 78: Komşular [100, 76, 117]
    -------------------------------------------------------------------
    node_78_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(100),
            inputs(1) => nodes(76),
            inputs(2) => nodes(117),
            inject    => '0',
            output    => nodes(78)
        );

    -------------------------------------------------------------------
    -- Node 79: Komşular [54, 33, 15]
    -------------------------------------------------------------------
    node_79_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(54),
            inputs(1) => nodes(33),
            inputs(2) => nodes(15),
            inject    => plain_text(7),
            output    => nodes(79)
        );

    -------------------------------------------------------------------
    -- Node 80: Komşular [32, 104, 21]
    -------------------------------------------------------------------
    node_80_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(32),
            inputs(1) => nodes(104),
            inputs(2) => nodes(21),
            inject    => '0',
            output    => nodes(80)
        );

    -------------------------------------------------------------------
    -- Node 81: Komşular [3, 122, 94]
    -------------------------------------------------------------------
    node_81_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(3),
            inputs(1) => nodes(122),
            inputs(2) => nodes(94),
            inject    => plain_text(1),
            output    => nodes(81)
        );

    -------------------------------------------------------------------
    -- Node 82: Komşular [119, 109, 37]
    -------------------------------------------------------------------
    node_82_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(119),
            inputs(1) => nodes(109),
            inputs(2) => nodes(37),
            inject    => '0',
            output    => nodes(82)
        );

    -------------------------------------------------------------------
    -- Node 83: Komşular [17, 82, 42]
    -------------------------------------------------------------------
    node_83_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(17),
            inputs(1) => nodes(82),
            inputs(2) => nodes(42),
            inject    => '0',
            output    => nodes(83)
        );

    -------------------------------------------------------------------
    -- Node 84: Komşular [85, 75, 104]
    -------------------------------------------------------------------
    node_84_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(85),
            inputs(1) => nodes(75),
            inputs(2) => nodes(104),
            inject    => '0',
            output    => nodes(84)
        );

    -------------------------------------------------------------------
    -- Node 85: Komşular [121, 124, 66]
    -------------------------------------------------------------------
    node_85_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(121),
            inputs(1) => nodes(124),
            inputs(2) => nodes(66),
            inject    => '0',
            output    => nodes(85)
        );

    -------------------------------------------------------------------
    -- Node 86: Komşular [87, 26, 73]
    -------------------------------------------------------------------
    node_86_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(87),
            inputs(1) => nodes(26),
            inputs(2) => nodes(73),
            inject    => '0',
            output    => nodes(86)
        );

    -------------------------------------------------------------------
    -- Node 87: Komşular [72, 48, 126]
    -------------------------------------------------------------------
    node_87_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(72),
            inputs(1) => nodes(48),
            inputs(2) => nodes(126),
            inject    => '0',
            output    => nodes(87)
        );

    -------------------------------------------------------------------
    -- Node 88: Komşular [119, 70, 124]
    -------------------------------------------------------------------
    node_88_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(119),
            inputs(1) => nodes(70),
            inputs(2) => nodes(124),
            inject    => '0',
            output    => nodes(88)
        );

    -------------------------------------------------------------------
    -- Node 89: Komşular [50, 67, 49]
    -------------------------------------------------------------------
    node_89_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(50),
            inputs(1) => nodes(67),
            inputs(2) => nodes(49),
            inject    => '0',
            output    => nodes(89)
        );

    -------------------------------------------------------------------
    -- Node 90: Komşular [37, 6, 7]
    -------------------------------------------------------------------
    node_90_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(37),
            inputs(1) => nodes(6),
            inputs(2) => nodes(7),
            inject    => '0',
            output    => nodes(90)
        );

    -------------------------------------------------------------------
    -- Node 91: Komşular [45, 108, 15]
    -------------------------------------------------------------------
    node_91_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(45),
            inputs(1) => nodes(108),
            inputs(2) => nodes(15),
            inject    => '0',
            output    => nodes(91)
        );

    -------------------------------------------------------------------
    -- Node 92: Komşular [108, 32, 104]
    -------------------------------------------------------------------
    node_92_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(108),
            inputs(1) => nodes(32),
            inputs(2) => nodes(104),
            inject    => '0',
            output    => nodes(92)
        );

    -------------------------------------------------------------------
    -- Node 93: Komşular [84, 65, 52]
    -------------------------------------------------------------------
    node_93_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(84),
            inputs(1) => nodes(65),
            inputs(2) => nodes(52),
            inject    => '0',
            output    => nodes(93)
        );

    -------------------------------------------------------------------
    -- Node 94: Komşular [111, 114, 50]
    -------------------------------------------------------------------
    node_94_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(111),
            inputs(1) => nodes(114),
            inputs(2) => nodes(50),
            inject    => '0',
            output    => nodes(94)
        );

    -------------------------------------------------------------------
    -- Node 95: Komşular [36, 60, 79]
    -------------------------------------------------------------------
    node_95_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(36),
            inputs(1) => nodes(60),
            inputs(2) => nodes(79),
            inject    => '0',
            output    => nodes(95)
        );

    -------------------------------------------------------------------
    -- Node 96: Komşular [36, 105, 126]
    -------------------------------------------------------------------
    node_96_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(36),
            inputs(1) => nodes(105),
            inputs(2) => nodes(126),
            inject    => '0',
            output    => nodes(96)
        );

    -------------------------------------------------------------------
    -- Node 97: Komşular [67, 96, 27]
    -------------------------------------------------------------------
    node_97_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(67),
            inputs(1) => nodes(96),
            inputs(2) => nodes(27),
            inject    => '0',
            output    => nodes(97)
        );

    -------------------------------------------------------------------
    -- Node 98: Komşular [13, 17, 45]
    -------------------------------------------------------------------
    node_98_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(13),
            inputs(1) => nodes(17),
            inputs(2) => nodes(45),
            inject    => plain_text(2),
            output    => nodes(98)
        );

    -------------------------------------------------------------------
    -- Node 99: Komşular [29, 13, 52]
    -------------------------------------------------------------------
    node_99_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(29),
            inputs(1) => nodes(13),
            inputs(2) => nodes(52),
            inject    => '0',
            output    => nodes(99)
        );

    -------------------------------------------------------------------
    -- Node 100: Komşular [13, 47, 41]
    -------------------------------------------------------------------
    node_100_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(13),
            inputs(1) => nodes(47),
            inputs(2) => nodes(41),
            inject    => '0',
            output    => nodes(100)
        );

    -------------------------------------------------------------------
    -- Node 101: Komşular [107, 105, 56]
    -------------------------------------------------------------------
    node_101_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(107),
            inputs(1) => nodes(105),
            inputs(2) => nodes(56),
            inject    => '0',
            output    => nodes(101)
        );

    -------------------------------------------------------------------
    -- Node 102: Komşular [29, 42, 93]
    -------------------------------------------------------------------
    node_102_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(29),
            inputs(1) => nodes(42),
            inputs(2) => nodes(93),
            inject    => '0',
            output    => nodes(102)
        );

    -------------------------------------------------------------------
    -- Node 103: Komşular [51, 53, 2]
    -------------------------------------------------------------------
    node_103_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(51),
            inputs(1) => nodes(53),
            inputs(2) => nodes(2),
            inject    => plain_text(7),
            output    => nodes(103)
        );

    -------------------------------------------------------------------
    -- Node 104: Komşular [13, 73, 69]
    -------------------------------------------------------------------
    node_104_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(13),
            inputs(1) => nodes(73),
            inputs(2) => nodes(69),
            inject    => '0',
            output    => nodes(104)
        );

    -------------------------------------------------------------------
    -- Node 105: Komşular [67, 119, 20]
    -------------------------------------------------------------------
    node_105_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(67),
            inputs(1) => nodes(119),
            inputs(2) => nodes(20),
            inject    => '0',
            output    => nodes(105)
        );

    -------------------------------------------------------------------
    -- Node 106: Komşular [120, 12, 48]
    -------------------------------------------------------------------
    node_106_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(120),
            inputs(1) => nodes(12),
            inputs(2) => nodes(48),
            inject    => '0',
            output    => nodes(106)
        );

    -------------------------------------------------------------------
    -- Node 107: Komşular [9, 82, 90]
    -------------------------------------------------------------------
    node_107_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(9),
            inputs(1) => nodes(82),
            inputs(2) => nodes(90),
            inject    => '0',
            output    => nodes(107)
        );

    -------------------------------------------------------------------
    -- Node 108: Komşular [96, 111, 44]
    -------------------------------------------------------------------
    node_108_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(96),
            inputs(1) => nodes(111),
            inputs(2) => nodes(44),
            inject    => '0',
            output    => nodes(108)
        );

    -------------------------------------------------------------------
    -- Node 109: Komşular [81, 64, 83]
    -------------------------------------------------------------------
    node_109_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(81),
            inputs(1) => nodes(64),
            inputs(2) => nodes(83),
            inject    => '0',
            output    => nodes(109)
        );

    -------------------------------------------------------------------
    -- Node 110: Komşular [62, 71, 113]
    -------------------------------------------------------------------
    node_110_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(62),
            inputs(1) => nodes(71),
            inputs(2) => nodes(113),
            inject    => '0',
            output    => nodes(110)
        );

    -------------------------------------------------------------------
    -- Node 111: Komşular [41, 85, 43]
    -------------------------------------------------------------------
    node_111_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(41),
            inputs(1) => nodes(85),
            inputs(2) => nodes(43),
            inject    => plain_text(7),
            output    => nodes(111)
        );

    -------------------------------------------------------------------
    -- Node 112: Komşular [23, 74, 114]
    -------------------------------------------------------------------
    node_112_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(23),
            inputs(1) => nodes(74),
            inputs(2) => nodes(114),
            inject    => '0',
            output    => nodes(112)
        );

    -------------------------------------------------------------------
    -- Node 113: Komşular [13, 56, 110]
    -------------------------------------------------------------------
    node_113_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(13),
            inputs(1) => nodes(56),
            inputs(2) => nodes(110),
            inject    => '0',
            output    => nodes(113)
        );

    -------------------------------------------------------------------
    -- Node 114: Komşular [13, 63, 44]
    -------------------------------------------------------------------
    node_114_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(13),
            inputs(1) => nodes(63),
            inputs(2) => nodes(44),
            inject    => '0',
            output    => nodes(114)
        );

    -------------------------------------------------------------------
    -- Node 115: Komşular [98, 70, 7]
    -------------------------------------------------------------------
    node_115_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(98),
            inputs(1) => nodes(70),
            inputs(2) => nodes(7),
            inject    => '0',
            output    => nodes(115)
        );

    -------------------------------------------------------------------
    -- Node 116: Komşular [40, 84, 52]
    -------------------------------------------------------------------
    node_116_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(40),
            inputs(1) => nodes(84),
            inputs(2) => nodes(52),
            inject    => plain_text(4),
            output    => nodes(116)
        );

    -------------------------------------------------------------------
    -- Node 117: Komşular [41, 10, 72]
    -------------------------------------------------------------------
    node_117_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(41),
            inputs(1) => nodes(10),
            inputs(2) => nodes(72),
            inject    => '0',
            output    => nodes(117)
        );

    -------------------------------------------------------------------
    -- Node 118: Komşular [102, 111, 61]
    -------------------------------------------------------------------
    node_118_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(102),
            inputs(1) => nodes(111),
            inputs(2) => nodes(61),
            inject    => '0',
            output    => nodes(118)
        );

    -------------------------------------------------------------------
    -- Node 119: Komşular [34, 38, 110]
    -------------------------------------------------------------------
    node_119_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(34),
            inputs(1) => nodes(38),
            inputs(2) => nodes(110),
            inject    => '0',
            output    => nodes(119)
        );

    -------------------------------------------------------------------
    -- Node 120: Komşular [66, 65, 98]
    -------------------------------------------------------------------
    node_120_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(66),
            inputs(1) => nodes(65),
            inputs(2) => nodes(98),
            inject    => '0',
            output    => nodes(120)
        );

    -------------------------------------------------------------------
    -- Node 121: Komşular [5, 77, 56]
    -------------------------------------------------------------------
    node_121_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(5),
            inputs(1) => nodes(77),
            inputs(2) => nodes(56),
            inject    => '0',
            output    => nodes(121)
        );

    -------------------------------------------------------------------
    -- Node 122: Komşular [116, 58, 31]
    -------------------------------------------------------------------
    node_122_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(116),
            inputs(1) => nodes(58),
            inputs(2) => nodes(31),
            inject    => '0',
            output    => nodes(122)
        );

    -------------------------------------------------------------------
    -- Node 123: Komşular [78, 56, 24]
    -------------------------------------------------------------------
    node_123_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(78),
            inputs(1) => nodes(56),
            inputs(2) => nodes(24),
            inject    => '0',
            output    => nodes(123)
        );

    -------------------------------------------------------------------
    -- Node 124: Komşular [121, 87, 80]
    -------------------------------------------------------------------
    node_124_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(121),
            inputs(1) => nodes(87),
            inputs(2) => nodes(80),
            inject    => '0',
            output    => nodes(124)
        );

    -------------------------------------------------------------------
    -- Node 125: Komşular [46, 121, 98]
    -------------------------------------------------------------------
    node_125_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(46),
            inputs(1) => nodes(121),
            inputs(2) => nodes(98),
            inject    => plain_text(5),
            output    => nodes(125)
        );

    -------------------------------------------------------------------
    -- Node 126: Komşular [0, 55, 4]
    -------------------------------------------------------------------
    node_126_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(0),
            inputs(1) => nodes(55),
            inputs(2) => nodes(4),
            inject    => '0',
            output    => nodes(126)
        );

    -------------------------------------------------------------------
    -- Node 127: Komşular [114, 50, 22]
    -------------------------------------------------------------------
    node_127_inst : entity work.chaos_node
        port map (
            inputs(0) => nodes(114),
            inputs(1) => nodes(50),
            inputs(2) => nodes(22),
            inject    => '0',
            output    => nodes(127)
        );

    -------------------------------------------------------------------
    -- GÖZLEMCİ KATMANI (Readout Layer)
    -------------------------------------------------------------------
    -- Reservoir sürekli titreşir (clock-less chaos)
    -- Biz onu clock edge'de 'dondurarak' okuruz
    -- Bu snapshot → Ciphertext output
    -------------------------------------------------------------------
    readout_proc : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                cipher_text <= (others => '0');
            else
                -- Reservoir state'in ilk 128 bitini al
                cipher_text <= nodes(127 downto 0);
            end if;
        end if;
    end process;

end Behavioral;

--------------------------------------------------------------------------------
-- TASARIM NOTLARI
--------------------------------------------------------------------------------
-- 1. NETWORK TOPOLOGY
--    - Total nodes: 128
--    - Edges: 384 (directed)
--    - Average degree: 3
--    - Topology: Random (uniform)
--
-- 2. INPUT INJECTION
--    - Injected nodes: ~25
--    - Injection pattern: Mod-8 (cyclic)
--
-- 3. COMBINATORIAL LOOP
--    - Her node kendi input'unu (komşular üzerinden) etkiler
--    - Loop length: Variable (3 to 128 hops)
--    - Total loops: Exponential (hesaplanamaz)
--
-- 4. SENTEZ GEREKSİNİMLERİ
--    Vivado (.xdc):
--      set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets *nodes*]
--      set_property SEVERITY {WARNING} [get_drc_checks LUTLP-1]
--
--    Libero (.pdc):
--      set_attribute {*nodes*} syn_preserve 1
--
-- 5. SİMÜLASYON
--    - GHDL: 'after 100 ps' clause simülasyon için zorunlu
--    - Beklenen: nodes vektörü sürekli değişir (kaos!)
--    - Hata: nodes sabit kalır (0x0 veya 0xFF...)
--
-- 6. POWER ESTIMATE
--    - LUT toggle rate: ~1 GHz (chaos frequency)
--    - Total toggles: 128 nodes × 1 GHz = 128 Gtoggle/s
--    - Dynamic power: HIGH (sürekli aktivite)
--    - Cooling: Gerekebilir!
--
-- 7. KRİPTO UYGULAMASI
--    - Stream cipher olarak kullanılabilir
--    - Deterministik DEĞİL (PUF gibi)
--    - Standart dışı (NIST SP 800-90 uyumlu değil)
--
-- 8. YENİDEN ÜRETİM
--    - Aynı seed ile aynı ağ: RANDOM_SEED = 907053
--    - Farklı ağ: Script'i yeniden çalıştır (seed değişir)
--------------------------------------------------------------------------------
-- 🌊 KAOS OKYANUSUU ÜRETİLDİ! SEED = 907053 🌊
--------------------------------------------------------------------------------
