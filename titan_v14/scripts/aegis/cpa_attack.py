"""
================================================================================
AEGIS ENGINEERING - PHASE 1.4: CPA Attack Simulation
================================================================================
PURPOSE: Demonstrate Correlation Power Analysis (CPA) attack against an
         UNPROTECTED AES-256 core. This proves WHY Omega Cloak side-channel
         countermeasures are essential.

TARGET: AES-256 First Round SubBytes — recover key byte 0 from power traces.

THREAT MODEL:
  Attacker can:
    - Choose/observe plaintexts
    - Measure power consumption during encryption
    - Correlate hypothetical power with measurements
  
  Power Model: P = HammingWeight(S-box[plaintext[0] XOR key[0]]) + N(0,σ)

OUTPUTS:
  cpa_attack.py             - This file (complete implementation)
  cpa_correlation.png       - Correlation plot (correct key = peak)
  cpa_trace_analysis.png    - Traces-to-break vs noise level

SUCCESS CRITERIA:
  σ=0.5: Key recovered with ≤200 traces
  σ=1.0: Key recovered with ≤500 traces
  Correct key shows clear peak in correlation plot
================================================================================
"""

import numpy as np
import time
import os
import sys

# =========================================================================
# AES-256 S-BOX (FIPS 197, Table 4)
# =========================================================================
# This is the EXACT SubBytes transformation used in AES.
# Each byte value maps to a substitution via this table.
# The S-box provides confusion — non-linearity in the cipher.
# =========================================================================

AES_SBOX = [
    # 0     1     2     3     4     5     6     7     8     9     A     B     C     D     E     F
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,  # 0
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,  # 1
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,  # 2
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,  # 3
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,  # 4
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,  # 5
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,  # 6
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,  # 7
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,  # 8
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,  # 9
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,  # A
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,  # B
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,  # C
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,  # D
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,  # E
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,  # F
]


# =========================================================================
# CORE FUNCTIONS
# =========================================================================

def hamming_weight(x):
    """
    Compute Hamming Weight (number of 1-bits) of an 8-bit value.

    FPGA Reality: This directly corresponds to switching activity
    in CMOS logic gates. Each bit flip draws current from VDD,
    creating a measurable power signature.
    """
    return bin(x & 0xFF).count('1')


def generate_power_traces(n_traces, true_key_byte, sigma=0.5, seed=42):
    """
    Simulate power consumption during AES SubBytes.

    Model: P(i) = HW(S-box[plaintext[i] XOR key]) + N(0, sigma)

    This models CMOS dynamic power: P ∝ α * C * V² * f
    where α (switching activity) = Hamming Weight of the data.

    Parameters
    ----------
    n_traces : int
        Number of encryption traces to simulate.
    true_key_byte : int
        The secret key byte (0-255) we're attacking.
    sigma : float
        Gaussian noise standard deviation (measurement noise).
    seed : int
        Random seed for reproducibility.

    Returns
    -------
    plaintexts : ndarray of uint8 (n_traces,)
        Random plaintext byte 0 values.
    power_traces : ndarray of float (n_traces,)
        Simulated power measurements.
    """
    rng = np.random.default_rng(seed)

    # Random plaintext byte 0
    plaintexts = rng.integers(0, 256, size=n_traces, dtype=np.uint8)

    # True power: HW(S-box[pt XOR key])
    true_power = np.array([
        hamming_weight(AES_SBOX[int(pt) ^ true_key_byte])
        for pt in plaintexts
    ], dtype=np.float64)

    # Add Gaussian noise (measurement noise, electronic noise, etc.)
    noise = rng.normal(0, sigma, size=n_traces)
    power_traces = true_power + noise

    return plaintexts, power_traces


def cpa_attack(plaintexts, power_traces):
    """
    Correlation Power Analysis attack on AES-256 SubBytes.

    For each key hypothesis (0-255):
      1. Compute hypothetical power: HW(S-box[pt XOR key_guess])
      2. Compute Pearson correlation with actual power traces
      3. Key with highest |correlation| = recovered key

    Parameters
    ----------
    plaintexts : ndarray of uint8
        Known plaintext byte 0 values.
    power_traces : ndarray of float
        Measured power consumption values.

    Returns
    -------
    best_key : int
        Recovered key byte (0-255).
    correlations : ndarray of float (256,)
        Correlation values for all 256 key hypotheses.
    """
    n_traces = len(plaintexts)
    correlations = np.zeros(256)

    for key_guess in range(256):
        # Hypothetical power for this key guess
        hypothetical_power = np.array([
            hamming_weight(AES_SBOX[int(pt) ^ key_guess])
            for pt in plaintexts
        ], dtype=np.float64)

        # Pearson correlation
        corr_matrix = np.corrcoef(hypothetical_power, power_traces)
        correlations[key_guess] = corr_matrix[0, 1]

    best_key = int(np.argmax(np.abs(correlations)))
    return best_key, correlations


def progressive_attack(plaintexts, power_traces, true_key, step=10):
    """
    Run CPA with increasing number of traces to find break point.

    Returns the minimum number of traces needed to recover the key.

    Parameters
    ----------
    plaintexts, power_traces : ndarray
        Full trace set.
    true_key : int
        True key byte (for verification).
    step : int
        Step size for trace count sweep.

    Returns
    -------
    traces_to_break : int or None
        Minimum traces needed, or None if never found.
    history : list of (n_traces, recovered_key, max_corr)
        Attack history.
    """
    n_total = len(plaintexts)
    traces_to_break = None
    history = []

    for n in range(step, n_total + 1, step):
        recovered, corrs = cpa_attack(plaintexts[:n], power_traces[:n])
        max_corr = np.max(np.abs(corrs))
        history.append((n, recovered, max_corr))

        if recovered == true_key and traces_to_break is None:
            traces_to_break = n

    return traces_to_break, history


# =========================================================================
# MAIN BENCHMARK
# =========================================================================

def run_benchmark():
    """
    Full CPA attack demonstration.

    1. Generate simulated power traces
    2. Run CPA attack at different noise levels
    3. Find minimum traces to break
    4. Generate plots
    """
    print("=" * 60)
    print(" AEGIS PHASE 1.4: CPA Attack Simulation")
    print(" Target: AES-256 SubBytes (Key Byte 0)")
    print("=" * 60)

    # Secret key byte — attacker doesn't know this
    TRUE_KEY_BYTE = 0xAB  # 171 decimal
    print(f"\n[CONFIG] True key byte: 0x{TRUE_KEY_BYTE:02X} ({TRUE_KEY_BYTE})")

    # ===== Test 1: sigma=0.5 =====
    print("\n" + "-" * 60)
    print(" TEST 1: σ=0.5 (low noise)")
    print("-" * 60)

    pts_05, pwr_05 = generate_power_traces(1000, TRUE_KEY_BYTE, sigma=0.5)

    # Full attack with 200 traces
    t0 = time.time()
    key_200, corrs_200 = cpa_attack(pts_05[:200], pwr_05[:200])
    t1 = time.time()

    print(f"  200 traces: recovered=0x{key_200:02X}, "
          f"correct={'YES' if key_200 == TRUE_KEY_BYTE else 'NO'}, "
          f"time={t1-t0:.3f}s")
    print(f"  Max |corr|: {np.max(np.abs(corrs_200)):.4f}")

    # Progressive analysis
    ttb_05, hist_05 = progressive_attack(pts_05, pwr_05, TRUE_KEY_BYTE, step=10)
    print(f"  Traces to break: {ttb_05}")
    pass_05 = ttb_05 is not None and ttb_05 <= 200

    # ===== Test 2: sigma=1.0 =====
    print("\n" + "-" * 60)
    print(" TEST 2: σ=1.0 (moderate noise)")
    print("-" * 60)

    pts_10, pwr_10 = generate_power_traces(1000, TRUE_KEY_BYTE, sigma=1.0, seed=123)

    # Full attack with 500 traces
    key_500, corrs_500 = cpa_attack(pts_10[:500], pwr_10[:500])
    print(f"  500 traces: recovered=0x{key_500:02X}, "
          f"correct={'YES' if key_500 == TRUE_KEY_BYTE else 'NO'}")
    print(f"  Max |corr|: {np.max(np.abs(corrs_500)):.4f}")

    # Progressive analysis
    ttb_10, hist_10 = progressive_attack(pts_10, pwr_10, TRUE_KEY_BYTE, step=10)
    print(f"  Traces to break: {ttb_10}")
    pass_10 = ttb_10 is not None and ttb_10 <= 500

    # ===== Test 3: sigma=2.0 (high noise — shows attack difficulty) =====
    print("\n" + "-" * 60)
    print(" TEST 3: σ=2.0 (high noise)")
    print("-" * 60)

    pts_20, pwr_20 = generate_power_traces(1000, TRUE_KEY_BYTE, sigma=2.0, seed=456)
    key_1k, corrs_1k = cpa_attack(pts_20, pwr_20)
    print(f"  1000 traces: recovered=0x{key_1k:02X}, "
          f"correct={'YES' if key_1k == TRUE_KEY_BYTE else 'NO'}")

    ttb_20, hist_20 = progressive_attack(pts_20, pwr_20, TRUE_KEY_BYTE, step=20)
    print(f"  Traces to break: {ttb_20}")

    # ===== Results Summary =====
    print(f"\n{'=' * 60}")
    print(f" RESULTS SUMMARY")
    print(f"{'=' * 60}")
    print(f"  σ=0.5: {'PASS' if pass_05 else 'FAIL'} "
          f"(break at {ttb_05} traces, target ≤200)")
    print(f"  σ=1.0: {'PASS' if pass_10 else 'FAIL'} "
          f"(break at {ttb_10} traces, target ≤500)")
    print(f"  σ=2.0: break at {ttb_20} traces (informational)")

    if pass_05 and pass_10:
        print(f"\n  >>> ALL CRITERIA MET!")
        print(f"  >>> UNPROTECTED AES IS VULNERABLE TO CPA!")
        print(f"  >>> This justifies Omega Cloak countermeasures.")
    else:
        print(f"\n  >>> CRITERIA NOT FULLY MET")

    # ===== Plots =====
    print(f"\n[PLOT] Generating correlation plots...")
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt

        fig, axes = plt.subplots(2, 2, figsize=(14, 10))

        # ----- Plot 1: Correlation for all 256 key guesses (σ=0.5, 200 traces) -----
        ax = axes[0, 0]
        colors = ['#BBDEFB'] * 256
        colors[TRUE_KEY_BYTE] = '#F44336'
        bars = ax.bar(range(256), np.abs(corrs_200), color=colors, width=1.0)
        ax.axvline(x=TRUE_KEY_BYTE, color='#F44336', linewidth=2, linestyle='--',
                   alpha=0.8, label=f'True key: 0x{TRUE_KEY_BYTE:02X}')
        ax.set_title('CPA Correlation (σ=0.5, 200 traces)', fontsize=12,
                      fontweight='bold')
        ax.set_xlabel('Key Hypothesis')
        ax.set_ylabel('|Pearson Correlation|')
        ax.legend(fontsize=10)
        ax.grid(True, alpha=0.3)

        # ----- Plot 2: Correlation for σ=1.0, 500 traces -----
        ax = axes[0, 1]
        colors2 = ['#BBDEFB'] * 256
        colors2[TRUE_KEY_BYTE] = '#F44336'
        ax.bar(range(256), np.abs(corrs_500), color=colors2, width=1.0)
        ax.axvline(x=TRUE_KEY_BYTE, color='#F44336', linewidth=2, linestyle='--',
                   alpha=0.8, label=f'True key: 0x{TRUE_KEY_BYTE:02X}')
        ax.set_title('CPA Correlation (σ=1.0, 500 traces)', fontsize=12,
                      fontweight='bold')
        ax.set_xlabel('Key Hypothesis')
        ax.set_ylabel('|Pearson Correlation|')
        ax.legend(fontsize=10)
        ax.grid(True, alpha=0.3)

        # ----- Plot 3: Progressive attack (traces to break) -----
        ax = axes[1, 0]
        for label, hist, color, sigma in [
            ('σ=0.5', hist_05, '#4CAF50', 0.5),
            ('σ=1.0', hist_10, '#FF9800', 1.0),
            ('σ=2.0', hist_20, '#F44336', 2.0),
        ]:
            n_traces_arr = [h[0] for h in hist]
            correct_arr = [1 if h[1] == TRUE_KEY_BYTE else 0 for h in hist]
            ax.plot(n_traces_arr, correct_arr, color=color, linewidth=2,
                    label=label, alpha=0.8)
        ax.set_title('Key Recovery vs Number of Traces', fontsize=12,
                      fontweight='bold')
        ax.set_xlabel('Number of Traces')
        ax.set_ylabel('Correct Key (1=Yes, 0=No)')
        ax.legend(fontsize=10)
        ax.grid(True, alpha=0.3)
        ax.set_ylim(-0.1, 1.1)

        # ----- Plot 4: Correlation evolution -----
        ax = axes[1, 1]
        for label, hist, color in [
            ('σ=0.5', hist_05, '#4CAF50'),
            ('σ=1.0', hist_10, '#FF9800'),
            ('σ=2.0', hist_20, '#F44336'),
        ]:
            n_arr = [h[0] for h in hist]
            corr_arr = [h[2] for h in hist]
            ax.plot(n_arr, corr_arr, color=color, linewidth=2,
                    label=label, alpha=0.8)
        ax.set_title('Max Correlation vs Traces', fontsize=12, fontweight='bold')
        ax.set_xlabel('Number of Traces')
        ax.set_ylabel('Max |Correlation|')
        ax.legend(fontsize=10)
        ax.grid(True, alpha=0.3)

        plt.suptitle('AEGIS CPA Attack on Unprotected AES-256\n'
                      'Proof: Side-Channel Attack is TRIVIAL Without Countermeasures',
                      fontsize=14, fontweight='bold', y=1.02)
        plt.tight_layout()
        plt.savefig('cpa_correlation.png', dpi=150, bbox_inches='tight')
        print("[PLOT] Saved: cpa_correlation.png")
        plt.close()

    except ImportError:
        print("[WARNING] matplotlib not available")

    print(f"\n{'=' * 60}")
    print(f" PHASE 1.4 COMPLETE")
    print(f"{'=' * 60}")

    return pass_05, pass_10


# =========================================================================
# ENTRY POINT
# =========================================================================

if __name__ == '__main__':
    pass_05, pass_10 = run_benchmark()
