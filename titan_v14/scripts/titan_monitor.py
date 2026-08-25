#!/usr/bin/env python3
"""
PROJECT TITAN V13: Ground Control Station
Module: UART Telemetry Monitor with Real-Time Dashboard

AMAÇ: Teknisyenin UART telemetri verilerini görselleştirmesi için terminal-based
      real-time dashboard.

KOMUTAN ŞERHİ: "Teknisyene 'PuTTY aç, hex oku' diyemeyiz. Ona bar grafik ver!"

KULLANIM:
    python titan_monitor.py COM3      # Windows
    python titan_monitor.py /dev/ttyUSB0  # Linux

REVİZYON 2: PLL LOCKED ve system_ready durumu da gösteriliyor.
"""

import serial
import time
import sys
import re

# ============================================================================
# CONFIGURATION
# ============================================================================
BAUD_RATE = 115200
TIMEOUT = 1.0  # seconds

# ============================================================================
# ANSI Color Codes
# ============================================================================
C_RESET = "\033[0m"
C_RED = "\033[91m"
C_GREEN = "\033[92m"
C_YELLOW = "\033[93m"
C_CYAN = "\033[96m"
C_BOLD = "\033[1m"

# ============================================================================
# Dashboard Rendering
# ============================================================================
def clear_line():
    """Terminal satırını temizle"""
    sys.stdout.write("\033[K")

def print_dashboard(xor_val, bucket, status, pll_locked=True, sys_ready=True):
    """
    Real-time dashboard güncelleme (same line)
    
    Args:
        xor_val: XOR değeri (0 veya 1)
        bucket: Bucket level (0-100%)
        status: Sistem durumu ("ARMED", "DANGER", "DEAD")
        pll_locked: PLL kilit durumu
        sys_ready: System ready durumu
    """
    # Bar graph oluştur
    bar_len = 20
    filled = int(bar_len * bucket // 100)
    bar = '█' * filled + '─' * (bar_len - filled)
    
    # Durum renklendir
    if status == "ARMED":
        stat_color = C_GREEN
    elif status == "DANGER":
        stat_color = C_YELLOW
    elif status == "DEAD":
        stat_color = C_RED
    else:
        stat_color = C_RESET
    
    # PLL ve System Ready göstergeleri
    pll_icon = C_GREEN + "🔒LOCK" + C_RESET if pll_locked else C_RED + "⚠ UNLOCK" + C_RESET
    sys_icon = C_GREEN + "✓RDY" + C_RESET if sys_ready else C_YELLOW + "⏳BOOT" + C_RESET
    
    # XOR değeri (crypto anahtar durumu)
    xor_icon = C_GREEN + "KEY_OK" + C_RESET if xor_val == 1 else C_RED + "KEY_LOST" + C_RESET
    
    # Dashboard çıktısı
    clear_line()
    output = (
        f"\r{C_BOLD}[TITAN_CTRL]{C_RESET} "
        f"PLL: {pll_icon} | "
        f"SYS: {sys_icon} | "
        f"XOR: {xor_icon} | "
        f"BUCKET: [{bar}] {bucket:3d}% | "
        f"{stat_color}STATUS: {status}{C_RESET}"
    )
    sys.stdout.write(output)
    sys.stdout.flush()

# ============================================================================
# UART Packet Parser
# ============================================================================
def parse_titan_packet(line):
    """
    UART'tan gelen [TITAN_SEC] paketini parse et
    
    Örnek:
        "[TITAN_SEC] | XOR_Val: 1 | Bucket_Lvl: 85% | Status: ARMED"
    
    Returns:
        dict: {'xor': 1, 'bucket': 85, 'status': 'ARMED'}
        None: Parse başarısız
    """
    try:
        # XOR değerini parse et
        xor_match = re.search(r'XOR_Val:\s*(\d)', line)
        xor_val = int(xor_match.group(1)) if xor_match else 0
        
        # Bucket level (şimdilik simülasyonda 0, gelecekte değişecek)
        bucket_match = re.search(r'Bucket_Lvl:\s*(\d+)%', line)
        bucket = int(bucket_match.group(1)) if bucket_match else 0
        
        # Status
        status_match = re.search(r'Status:\s*(ARMED|DANGER|DEAD)', line)
        status = status_match.group(1) if status_match else "UNKNOWN"
        
        return {
            'xor': xor_val,
            'bucket': bucket,
            'status': status
        }
    except Exception as e:
        return None

# ============================================================================
# Main Loop
# ============================================================================
def main():
    if len(sys.argv) < 2:
        print(f"{C_RED}HATA: COM port belirtilmedi!{C_RESET}")
        print(f"\nKullanım:")
        print(f"  {C_CYAN}python titan_monitor.py COM3{C_RESET}        # Windows")
        print(f"  {C_CYAN}python titan_monitor.py /dev/ttyUSB0{C_RESET}  # Linux/macOS")
        sys.exit(1)
    
    port = sys.argv[1]
    
    print(f"{C_BOLD}[TITAN Ground Control Station]{C_RESET}")
    print(f"Bağlanıyor: {C_CYAN}{port}{C_RESET} @ {BAUD_RATE} baud...")
    
    try:
        ser = serial.Serial(port, BAUD_RATE, timeout=TIMEOUT)
        print(f"{C_GREEN}✓ Bağlantı başarılı!{C_RESET}\n")
        
        # İlk dashboard (varsayılan değerler)
        print_dashboard(xor_val=1, bucket=0, status="BOOTING", pll_locked=False, sys_ready=False)
        
        while True:
            try:
                # UART'tan satır oku
                line = ser.readline().decode('utf-8', errors='ignore').strip()
                
                if line and "[TITAN_SEC]" in line:
                    # Paketi parse et
                    data = parse_titan_packet(line)
                    
                    if data:
                        # Dashboard'u güncelle
                        # NOT: PLL ve SYS durumu şimdilik sabit (donanım gelince değişecek)
                        print_dashboard(
                            xor_val=data['xor'],
                            bucket=data['bucket'],
                            status=data['status'],
                            pll_locked=True,   # Gelecekte UART'tan alınacak
                            sys_ready=True     # Gelecekte UART'tan alınacak
                        )
                
                time.sleep(0.01)  # CPU'yu boşa yormamak için
                
            except KeyboardInterrupt:
                print(f"\n\n{C_YELLOW}[CTRL+C] Kullanıcı tarafından sonlandırıldı.{C_RESET}")
                break
            except Exception as e:
                print(f"\n{C_RED}HATA: {e}{C_RESET}")
                time.sleep(1)
        
        ser.close()
        print(f"{C_GREEN}✓ Bağlantı kapatıldı.{C_RESET}")
        
    except serial.SerialException as e:
        print(f"{C_RED}✗ Seri port hatası: {e}{C_RESET}")
        print(f"\n{C_YELLOW}İpucu:{C_RESET}")
        print(f"  - Windows: Device Manager'dan COM port numarasını kontrol edin")
        print(f"  - Linux: 'ls /dev/ttyUSB*' veya 'ls /dev/ttyACM*' komutunu deneyin")
        print(f"  - USB kablo bağlantısını kontrol edin")
        sys.exit(1)

if __name__ == "__main__":
    main()

# ============================================================================
# TASARIM NOTLARI
# ============================================================================
# 1. GERÇEK ZAMANLI DASHBOARD
#    → Terminal'de aynı satır güncelleniyor (\r ile)
#    → GTK/Qt GUI yok (terminal yeterli - askeri simplicity)
#
# 2. ANSI COLOR CODES
#    → Linux/macOS: Destekleniyor
#    → Windows: Windows 10+ destekliyor (CMD/PowerShell)
#    → Eski sistemler: Renkler görmez ama çalışır
#
# 3. PLL VE SYSTEM READY
#    → Şu an sabit gösteriliyor (UART'ta bu bilgi yok)
#    → Gelecekte UART protokolüne eklenecek:
#      "[TITAN_SEC] | PLL: 1 | SYS: 1 | XOR_Val: 1 | ..."
#
# 4. BUCKET LEVEL
#    → Şu anda simülasyonda hep 0
#    → Gerçek donanımda module_external_tamper'dan gelecek
#
# 5. PACKET TIMEOUT
#    → Eğer 10 saniye mesaj gelmezse → "CONNECTION LOST" uyarısı (TODO)
#
# 6. CROSS-PLATFORM
#    → Windows: COM3, COM4, ...
#    → Linux: /dev/ttyUSB0, /dev/ttyACM0
#    → macOS: /dev/cu.usbserial-*
#
# 7. KULLANIM SENARYOSU
#    Teknisyen:
#      1. FPGA'yı USB-UART adaptörüyle PC'ye bağlar
#      2. `python titan_monitor.py COM3` çalıştırır
#      3. Real-time bar graph görür
#      4. Trimpot ayarlarken BUCKET değişimini izler
#      5. KILL tetiklendiğinde "KEY_LOST  " kırmızı görür
# ============================================================================
