#!/usr/bin/env python3
"""
TITAN V14 — NIST SP 800-90B Simplified Entropy Test Suite
Analyzes TRNG output captured from GHDL simulation.

Tests implemented:
  1. Monobit (Frequency) Test
  2. Runs Test
  3. Serial Correlation Test
  4. Chi-Square (Byte Distribution) Test
  5. Autocorrelation Test
  6. Min-Entropy Estimation

Usage: python nist_entropy_test.py [trng_output.txt]
Output: TRNG_ENTROPY_REPORT.md
"""

import sys
import os
import math
from collections import Counter
from datetime import datetime


def read_bits(filepath):
    """Read bit file (one bit per line: '0' or '1')."""
    bits = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line in ('0', '1'):
                bits.append(int(line))
    return bits


def monobit_test(bits):
    """NIST SP 800-90B: Frequency (Monobit) Test.
    Checks if the proportion of ones is approximately 0.5."""
    n = len(bits)
    ones = sum(bits)
    zeros = n - ones
    ratio = ones / n

    # Compute test statistic
    s_obs = abs(ones - zeros) / math.sqrt(n)

    # Approximate p-value using complementary error function
    p_value = math.erfc(s_obs / math.sqrt(2))

    passed = p_value > 0.01
    return {
        'test': 'Monobit (Frequency)',
        'ones': ones,
        'zeros': zeros,
        'ratio': ratio,
        's_obs': s_obs,
        'p_value': p_value,
        'passed': passed
    }


def runs_test(bits):
    """NIST SP 800-90B: Runs Test.
    Checks if the oscillation between 0s and 1s is as expected."""
    n = len(bits)
    ones = sum(bits)
    pi = ones / n

    # Pre-test: if monobit fails badly, skip runs
    if abs(pi - 0.5) > (2.0 / math.sqrt(n)):
        return {
            'test': 'Runs',
            'total_runs': 0,
            'expected_runs': 0,
            'p_value': 0.0,
            'passed': False,
            'note': 'Skipped (monobit prerequisite failed)'
        }

    # Count runs
    runs = 1
    for i in range(1, n):
        if bits[i] != bits[i-1]:
            runs += 1

    expected = 1 + 2 * ones * (n - ones) / n
    variance = (expected - 1) * (expected - 2) / (n - 1)
    if variance <= 0:
        variance = 1

    z = (runs - expected) / math.sqrt(variance)
    p_value = math.erfc(abs(z) / math.sqrt(2))

    return {
        'test': 'Runs',
        'total_runs': runs,
        'expected_runs': round(expected, 1),
        'z_score': round(z, 4),
        'p_value': p_value,
        'passed': p_value > 0.01
    }


def serial_correlation_test(bits, lag=1):
    """Serial Correlation Test.
    Checks if consecutive bits are independent."""
    n = len(bits) - lag
    if n <= 0:
        return {'test': 'Serial Correlation', 'passed': False, 'note': 'Not enough data'}

    mean = sum(bits) / len(bits)
    num = 0.0
    den = 0.0
    for i in range(n):
        num += (bits[i] - mean) * (bits[i + lag] - mean)
        den += (bits[i] - mean) ** 2

    if den == 0:
        correlation = 0.0
    else:
        correlation = num / den

    # For independent bits, correlation should be close to 0
    # Threshold: |r| < 2/sqrt(n)
    threshold = 2.0 / math.sqrt(n)
    passed = abs(correlation) < threshold

    return {
        'test': f'Serial Correlation (lag={lag})',
        'correlation': round(correlation, 6),
        'threshold': round(threshold, 6),
        'passed': passed
    }


def chi_square_byte_test(bits):
    """Chi-Square Test on byte distribution.
    Groups bits into bytes, checks if distribution is uniform."""
    n_bytes = len(bits) // 8
    if n_bytes < 256:
        return {'test': 'Chi-Square (Byte)', 'passed': False, 'note': 'Not enough data'}

    # Build bytes
    byte_counts = Counter()
    for i in range(n_bytes):
        byte_val = 0
        for j in range(8):
            byte_val = (byte_val << 1) | bits[i * 8 + j]
        byte_counts[byte_val] += 1

    # Chi-square statistic
    expected = n_bytes / 256.0
    chi2 = 0.0
    for val in range(256):
        observed = byte_counts.get(val, 0)
        chi2 += (observed - expected) ** 2 / expected

    # Degrees of freedom = 255
    # For df=255, critical value at alpha=0.01 is approximately 310
    # Simple p-value approximation using normal approximation to chi-square
    z = (chi2 - 255) / math.sqrt(2 * 255)
    p_value = math.erfc(abs(z) / math.sqrt(2)) if z > 0 else 1.0

    return {
        'test': 'Chi-Square (Byte Distribution)',
        'chi2': round(chi2, 2),
        'df': 255,
        'z_approx': round(z, 4),
        'p_value': round(p_value, 6),
        'unique_bytes': len(byte_counts),
        'passed': p_value > 0.01
    }


def autocorrelation_test(bits, max_lag=16):
    """Autocorrelation Test at multiple lags.
    Checks for periodic patterns in the bit stream."""
    n = len(bits)
    mean = sum(bits) / n
    results = []

    threshold = 2.0 / math.sqrt(n)

    for lag in range(1, max_lag + 1):
        num = 0.0
        den = 0.0
        for i in range(n - lag):
            num += (bits[i] - mean) * (bits[i + lag] - mean)
            den += (bits[i] - mean) ** 2

        if den == 0:
            r = 0.0
        else:
            r = num / den

        results.append({
            'lag': lag,
            'r': round(r, 6),
            'passed': abs(r) < threshold
        })

    all_passed = all(r['passed'] for r in results)
    max_corr = max(abs(r['r']) for r in results)

    return {
        'test': 'Autocorrelation (lag 1-16)',
        'max_abs_correlation': round(max_corr, 6),
        'threshold': round(threshold, 6),
        'all_passed': all_passed,
        'details': results,
        'passed': all_passed
    }


def min_entropy_estimate(bits):
    """Estimate min-entropy (H_min) of the bit source.
    H_min = -log2(max probability of any symbol)."""
    n = len(bits)
    ones = sum(bits)
    p_max = max(ones / n, (n - ones) / n)

    if p_max <= 0 or p_max >= 1:
        h_min = 0.0
    else:
        h_min = -math.log2(p_max)

    return {
        'test': 'Min-Entropy Estimate',
        'p_max': round(p_max, 6),
        'h_min': round(h_min, 6),
        'ideal': 1.0,
        'passed': h_min > 0.9  # At least 0.9 bits of entropy per sample
    }


def generate_report(results, n_bits, filepath, report_path):
    """Generate markdown report."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    lines = []
    lines.append("# TITAN V14 — TRNG Entropi Analiz Raporu")
    lines.append("")
    lines.append(f"**Tarih:** {timestamp}  ")
    lines.append(f"**Kaynak:** `{os.path.basename(filepath)}`  ")
    lines.append(f"**Toplam Bit:** {n_bits:,}  ")
    lines.append(f"**Standart:** NIST SP 800-90B (Basitleştirilmiş)")
    lines.append("")

    # Disclaimer
    lines.append("> [!NOTE]")
    lines.append("> Bu test GHDL simülasyonundan alınan veriler üzerinde yapılmıştır.")
    lines.append("> Simülasyondaki Ring Oscillator `after 1 ns` delay kullanır —")
    lines.append("> gerçek jitter değildir. Bu test, algoritmik modelin kalitesini ölçer.")
    lines.append("> Gerçek entropi değerlendirmesi donanım üzerinde yapılmalıdır.")
    lines.append("")
    lines.append("---")
    lines.append("")

    # Summary table
    lines.append("## Sonuç Özeti")
    lines.append("")
    lines.append("| # | Test | Sonuç | Detay |")
    lines.append("|---|------|-------|-------|")

    for i, r in enumerate(results, 1):
        status = "✅ PASS" if r['passed'] else "❌ FAIL"
        detail = ""
        if r['test'].startswith('Monobit'):
            detail = f"p={r['p_value']:.4f}, oran={r['ratio']:.4f}"
        elif r['test'] == 'Runs':
            if 'note' in r:
                detail = r['note']
            else:
                detail = f"p={r['p_value']:.4f}, runs={r['total_runs']}"
        elif r['test'].startswith('Serial'):
            detail = f"r={r['correlation']:.6f}, eşik={r['threshold']:.6f}"
        elif r['test'].startswith('Chi-Square'):
            detail = f"χ²={r.get('chi2', 'N/A')}, p={r.get('p_value', 'N/A')}"
        elif r['test'].startswith('Autocorrelation'):
            detail = f"max|r|={r['max_abs_correlation']:.6f}"
        elif r['test'].startswith('Min-Entropy'):
            detail = f"H_min={r['h_min']:.4f} bit/sample"

        lines.append(f"| {i} | {r['test']} | {status} | {detail} |")

    lines.append("")

    # Overall verdict
    all_pass = all(r['passed'] for r in results)
    total_pass = sum(1 for r in results if r['passed'])
    lines.append(f"**Genel Sonuç: {total_pass}/{len(results)} Test Başarılı**")
    if all_pass:
        lines.append("")
        lines.append("> [!TIP]")
        lines.append("> Tüm testler başarılı. TRNG simülasyon modeli istatistiksel olarak")
        lines.append("> kabul edilebilir rastgelelik üretiyor.")
    else:
        lines.append("")
        lines.append("> [!WARNING]")
        lines.append("> Bazı testler başarısız. Simülasyon modelinin entropi kalitesi")
        lines.append("> beklenenin altında. Gerçek donanımda farklı sonuçlar beklenir.")

    lines.append("")
    lines.append("---")
    lines.append("")

    # Detailed results
    lines.append("## Detaylı Sonuçlar")
    lines.append("")

    # Monobit
    m = results[0]
    lines.append("### 1. Monobit (Frekans) Testi")
    lines.append(f"- **Birler:** {m['ones']:,} ({m['ratio']*100:.2f}%)")
    lines.append(f"- **Sıfırlar:** {m['zeros']:,} ({(1-m['ratio'])*100:.2f}%)")
    lines.append(f"- **S_obs:** {m['s_obs']:.4f}")
    lines.append(f"- **p-value:** {m['p_value']:.6f}")
    lines.append("")

    # Autocorrelation details
    ac = results[4]
    lines.append("### 5. Otokorelasyon Detayları")
    lines.append("")
    lines.append("| Gecikme | r | Sonuç |")
    lines.append("|---------|---|-------|")
    for d in ac['details']:
        status = "✅" if d['passed'] else "❌"
        lines.append(f"| {d['lag']} | {d['r']:.6f} | {status} |")
    lines.append("")

    # Min-entropy
    me = results[5]
    lines.append("### 6. Min-Entropi Tahmini")
    lines.append(f"- **p_max:** {me['p_max']:.6f}")
    lines.append(f"- **H_min:** {me['h_min']:.4f} bit/sample (ideal: 1.0)")
    lines.append("")

    with open(report_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    return all_pass


def main():
    input_file = sys.argv[1] if len(sys.argv) > 1 else "trng_output.txt"
    report_file = "TRNG_ENTROPY_REPORT.md"

    if not os.path.exists(input_file):
        print(f"[ERROR] File not found: {input_file}")
        sys.exit(1)

    print(f"[INFO] Reading {input_file}...")
    bits = read_bits(input_file)
    n = len(bits)
    print(f"[INFO] Loaded {n:,} bits")

    if n < 1000:
        print("[ERROR] Not enough data for meaningful analysis (need >= 1000 bits)")
        sys.exit(1)

    print("[INFO] Running NIST SP 800-90B simplified tests...")
    results = []

    print("  [1/6] Monobit test...")
    results.append(monobit_test(bits))

    print("  [2/6] Runs test...")
    results.append(runs_test(bits))

    print("  [3/6] Serial correlation test...")
    results.append(serial_correlation_test(bits, lag=1))

    print("  [4/6] Chi-square byte test...")
    results.append(chi_square_byte_test(bits))

    print("  [5/6] Autocorrelation test (lag 1-16)...")
    results.append(autocorrelation_test(bits, max_lag=16))

    print("  [6/6] Min-entropy estimate...")
    results.append(min_entropy_estimate(bits))

    print(f"\n[INFO] Generating report: {report_file}")
    all_pass = generate_report(results, n, input_file, report_file)

    # Print summary
    print("\n" + "=" * 50)
    print("  TRNG ENTROPY TEST RESULTS")
    print("=" * 50)
    for r in results:
        status = "PASS" if r['passed'] else "FAIL"
        print(f"  [{status}] {r['test']}")
    total = sum(1 for r in results if r['passed'])
    print(f"\n  TOTAL: {total}/{len(results)} PASSED")
    print("=" * 50)

    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
