#!/usr/bin/env python3
"""
PROJECT OMEGA: Liquid Reservoir Generator
==========================================

AMAÇ: Rastgele bağlı kaotik bir VHDL ağı üretmek

KOMUTAN ŞERHİ: "Mühendisler VHDL yazmayacak, Python yazdıracak!"

FİZİKSEL MODEL:
  - N düğüm (chaos_node instance)
  - Her düğüm 3 rastgele komşuya bağlı
  - Small-World Network topology
  - Input injection: %20 düğüme plaintext damlatılır

KULLANIM:
  python generate_reservoir.py
  → rtl/omega/liquid_reservoir.vhdl oluşturulur

HER ÇALIŞTIRMADA FARKLI AĞ!
  - Rastgele seed → Benzersiz topoloji
  - Aynı kripto işlemci 2 kez üretilmez
  - Ultimate IP protection: Her müşteriye farklı donanım!

"""

import random
import os
from datetime import datetime

# =============================================================================
# CONFIGURATION
# =============================================================================
N_NODES = 128  # Okyanus büyüklüğü (Reservoir size)
CONNECTIONS_PER_NODE = 3  # Her düğümün komşu sayısı
INJECTION_RATIO = 0.2  # Input'un %20'si enjekte edilir
INPUT_WIDTH = 8  # Plaintext genişliği (8-bit char)
OUTPUT_WIDTH = 128  # Ciphertext genişliği (reservoir snapshot)

OUTPUT_DIR = "../rtl/omega"
FILENAME = "liquid_reservoir.vhd"

# Rastgele seed (reproducing istemiyorsak None yapılır)
RANDOM_SEED = random.randint(0, 999999)  # Her çalıştırmada farklı
# RANDOM_SEED = 42  # Sabit seed (debugging için)

# =============================================================================
# VHDL GENERATOR
# =============================================================================
def generate_vhdl():
    """Kaotik reservoir VHDL dosyasını üret"""
    
    # Seed'i ayarla
    random.seed(RANDOM_SEED)
    print(f"[INFO] Random seed: {RANDOM_SEED}")
    print(f"[INFO] Generating {N_NODES}-node reservoir...")
    
    # Output directory oluştur
    if not os.path.exists(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)
        print(f"[INFO] Created directory: {OUTPUT_DIR}")
    
    filepath = os.path.join(OUTPUT_DIR, FILENAME)
    
    with open(filepath, "w", encoding="utf-8") as f:
        # =====================================================================
        # HEADER
        # =====================================================================
        f.write("-" * 80 + "\n")
        f.write("-- PROJECT OMEGA: Liquid State Reservoir\n")
        f.write("-- OTOMATİK ÜRETİLMİŞ DOSYA - ELLE DEĞİŞTİRMEYİN!\n")
        f.write("-" * 80 + "\n")
        f.write(f"-- Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"-- Random Seed: {RANDOM_SEED}\n")
        f.write(f"-- Nodes: {N_NODES}\n")
        f.write(f"-- Connections per node: {CONNECTIONS_PER_NODE}\n")
        f.write(f"-- Injection ratio: {INJECTION_RATIO*100}%\n")
        f.write("--\n")
        f.write("-- ⚠️ UYARI: Bu dosya COMBINATORIAl LOOP içerir!\n")
        f.write("--   Vivado: set_property ALLOW_COMBINATORIAL_LOOPS TRUE\n")
        f.write("--\n")
        f.write("-- KAOS AĞI YAPISI:\n")
        f.write("--   Input Layer  → Plaintext injection\n")
        f.write("--   Reservoir    → Kaotik okyanus (clock-less)\n")
        f.write("--   Readout      → Sampling (clock-ed)\n")
        f.write("-" * 80 + "\n\n")
        
        f.write("library IEEE;\n")
        f.write("use IEEE.STD_LOGIC_1164.ALL;\n")
        f.write("use IEEE.NUMERIC_STD.ALL;\n\n")
        
        # =====================================================================
        # ENTITY
        # =====================================================================
        f.write("entity liquid_reservoir is\n")
        f.write("    port (\n")
        f.write("        -------------------------------------------------------------------\n")
        f.write("        -- Sampling Clock (Sadece readout için - reservoir clock-less!)\n")
        f.write("        -------------------------------------------------------------------\n")
        f.write("        clk         : in  std_logic;\n")
        f.write("        rst_n       : in  std_logic;\n")
        f.write("        \n")
        f.write("        -------------------------------------------------------------------\n")
        f.write("        -- Input (Plaintext damlatma)\n")
        f.write("        -------------------------------------------------------------------\n")
        f.write(f"        plain_text  : in  std_logic_vector({INPUT_WIDTH-1} downto 0);\n")
        f.write("        \n")
        f.write("        -------------------------------------------------------------------\n")
        f.write("        -- Output (Kaotik fırtınanın fotoğrafı)\n")
        f.write("        -------------------------------------------------------------------\n")
        f.write(f"        cipher_text : out std_logic_vector({OUTPUT_WIDTH-1} downto 0)\n")
        f.write("    );\n")
        f.write("end liquid_reservoir;\n\n")
        
        # =====================================================================
        # ARCHITECTURE
        # =====================================================================
        f.write("architecture Behavioral of liquid_reservoir is\n\n")
        
        # Internal signals
        f.write("    -------------------------------------------------------------------\n")
        f.write("    -- Reservoir State (Tüm düğümlerin anlık durumu)\n")
        f.write("    -------------------------------------------------------------------\n")
        f.write(f"    signal nodes : std_logic_vector({N_NODES-1} downto 0);\n\n")
        
        # Synthesis attributes
        f.write("    -------------------------------------------------------------------\n")
        f.write("    -- Sentez Koruma (Vivado/Libero)\n")
        f.write("    -------------------------------------------------------------------\n")
        f.write("    attribute keep : string;\n")
        f.write("    attribute keep of nodes : signal is \"true\";\n")
        f.write("    \n")
        f.write("    attribute dont_touch : string;\n")
        f.write("    attribute dont_touch of nodes : signal is \"true\";\n\n")
        
        f.write("begin\n\n")
        
        # =====================================================================
        # CHAOS NODE NETWORK (Reservoir Core)
        # =====================================================================
        f.write("    -------------------------------------------------------------------\n")
        f.write("    -- KAOS AĞI (Combinatorial Loop Network)\n")
        f.write("    -------------------------------------------------------------------\n")
        f.write("    -- Her düğüm rastgele 3 komşuya bağlı\n")
        f.write("    -- %20 düğüme plaintext bit'i enjekte edilir\n")
        f.write("    -------------------------------------------------------------------\n\n")
        
        # Düğümleri üret
        for i in range(N_NODES):
            # Rastgele 3 komşu seç (kendisi hariç)
            # Small-World Network için preferential attachment kullanılabilir
            # Şimdilik uniform random
            available_neighbors = [x for x in range(N_NODES) if x != i]
            neighbors = random.sample(available_neighbors, CONNECTIONS_PER_NODE)
            
            # Input injection (rastgele %20'sine)
            if random.random() < INJECTION_RATIO:
                inject_bit = i % INPUT_WIDTH  # Plaintext'in hangi biti
                inject_signal = f"plain_text({inject_bit})"
            else:
                inject_signal = "'0'"  # Injection yok
            
            # VHDL instance
            f.write(f"    -------------------------------------------------------------------\n")
            f.write(f"    -- Node {i}: Komşular [{neighbors[0]}, {neighbors[1]}, {neighbors[2]}]\n")
            f.write(f"    -------------------------------------------------------------------\n")
            f.write(f"    node_{i}_inst : entity work.chaos_node\n")
            f.write(f"        port map (\n")
            f.write(f"            inputs(0) => nodes({neighbors[0]}),\n")
            f.write(f"            inputs(1) => nodes({neighbors[1]}),\n")
            f.write(f"            inputs(2) => nodes({neighbors[2]}),\n")
            f.write(f"            inject    => {inject_signal},\n")
            f.write(f"            output    => nodes({i})\n")
            f.write(f"        );\n\n")
        
        # =====================================================================
        # READOUT LAYER (Sampling)
        # =====================================================================
        f.write("    -------------------------------------------------------------------\n")
        f.write("    -- GÖZLEMCİ KATMANI (Readout Layer)\n")
        f.write("    -------------------------------------------------------------------\n")
        f.write("    -- Reservoir sürekli titreşir (clock-less chaos)\n")
        f.write("    -- Biz onu clock edge'de 'dondurarak' okuruz\n")
        f.write("    -- Bu snapshot → Ciphertext output\n")
        f.write("    -------------------------------------------------------------------\n")
        f.write("    readout_proc : process(clk)\n")
        f.write("    begin\n")
        f.write("        if rising_edge(clk) then\n")
        f.write("            if rst_n = '0' then\n")
        f.write("                cipher_text <= (others => '0');\n")
        f.write("            else\n")
        f.write("                -- Reservoir state'in ilk 128 bitini al\n")
        f.write(f"                cipher_text <= nodes({OUTPUT_WIDTH-1} downto 0);\n")
        f.write("            end if;\n")
        f.write("        end if;\n")
        f.write("    end process;\n\n")
        
        f.write("end Behavioral;\n\n")
        
        # =====================================================================
        # FOOTER (Tasarım notları)
        # =====================================================================
        f.write("-" * 80 + "\n")
        f.write("-- TASARIM NOTLARI\n")
        f.write("-" * 80 + "\n")
        f.write("-- 1. NETWORK TOPOLOGY\n")
        f.write(f"--    - Total nodes: {N_NODES}\n")
        f.write(f"--    - Edges: {N_NODES * CONNECTIONS_PER_NODE} (directed)\n")
        f.write(f"--    - Average degree: {CONNECTIONS_PER_NODE}\n")
        f.write(f"--    - Topology: Random (uniform)\n")
        f.write("--\n")
        f.write("-- 2. INPUT INJECTION\n")
        f.write(f"--    - Injected nodes: ~{int(N_NODES * INJECTION_RATIO)}\n")
        f.write(f"--    - Injection pattern: Mod-{INPUT_WIDTH} (cyclic)\n")
        f.write("--\n")
        f.write("-- 3. COMBINATORIAL LOOP\n")
        f.write("--    - Her node kendi input'unu (komşular üzerinden) etkiler\n")
        f.write("--    - Loop length: Variable (3 to 128 hops)\n")
        f.write("--    - Total loops: Exponential (hesaplanamaz)\n")
        f.write("--\n")
        f.write("-- 4. SENTEZ GEREKSİNİMLERİ\n")
        f.write("--    Vivado (.xdc):\n")
        f.write("--      set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets *nodes*]\n")
        f.write("--      set_property SEVERITY {WARNING} [get_drc_checks LUTLP-1]\n")
        f.write("--\n")
        f.write("--    Libero (.pdc):\n")
        f.write("--      set_attribute {*nodes*} syn_preserve 1\n")
        f.write("--\n")
        f.write("-- 5. SİMÜLASYON\n")
        f.write("--    - GHDL: 'after 100 ps' clause simülasyon için zorunlu\n")
        f.write("--    - Beklenen: nodes vektörü sürekli değişir (kaos!)\n")
        f.write("--    - Hata: nodes sabit kalır (0x0 veya 0xFF...)\n")
        f.write("--\n")
        f.write("-- 6. POWER ESTIMATE\n")
        f.write(f"--    - LUT toggle rate: ~1 GHz (chaos frequency)\n")
        f.write(f"--    - Total toggles: {N_NODES} nodes × 1 GHz = {N_NODES} Gtoggle/s\n")
        f.write("--    - Dynamic power: HIGH (sürekli aktivite)\n")
        f.write("--    - Cooling: Gerekebilir!\n")
        f.write("--\n")
        f.write("-- 7. KRİPTO UYGULAMASI\n")
        f.write("--    - Stream cipher olarak kullanılabilir\n")
        f.write("--    - Deterministik DEĞİL (PUF gibi)\n")
        f.write("--    - Standart dışı (NIST SP 800-90 uyumlu değil)\n")
        f.write("--\n")
        f.write("-- 8. YENİDEN ÜRETİM\n")
        f.write(f"--    - Aynı seed ile aynı ağ: RANDOM_SEED = {RANDOM_SEED}\n")
        f.write("--    - Farklı ağ: Script'i yeniden çalıştır (seed değişir)\n")
        f.write("-" * 80 + "\n")
        f.write(f"-- 🌊 KAOS OKYANUSUU ÜRETİLDİ! SEED = {RANDOM_SEED} 🌊\n")
        f.write("-" * 80 + "\n")
    
    print(f"[SUCCESS] {filepath} created!")
    print(f"[INFO] Total nodes: {N_NODES}")
    print(f"[INFO] Total connections: {N_NODES * CONNECTIONS_PER_NODE}")
    print(f"[INFO] Injected nodes: ~{int(N_NODES * INJECTION_RATIO)}")
    print(f"[INFO] Random seed: {RANDOM_SEED} (for reproduction)")
    print("\n[NEXT STEP] Add to XDC:")
    print("  set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets -hierarchical \"*nodes*\"]")
    print("  set_property SEVERITY {WARNING} [get_drc_checks LUTLP-1]")

# =============================================================================
# MAIN
# =============================================================================
if __name__ == "__main__":
    print("=" * 80)
    print("PROJECT OMEGA: LIQUID RESERVOIR GENERATOR")
    print("=" * 80)
    generate_vhdl()
    print("=" * 80)
    print("🌊 DONE! Kaotik okyanus hazır. Simülasyona geç! 🌊")
    print("=" * 80)
