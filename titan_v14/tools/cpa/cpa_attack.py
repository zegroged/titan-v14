#!/usr/bin/env python3
"""
TITAN V14 -- CPA (Correlation Power Analysis) Attack Simulation
Attacks AES-256 key byte 0 using Hamming Weight leakage model.

Tests the effectiveness of masking countermeasures by correlating
hypothetical S-Box output HW with simulated power consumption.

Usage: python cpa_attack.py [power_traces.csv]
Output: CPA_ATTACK_REPORT.md
"""

import sys
import os
import math
import csv
from datetime import datetime

# AES S-Box
SBOX = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
]

CORRECT_KEY_BYTE = 0x2b  # First byte of ATTACK_KEY


def hamming_weight(val):
    """Count set bits."""
    return bin(val).count('1')


def pearson_correlation(x, y):
    """Compute Pearson correlation coefficient."""
    n = len(x)
    if n == 0:
        return 0.0

    mean_x = sum(x) / n
    mean_y = sum(y) / n

    num = sum((xi - mean_x) * (yi - mean_y) for xi, yi in zip(x, y))
    den_x = math.sqrt(sum((xi - mean_x) ** 2 for xi in x))
    den_y = math.sqrt(sum((yi - mean_y) ** 2 for yi in y))

    if den_x == 0 or den_y == 0:
        return 0.0

    return num / (den_x * den_y)


def add_gaussian_noise(values, sigma):
    """Add Gaussian noise to simulate measurement noise."""
    import random
    return [v + random.gauss(0, sigma) for v in values]


def run_cpa_attack(pt_bytes, power_traces, noise_sigma=0.0):
    """Run CPA attack on key byte 0.
    Returns correlation for each key guess (0..255)."""
    correlations = []

    # Add noise if specified
    if noise_sigma > 0.0:
        power_traces = add_gaussian_noise(power_traces, noise_sigma)

    for key_guess in range(256):
        # Hypothetical power model: HW(SBOX[PT ^ key_guess])
        hypothetical = []
        for pt in pt_bytes:
            sbox_out = SBOX[pt ^ key_guess]
            hypothetical.append(hamming_weight(sbox_out))

        # Correlate with actual power traces
        corr = pearson_correlation(hypothetical, power_traces)
        correlations.append(abs(corr))

    return correlations


def main():
    input_file = sys.argv[1] if len(sys.argv) > 1 else "power_traces.csv"
    script_dir = os.path.dirname(os.path.abspath(__file__))
    report_path = os.path.join(script_dir, "CPA_ATTACK_REPORT.md")

    if not os.path.exists(input_file):
        print(f"[ERROR] File not found: {input_file}")
        sys.exit(1)

    # Read traces
    print(f"[INFO] Reading {input_file}...")
    pt_bytes = []
    power_hw = []

    with open(input_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            pt_bytes.append(int(row['pt_byte']))
            power_hw.append(float(row['ct_byte0_hw']))

    n_traces = len(pt_bytes)
    print(f"[INFO] Loaded {n_traces} traces")

    # Run CPA with different noise levels
    noise_levels = [0.0, 0.5, 1.0, 2.0, 4.0]
    results = {}

    for sigma in noise_levels:
        label = f"sigma={sigma:.1f}"
        print(f"  [{label}] Running CPA attack...")
        corr = run_cpa_attack(pt_bytes, power_hw, sigma)

        best_guess = corr.index(max(corr))
        best_corr = max(corr)
        correct_corr = corr[CORRECT_KEY_BYTE]

        # Rank of correct key
        sorted_corr = sorted(enumerate(corr), key=lambda x: -x[1])
        correct_rank = next(i for i, (idx, _) in enumerate(sorted_corr) if idx == CORRECT_KEY_BYTE) + 1

        # SNR: ratio of correct key correlation to average of wrong keys
        wrong_corrs = [c for i, c in enumerate(corr) if i != CORRECT_KEY_BYTE]
        avg_wrong = sum(wrong_corrs) / len(wrong_corrs) if wrong_corrs else 0
        snr = correct_corr / avg_wrong if avg_wrong > 0 else float('inf')

        results[label] = {
            'sigma': sigma,
            'best_guess': best_guess,
            'best_guess_hex': f"0x{best_guess:02x}",
            'best_corr': best_corr,
            'correct_corr': correct_corr,
            'correct_rank': correct_rank,
            'snr': snr,
            'attack_success': best_guess == CORRECT_KEY_BYTE
        }

        status = "RECOVERED" if best_guess == CORRECT_KEY_BYTE else "DEFENDED"
        print(f"    Best guess: 0x{best_guess:02x} (correct: 0x{CORRECT_KEY_BYTE:02x}) "
              f"- {status} [rank={correct_rank}, SNR={snr:.2f}]")

    # Generate report
    print(f"\n[INFO] Generating report: {report_path}")
    generate_report(results, n_traces, report_path)
    print("[INFO] Done")


def generate_report(results, n_traces, report_path):
    """Generate CPA attack report."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    lines = []
    lines.append("# TITAN V14 -- CPA Saldiri Simulasyonu Raporu")
    lines.append("")
    lines.append(f"**Tarih:** {timestamp}  ")
    lines.append(f"**Hedef:** `aes256_core.vhd` (byte 0)  ")
    lines.append(f"**Trace Sayisi:** {n_traces}  ")
    lines.append(f"**Gercek Anahtar Byte 0:** `0x2b`  ")
    lines.append(f"**Sizinti Modeli:** Hamming Weight (S-Box cikisi)")
    lines.append("")

    lines.append("> [!NOTE]")
    lines.append("> Bu simulasyon GHDL ortaminda yapilmistir. Gercek donanumda")
    lines.append("> glitch-tabanli sizinti (glitch leakage) ek bir kanal olusturur")
    lines.append("> ve bu simulasyonda modellenemez. Donanim testi ayrica gereklidir.")
    lines.append("")
    lines.append("---")
    lines.append("")

    # Summary table
    lines.append("## Saldiri Sonuclari")
    lines.append("")
    lines.append("| Gurultu (sigma) | En Iyi Tahmin | Korelasyon | Dogru Key Sirasi | SNR | Sonuc |")
    lines.append("|-----------------|--------------|------------|-----------------|-----|-------|")

    for label, r in results.items():
        status = "KEY RECOVERED" if r['attack_success'] else "DEFENDED"
        emoji = "!!" if r['attack_success'] else "OK"
        lines.append(f"| {r['sigma']:.1f} | `{r['best_guess_hex']}` | "
                     f"{r['best_corr']:.4f} | {r['correct_rank']}/256 | "
                     f"{r['snr']:.2f} | {emoji} {status} |")

    lines.append("")

    # Analysis
    any_recovered = any(r['attack_success'] for r in results.values())
    no_noise_result = results.get('sigma=0.0', {})

    if any_recovered:
        lines.append("> [!WARNING]")
        lines.append("> CPA saldirisi bazi gurultu seviyelerinde anahtar byte'ini belirledi.")
        lines.append("> Maskeleme katmaninin guclendirmesi (2nd-order masking) onerili.")
    else:
        lines.append("> [!TIP]")
        lines.append("> CPA saldirisi hicbir gurultu seviyesinde basarili olamadi.")
        lines.append("> Maskeleme korumasi etkili calisiyor.")

    lines.append("")
    lines.append("---")
    lines.append("")

    # Masking effectiveness analysis
    lines.append("## Maskeleme Etkinlik Analizi")
    lines.append("")
    if no_noise_result:
        if no_noise_result['attack_success']:
            lines.append("### Gurultusuz Ortamda Anahtar Sizdi")
            lines.append("")
            lines.append("Sifir gurultu ile anahtar byte kurtarildi. Bu durum:")
            lines.append("- 1st-order maskelemenin yetersiz oldugunu gosterir")
            lines.append("- 2nd-order maskeleme (Faz 6) bu acigi kapatacaktir")
            lines.append("- Donanumda ek fiziksel gurultu koruma saglar")
        else:
            lines.append("### Gurultusuz Ortamda Bile Anahtar Korundu")
            lines.append("")
            lines.append("Sifir gurultu ile bile anahtar kurtarilamadi. Bu durum:")
            lines.append("- Maskeleme katmaninin etkili calistigini gosterir")
            lines.append("- Korelasyon dogru anahtarla bile dusuk")
    lines.append("")

    lines.append("## Sonraki Adim")
    lines.append("")
    lines.append("- Faz 6'da 2nd-order maskeleme uygulanacak")
    lines.append("- Donanim uzerinde oscilloscope ile gercek guc olcumu yapilmali")
    lines.append("- T-test (TVLA) ile sizinti noktasi haritalanmali")

    with open(report_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))


if __name__ == "__main__":
    main()
