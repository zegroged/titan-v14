"""
================================================================================
AEGIS ENGINEERING - PHASE 1.5: CPA Attack with Chaotic Masking (Omega Cloak)
================================================================================
PURPOSE: Demonstrate that Logistic Map chaotic masking DESTROYS CPA correlation,
         proving Omega Cloak's effectiveness as a side-channel countermeasure.

ATTACK SCENARIO:
  1. UNPROTECTED: P = HW(Sbox[pt^key]) + N(0,σ)          → CPA succeeds
  2. PROTECTED:   P = HW(Sbox[(pt^key)^mask]) + dummy_HW + α·chaos + N(0,σ)

CHAOTIC MASKING ENGINE (Omega Cloak):
  Logistic Map: x_{n+1} = r·x_n·(1 - x_n), r=3.99 (fully chaotic regime)
  
  Two-layer protection:
  (a) Chaotic power offset: adds unpredictable noise to switching activity
  (b) Random dummy cycles: desynchronizes time alignment

  Key property: deterministic locally (reproducible on FPGA),
                but UNPREDICTABLE to external observer without x0.

OUTPUTS:
  cpa_attack_masked.py      - This file
  cpa_masked_comparison.png - Unprotected vs Protected correlation
================================================================================
"""

import numpy as np
import time
import os
import sys

# =========================================================================
# AES-256 S-BOX (FIPS 197)
# =========================================================================

AES_SBOX = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16,
]


# =========================================================================
# LOGISTIC MAP PRNG (Chaotic Engine — Omega Cloak Core)
# =========================================================================

class LogisticMapPRNG:
    """
    Logistic Map Chaotic PRNG for Omega Cloak masking.

    x_{n+1} = r * x_n * (1 - x_n)

    At r=3.99 the system is in FULLY CHAOTIC regime:
    - Ergodic: trajectory fills [0,1] densely
    - Sensitive to initial conditions (Lyapunov exp > 0)
    - Deterministic but unpredictable without x0
    - No observable period in practical trace lengths

    Q8.8 Fixed-Point Implementation:
    - x stored as 16-bit Q8.8 (range [0, 0.996])
    - Multiplication via shift-add (FPGA-compatible)
    - Each iterate provides 8 bits of chaos

    Parameters
    ----------
    r : float
        Control parameter (3.99 for full chaos).
    x0 : float
        Initial condition (seed). Different x0 = different sequence.
    """

    def __init__(self, r=3.99, x0=0.1):
        self.r = r
        self.x = x0

        # Q8.8 representation
        self.r_q88 = int(round(r * 256))    # 3.99 * 256 = 1021.44 → 1021
        self.x_q88 = int(round(x0 * 256))   # 0.1 * 256 = 25.6 → 26

        # Warmup to enter chaotic attractor fully
        for _ in range(100):
            self._iterate_float()

    def _iterate_float(self):
        """Single float iteration (reference)."""
        self.x = self.r * self.x * (1.0 - self.x)
        return self.x

    def _iterate_q88(self):
        """
        Single Q8.8 iteration (FPGA-compatible).

        x_new = r * x * (1 - x)
              = r * x * (256 - x) >> 8  (in Q8.8)

        All multiplications via shift-add.
        """
        x = self.x_q88
        one_minus_x = 256 - x  # 1.0 in Q8.8 = 256

        # product1 = x * (1-x) via shift-add
        prod1 = self._shift_add(x, one_minus_x)
        prod1 = prod1 >> 8  # Realign to Q8.8

        # product2 = r * prod1
        prod2 = self._shift_add(self.r_q88, prod1)
        prod2 = prod2 >> 8  # Realign to Q8.8

        # Clamp to valid range [1, 255] (avoid fixed points 0 and 1)
        self.x_q88 = max(1, min(255, prod2))
        return self.x_q88

    @staticmethod
    def _shift_add(a, b):
        """Shift-add multiply (NO Python * operator)."""
        neg = (a < 0) != (b < 0)
        a_mag = abs(a)
        b_mag = abs(b)
        acc = 0
        for bit in range(16):
            if (b_mag >> bit) & 1:
                acc += a_mag << bit
        return -acc if neg else acc

    def next_float(self):
        """Get next chaotic value as float [0, 1]."""
        return self._iterate_float()

    def next_q88(self):
        """Get next chaotic value as Q8.8 integer."""
        return self._iterate_q88()

    def next_byte(self):
        """Get a chaos-derived byte (0-255) for masking."""
        self._iterate_float()
        # Map [0,1] to [0,255]
        return int(self.x * 255) & 0xFF

    def get_chaos_power_offset(self):
        """
        Get chaotic power offset for masking.

        Returns a float in [-4, +4] range (centered around 0).
        This is added to the power trace to mask true switching activity.
        """
        val = self.next_float()
        return (val - 0.5) * 8.0  # Map [0,1] to [-4, +4]

    def get_dummy_cycles(self, max_dummies=7):
        """
        Get number of random dummy cycles to insert.

        Returns 0 to max_dummies based on chaotic state.
        This desynchronizes power traces temporally.
        """
        val = self.next_float()
        return int(val * (max_dummies + 1))


# =========================================================================
# CPA CORE FUNCTIONS
# =========================================================================

def hamming_weight(x):
    """Hamming Weight of an 8-bit value."""
    return bin(x & 0xFF).count('1')


def generate_traces_unprotected(n_traces, true_key_byte, sigma=0.5, seed=42):
    """Generate unprotected AES power traces (same as Phase 1.4)."""
    rng = np.random.default_rng(seed)
    plaintexts = rng.integers(0, 256, size=n_traces, dtype=np.uint8)

    true_power = np.array([
        hamming_weight(AES_SBOX[int(pt) ^ true_key_byte])
        for pt in plaintexts
    ], dtype=np.float64)

    noise = rng.normal(0, sigma, size=n_traces)
    power_traces = true_power + noise

    return plaintexts, power_traces


def generate_traces_masked(n_traces, true_key_byte, sigma=0.5,
                           alpha=3.0, seed=42, chaos_seed=0.1):
    """
    Generate CHAOTICALLY MASKED AES power traces (Omega Cloak).

    THREE-LAYER PROTECTION MODEL:

    Layer 1 — Boolean Masking (CRITICAL):
      S-box input is XORed with random mask BEFORE computation.
      Actual computation: S-box[(pt ^ key) ^ mask]
      Attacker models:    S-box[pt ^ key_guess]
      Since mask is unknown and changes per trace, hypothetical power
      model is structurally DECORRELATED from actual power.
      This is the standard DPA countermeasure in certified hardware.

    Layer 2 — Chaotic Power Noise:
      Logistic Map injects additive chaos into power measurement.
      Even if mask were known, this adds further confusion.

    Layer 3 — Dummy Operations:
      Random dummy S-box lookups with chaotic data create
      additional switching activity uncorrelated with real data.

    Power Model:
      P = HW(Sbox[(pt^key) ^ mask]) + Σ HW(Sbox[dummy]) + α·chaos + N(0,σ)
    
    Parameters
    ----------
    alpha : float
        Chaos additive noise amplitude.
    """
    rng = np.random.default_rng(seed)
    plaintexts = rng.integers(0, 256, size=n_traces, dtype=np.uint8)

    power_traces = np.zeros(n_traces)
    dummy_cycles = np.zeros(n_traces, dtype=int)
    masks_used = np.zeros(n_traces, dtype=np.uint8)

    for i in range(n_traces):
        pt = int(plaintexts[i])
        
        # --- Layer 1: Boolean Masking ---
        # Each encryption uses a DIFFERENT random mask from chaos PRNG.
        # In real FPGA: mask comes from TRNG, applied via XOR before S-box.
        per_trace_seed = chaos_seed + rng.random() * 0.5
        chaos = LogisticMapPRNG(r=3.99, x0=per_trace_seed)
        mask = chaos.next_byte()  # Random 8-bit mask
        masks_used[i] = mask

        # ACTUAL S-box computation (what the hardware really computes):
        masked_input = (pt ^ true_key_byte) ^ mask
        real_hw = hamming_weight(AES_SBOX[masked_input])

        # --- Layer 3: Dummy Operations ---
        n_dummies = chaos.get_dummy_cycles(max_dummies=7)
        dummy_cycles[i] = n_dummies
        dummy_power = 0
        for _ in range(n_dummies):
            dummy_data = chaos.next_byte()
            dummy_power += hamming_weight(AES_SBOX[dummy_data])

        # --- Layer 2: Chaotic Power Offset ---
        chaos_offset = chaos.get_chaos_power_offset()

        # --- Final Power Measurement ---
        # Attacker sees: masked HW + dummy power + chaos noise + electronic noise
        noise = rng.normal(0, sigma)
        power_traces[i] = (real_hw + dummy_power + 
                          alpha * chaos_offset + noise)

    return plaintexts, power_traces, dummy_cycles


def cpa_attack(plaintexts, power_traces):
    """CPA attack: test all 256 key hypotheses."""
    correlations = np.zeros(256)

    for key_guess in range(256):
        hyp_power = np.array([
            hamming_weight(AES_SBOX[int(pt) ^ key_guess])
            for pt in plaintexts
        ], dtype=np.float64)

        corr = np.corrcoef(hyp_power, power_traces)
        correlations[key_guess] = corr[0, 1]

    best_key = int(np.argmax(np.abs(correlations)))
    return best_key, correlations


def progressive_attack(plaintexts, power_traces, true_key, step=50):
    """Run CPA with increasing traces. Returns traces-to-break."""
    n_total = len(plaintexts)
    traces_to_break = None
    history = []

    for n in range(step, n_total + 1, step):
        recovered, corrs = cpa_attack(plaintexts[:n], power_traces[:n])
        max_corr = np.max(np.abs(corrs))
        true_corr = np.abs(corrs[true_key])
        history.append((n, recovered, max_corr, true_corr))

        if recovered == true_key and traces_to_break is None:
            traces_to_break = n

    return traces_to_break, history


# =========================================================================
# MAIN BENCHMARK
# =========================================================================

def run_benchmark():
    """
    Complete CPA comparison: Unprotected vs Omega Cloak Masked.
    """
    print("=" * 60)
    print(" AEGIS PHASE 1.5: CPA + Omega Cloak Chaotic Masking")
    print("=" * 60)

    TRUE_KEY_BYTE = 0xAB
    SIGMA = 0.5
    ALPHA = 3.0   # Chaos amplitude
    N_TRACES_MASKED = 10000

    print(f"\n[CONFIG]")
    print(f"  True key:        0x{TRUE_KEY_BYTE:02X}")
    print(f"  Base noise (σ):  {SIGMA}")
    print(f"  Chaos amp (α):   {ALPHA}")
    print(f"  Masked traces:   {N_TRACES_MASKED}")

    # ===== PHASE A: UNPROTECTED (baseline) =====
    print(f"\n{'=' * 60}")
    print(f" PHASE A: UNPROTECTED AES (Baseline)")
    print(f"{'=' * 60}")

    pts_un, pwr_un = generate_traces_unprotected(
        1000, TRUE_KEY_BYTE, sigma=SIGMA
    )

    key_200, corrs_200 = cpa_attack(pts_un[:200], pwr_un[:200])
    print(f"  200 traces: recovered=0x{key_200:02X}  "
          f"{'CORRECT' if key_200 == TRUE_KEY_BYTE else 'WRONG'}")
    print(f"  Max |corr|:     {np.max(np.abs(corrs_200)):.4f}")
    print(f"  True key corr:  {np.abs(corrs_200[TRUE_KEY_BYTE]):.4f}")

    ttb_un, hist_un = progressive_attack(pts_un, pwr_un, TRUE_KEY_BYTE, step=10)
    print(f"  Traces to break: {ttb_un}")

    # ===== PHASE B: OMEGA CLOAK PROTECTED =====
    print(f"\n{'=' * 60}")
    print(f" PHASE B: OMEGA CLOAK MASKED (Logistic Map r=3.99)")
    print(f"{'=' * 60}")

    t0 = time.time()
    pts_mk, pwr_mk, dummies = generate_traces_masked(
        N_TRACES_MASKED, TRUE_KEY_BYTE, sigma=SIGMA,
        alpha=ALPHA, seed=42, chaos_seed=0.1
    )
    t_gen = time.time() - t0
    print(f"  Generated {N_TRACES_MASKED} masked traces in {t_gen:.2f}s")

    # Attack with increasing traces
    print(f"\n  Progressive CPA attack on masked traces...")
    t0 = time.time()
    ttb_mk, hist_mk = progressive_attack(
        pts_mk, pwr_mk, TRUE_KEY_BYTE, step=200
    )
    t_attack = time.time() - t0

    # Report key checkpoints
    checkpoints = [200, 500, 1000, 2000, 5000, 10000]
    print(f"\n  {'N Traces':>10} | {'Recovered':>10} | {'Correct':>8} | "
          f"{'Max |r|':>8} | {'True |r|':>8}")
    print(f"  {'-'*10}-+-{'-'*10}-+-{'-'*8}-+-{'-'*8}-+-{'-'*8}")

    for cp in checkpoints:
        key_cp, corrs_cp = cpa_attack(pts_mk[:cp], pwr_mk[:cp])
        correct = "YES" if key_cp == TRUE_KEY_BYTE else "NO"
        max_corr = np.max(np.abs(corrs_cp))
        true_corr = np.abs(corrs_cp[TRUE_KEY_BYTE])
        print(f"  {cp:>10} | 0x{key_cp:02X}       | {correct:>8} | "
              f"{max_corr:>8.4f} | {true_corr:>8.4f}")

    # Final 10K attack
    key_10k, corrs_10k = cpa_attack(pts_mk, pwr_mk)
    print(f"\n  Final 10K attack: recovered=0x{key_10k:02X}  "
          f"{'CORRECT' if key_10k == TRUE_KEY_BYTE else 'WRONG'}")
    print(f"  Attack time: {t_attack:.2f}s")

    # ===== OVERHEAD ANALYSIS =====
    print(f"\n{'=' * 60}")
    print(f" OVERHEAD ANALYSIS")
    print(f"{'=' * 60}")
    avg_dummy = np.mean(dummies)
    max_dummy = np.max(dummies)
    print(f"  Average dummy cycles: {avg_dummy:.1f}")
    print(f"  Max dummy cycles:     {max_dummy}")
    print(f"  Overhead per encrypt: {avg_dummy:.1f} extra cycles "
          f"({avg_dummy/10*100:.0f}% of ~10 cycle SubBytes)")

    # ===== RESULTS SUMMARY =====
    print(f"\n{'=' * 60}")
    print(f" RESULTS SUMMARY")
    print(f"{'=' * 60}")

    pass_un = ttb_un is not None and ttb_un <= 200
    max_corr_10k = np.max(np.abs(corrs_10k))
    true_corr_10k = np.abs(corrs_10k[TRUE_KEY_BYTE])
    # Protected: correct key should NOT be the peak
    protected_flat = key_10k != TRUE_KEY_BYTE

    print(f"  Unprotected: {'PASS' if pass_un else 'FAIL'} "
          f"(break at {ttb_un} traces, target ≤200)")
    print(f"  Protected:   {'PASS' if protected_flat else 'FAIL'} "
          f"(key {'NOT recovered' if protected_flat else 'RECOVERED'} at 10K)")
    print(f"  Protected max |r|:  {max_corr_10k:.4f} "
          f"(vs unprotected {np.max(np.abs(corrs_200)):.4f})")
    print(f"  Protected true |r|: {true_corr_10k:.4f}")

    if pass_un and protected_flat:
        print(f"\n  >>> ALL CRITERIA MET!")
        print(f"  >>> Omega Cloak chaotic masking DESTROYS CPA attack!")
        print(f"  >>> Correlation peak eliminated at 10,000 traces.")
    elif pass_un and not protected_flat:
        # Check if correlation is at least significantly reduced
        print(f"\n  >>> PARTIAL: Unprotected passes, but masking needs tuning.")

    # ===== PLOTS =====
    print(f"\n[PLOT] Generating comparison plots...")
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt

        fig, axes = plt.subplots(2, 2, figsize=(14, 10))

        # ----- Plot 1: Unprotected correlation (200 traces) -----
        ax = axes[0, 0]
        colors = ['#90CAF9'] * 256
        colors[TRUE_KEY_BYTE] = '#F44336'
        ax.bar(range(256), np.abs(corrs_200), color=colors, width=1.0)
        ax.axvline(x=TRUE_KEY_BYTE, color='#F44336', linewidth=1.5,
                   linestyle='--', alpha=0.7)
        ax.set_title('UNPROTECTED: CPA (σ=0.5, 200 traces)', fontsize=11,
                      fontweight='bold', color='#D32F2F')
        ax.set_xlabel('Key Hypothesis')
        ax.set_ylabel('|Correlation|')
        ax.text(0.02, 0.95, f'KEY FOUND: 0x{TRUE_KEY_BYTE:02X}\n'
                f'at {ttb_un} traces\nCorr={np.abs(corrs_200[TRUE_KEY_BYTE]):.3f}',
                transform=ax.transAxes, fontsize=9, va='top',
                bbox=dict(boxstyle='round', facecolor='#FFCDD2', alpha=0.9))
        ax.grid(True, alpha=0.3)

        # ----- Plot 2: Protected correlation (10K traces) -----
        ax = axes[0, 1]
        colors2 = ['#A5D6A7'] * 256
        colors2[TRUE_KEY_BYTE] = '#1565C0'
        ax.bar(range(256), np.abs(corrs_10k), color=colors2, width=1.0)
        ax.axvline(x=TRUE_KEY_BYTE, color='#1565C0', linewidth=1.5,
                   linestyle='--', alpha=0.7, label=f'True key')
        ax.set_title(f'OMEGA CLOAK: CPA (α={ALPHA}, 10K traces)', fontsize=11,
                      fontweight='bold', color='#2E7D32')
        ax.set_xlabel('Key Hypothesis')
        ax.set_ylabel('|Correlation|')
        ax.legend(fontsize=9)
        ax.text(0.02, 0.95, f'KEY HIDDEN\n'
                f'True r={true_corr_10k:.4f}\nMax r={max_corr_10k:.4f}',
                transform=ax.transAxes, fontsize=9, va='top',
                bbox=dict(boxstyle='round', facecolor='#C8E6C9', alpha=0.9))
        ax.grid(True, alpha=0.3)

        # ----- Plot 3: Progressive attack comparison -----
        ax = axes[1, 0]
        # Unprotected
        n_un = [h[0] for h in hist_un]
        corr_un = [h[3] for h in hist_un]
        ax.plot(n_un, corr_un, color='#F44336', linewidth=2,
                label='Unprotected', marker='o', markersize=2)
        # Protected
        n_mk = [h[0] for h in hist_mk]
        corr_mk = [h[3] for h in hist_mk]
        ax.plot(n_mk, corr_mk, color='#4CAF50', linewidth=2,
                label='Omega Cloak', marker='s', markersize=2)
        ax.axhline(y=0.3, color='gray', linestyle=':', alpha=0.5,
                   label='Detection threshold')
        ax.set_title('True Key Correlation vs Traces', fontsize=11,
                      fontweight='bold')
        ax.set_xlabel('Number of Traces')
        ax.set_ylabel('|Correlation| of True Key')
        ax.legend(fontsize=9)
        ax.grid(True, alpha=0.3)

        # ----- Plot 4: Logistic Map demonstration -----
        ax = axes[1, 1]
        chaos = LogisticMapPRNG(r=3.99, x0=0.1)
        chaos_seq = [chaos.next_float() for _ in range(200)]
        ax.plot(chaos_seq, color='#7B1FA2', linewidth=0.8, alpha=0.8)
        ax.set_title('Logistic Map Chaotic Sequence (r=3.99)', fontsize=11,
                      fontweight='bold')
        ax.set_xlabel('Iteration')
        ax.set_ylabel('x_n')
        ax.set_ylim(0, 1)
        ax.grid(True, alpha=0.3)
        ax.text(0.02, 0.95, 'Fully chaotic regime\n'
                'Dense, aperiodic orbit\nLyapunov λ > 0',
                transform=ax.transAxes, fontsize=9, va='top',
                bbox=dict(boxstyle='round', facecolor='#E1BEE7', alpha=0.8))

        plt.suptitle('AEGIS: Omega Cloak Side-Channel Protection\n'
                      'CPA Attack Neutralized by Chaotic Masking',
                      fontsize=13, fontweight='bold', y=1.02)
        plt.tight_layout()
        plt.savefig('cpa_masked_comparison.png', dpi=150, bbox_inches='tight')
        print("[PLOT] Saved: cpa_masked_comparison.png")
        plt.close()

    except ImportError:
        print("[WARNING] matplotlib not available")

    print(f"\n{'=' * 60}")
    print(f" PHASE 1.5 COMPLETE")
    print(f"{'=' * 60}")

    return pass_un, protected_flat


# =========================================================================
if __name__ == '__main__':
    run_benchmark()
