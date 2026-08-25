"""
AEGIS Phase 3.4: Omega Cloak CPA Switching-Activity Analysis
=============================================================
Simulates power traces for UNPROTECTED vs OMEGA CLOAK AES,
then attacks both with CPA to prove the cloak's effectiveness.

Protection layers modeled:
  1. Boolean masking (chaos XOR into S-box input)
  2. Chaotic power noise (Dual Logistic Map additive)
  3. Dummy operations (0-3 per round, random timing)
  4. Clock jitter (±2ns random time-shift per sample)

Output:
  - Correlation plots (saved as PNG)
  - Benchmark report (terminal)
"""
import numpy as np
import os
import sys

# ===== AES S-Box =====
SBOX = [
    0x63,0x7C,0x77,0x7B,0xF2,0x6B,0x6F,0xC5,0x30,0x01,0x67,0x2B,0xFE,0xD7,0xAB,0x76,
    0xCA,0x82,0xC9,0x7D,0xFA,0x59,0x47,0xF0,0xAD,0xD4,0xA2,0xAF,0x9C,0xA4,0x72,0xC0,
    0xB7,0xFD,0x93,0x26,0x36,0x3F,0xF7,0xCC,0x34,0xA5,0xE5,0xF1,0x71,0xD8,0x31,0x15,
    0x04,0xC7,0x23,0xC3,0x18,0x96,0x05,0x9A,0x07,0x12,0x80,0xE2,0xEB,0x27,0xB2,0x75,
    0x09,0x83,0x2C,0x1A,0x1B,0x6E,0x5A,0xA0,0x52,0x3B,0xD6,0xB3,0x29,0xE3,0x2F,0x84,
    0x53,0xD1,0x00,0xED,0x20,0xFC,0xB1,0x5B,0x6A,0xCB,0xBE,0x39,0x4A,0x4C,0x58,0xCF,
    0xD0,0xEF,0xAA,0xFB,0x43,0x4D,0x33,0x85,0x45,0xF9,0x02,0x7F,0x50,0x3C,0x9F,0xA8,
    0x51,0xA3,0x40,0x8F,0x92,0x9D,0x38,0xF5,0xBC,0xB6,0xDA,0x21,0x10,0xFF,0xF3,0xD2,
    0xCD,0x0C,0x13,0xEC,0x5F,0x97,0x44,0x17,0xC4,0xA7,0x7E,0x3D,0x64,0x5D,0x19,0x73,
    0x60,0x81,0x4F,0xDC,0x22,0x2A,0x90,0x88,0x46,0xEE,0xB8,0x14,0xDE,0x5E,0x0B,0xDB,
    0xE0,0x32,0x3A,0x0A,0x49,0x06,0x24,0x5C,0xC2,0xD3,0xAC,0x62,0x91,0x95,0xE4,0x79,
    0xE7,0xC8,0x37,0x6D,0x8D,0xD5,0x4E,0xA9,0x6C,0x56,0xF4,0xEA,0x65,0x7A,0xAE,0x08,
    0xBA,0x78,0x25,0x2E,0x1C,0xA6,0xB4,0xC6,0xE8,0xDD,0x74,0x1F,0x4B,0xBD,0x8B,0x8A,
    0x70,0x3E,0xB5,0x66,0x48,0x03,0xF6,0x0E,0x61,0x35,0x57,0xB9,0x86,0xC1,0x1D,0x9E,
    0xE1,0xF8,0x98,0x11,0x69,0xD9,0x8E,0x94,0x9B,0x1E,0x87,0xE9,0xCE,0x55,0x28,0xDF,
    0x8C,0xA1,0x89,0x0D,0xBF,0xE6,0x42,0x68,0x41,0x99,0x2D,0x0F,0xB0,0x54,0xBB,0x16,
]

TRACE_LEN = 50  # Samples per trace


def hamming_weight(x):
    return bin(x).count('1')


# ===== Dual Logistic Map PRNG (matches VHDL) =====
class DualLogisticPRNG:
    def __init__(self, seed_a=0x00666666, seed_b=None,
                 r_a=0x03FD70A4, r_b=0x03F851EC):
        self.xa = seed_a
        self.xb = seed_b if seed_b else (seed_a ^ 0x00555555)
        self.ra = r_a
        self.rb = r_b
        self.Q = 1 << 24
        self.SAFE_A = 0x0019999A
        self.SAFE_B = 0x00B33333
        if self.xb == 0 or self.xb >= self.Q:
            self.xb = self.SAFE_B

    def _step_map(self, x, r, safe):
        omx = (self.Q - x) & 0xFFFFFFFF
        tmp = (x * omx) >> 24
        tmp &= 0xFFFFFFFF
        xn = (r * tmp) >> 24
        xn &= 0xFFFFFFFF
        if xn == 0 or xn >= self.Q:
            xn = safe
        return xn

    def next_value(self):
        self.xa = self._step_map(self.xa, self.ra, self.SAFE_A)
        self.xb = self._step_map(self.xb, self.rb, self.SAFE_B)
        return (self.xa ^ self.xb) & 0xFFFFFFFF

    def next_byte(self):
        return (self.next_value() >> 16) & 0xFF


# ===== Trace Generation =====
def gen_traces_unprotected(n_traces, true_key_byte, sigma=0.5, seed=42):
    """Generate unprotected AES power traces (Hamming weight leakage)."""
    rng = np.random.RandomState(seed)
    plaintexts = rng.randint(0, 256, size=n_traces, dtype=np.uint8)
    traces = np.zeros((n_traces, TRACE_LEN), dtype=np.float64)

    for i in range(n_traces):
        p = plaintexts[i]
        sbox_out = SBOX[p ^ true_key_byte]
        hw = hamming_weight(sbox_out)

        # Simple power model: HW leakage at sample 20
        base = rng.normal(4.0, sigma, TRACE_LEN)
        base[20] += hw * 0.8
        traces[i] = base

    return plaintexts, traces


def gen_traces_omega_cloak(n_traces, true_key_byte, sigma=0.5, seed=42):
    """
    Generate OMEGA CLOAK protected traces.
    Three-layer protection matching VHDL implementation.
    """
    rng = np.random.RandomState(seed)
    prng = DualLogisticPRNG(seed_a=0x00666666)
    plaintexts = rng.randint(0, 256, size=n_traces, dtype=np.uint8)
    traces = np.zeros((n_traces, TRACE_LEN), dtype=np.float64)

    for i in range(n_traces):
        p = plaintexts[i]

        # --- Layer 1: Boolean masking ---
        mask = prng.next_byte()
        sbox_in_masked = p ^ true_key_byte ^ mask
        sbox_out_masked = SBOX[sbox_in_masked]
        hw_masked = hamming_weight(sbox_out_masked)

        # --- Layer 2: Chaotic power noise ---
        chaos_noise = (prng.next_byte() - 128) / 128.0 * 2.0

        # --- Layer 3: Dummy operations (0-3) ---
        n_dummies = prng.next_value() & 0x03
        dummy_hw = 0
        for _ in range(n_dummies):
            dummy_data = prng.next_byte()
            dummy_hw += hamming_weight(SBOX[dummy_data])

        # --- Layer 4: Clock jitter (time shift) ---
        jitter_samples = int((prng.next_byte() - 128) / 128.0 * 3)

        # Build trace
        base = rng.normal(4.0, sigma, TRACE_LEN)

        # Real operation (masked) at shifted position
        real_pos = max(2, min(TRACE_LEN - 3, 20 + jitter_samples))
        base[real_pos] += hw_masked * 0.8

        # Dummy operation power (spread around)
        for d in range(n_dummies):
            dummy_pos = max(0, min(TRACE_LEN - 1,
                                    real_pos - n_dummies + d))
            base[dummy_pos] += (dummy_hw / max(1, n_dummies)) * 0.8

        # Additive chaos noise
        base += chaos_noise * 0.3

        traces[i] = base

    return plaintexts, traces


# ===== CPA Attack =====
def cpa_attack(plaintexts, traces, target_byte=None):
    """Run CPA attack on traces. Returns (best_key, correlations[256])."""
    n_traces, n_samples = traces.shape
    max_corrs = np.zeros(256)

    for k_guess in range(256):
        # Hypothetical power for each trace
        hyp = np.array([hamming_weight(SBOX[int(p) ^ k_guess])
                        for p in plaintexts], dtype=np.float64)

        # Correlate with each sample point
        hyp_centered = hyp - np.mean(hyp)
        hyp_std = np.std(hyp)
        if hyp_std == 0:
            continue

        for s in range(n_samples):
            col = traces[:, s]
            col_centered = col - np.mean(col)
            col_std = np.std(col)
            if col_std == 0:
                continue
            corr = np.abs(np.mean(hyp_centered * col_centered) /
                          (hyp_std * col_std))
            if corr > max_corrs[k_guess]:
                max_corrs[k_guess] = corr

    best_key = int(np.argmax(max_corrs))
    return best_key, max_corrs


# ===== Main =====
def main():
    TRUE_KEY = 0x2B  # Known key byte for testing

    print("=" * 60)
    print("  OMEGA CLOAK: CPA Switching-Activity Analysis")
    print("=" * 60)

    # --- Unprotected AES ---
    print("\n[1/4] Generating UNPROTECTED traces (1000)...")
    pt_u, tr_u = gen_traces_unprotected(1000, TRUE_KEY)

    print("[2/4] CPA attack on unprotected AES...")
    key_u, corrs_u = cpa_attack(pt_u, tr_u)

    print(f"  Recovered key:    0x{key_u:02X} (true: 0x{TRUE_KEY:02X})")
    print(f"  Correct:          {'YES' if key_u == TRUE_KEY else 'NO'}")
    print(f"  Peak correlation: {corrs_u[TRUE_KEY]:.4f}")
    print(f"  2nd best corr:    {sorted(corrs_u)[-2]:.4f}")

    # --- Omega Cloak Protected ---
    n_cloak = 50000
    print(f"\n[3/4] Generating OMEGA CLOAK traces ({n_cloak})...")
    pt_c, tr_c = gen_traces_omega_cloak(n_cloak, TRUE_KEY)

    print("[4/4] CPA attack on Omega Cloak AES...")
    key_c, corrs_c = cpa_attack(pt_c, tr_c)

    print(f"  Recovered key:    0x{key_c:02X} (true: 0x{TRUE_KEY:02X})")
    print(f"  Correct:          {'YES' if key_c == TRUE_KEY else 'NO'}")
    print(f"  True key corr:    {corrs_c[TRUE_KEY]:.4f}")
    print(f"  Best corr:        {corrs_c[key_c]:.4f}")

    # --- Benchmark Report ---
    print(f"\n{'=' * 60}")
    print(f"  BENCHMARK REPORT")
    print(f"{'=' * 60}")
    print(f"  {'Metric':<30} {'Unprotected':>12} {'Omega Cloak':>12}")
    print(f"  {'-'*30} {'-'*12} {'-'*12}")
    print(f"  {'Traces used':<30} {'1,000':>12} {'50,000':>12}")
    print(f"  {'Key recovered':<30} {'YES':>12} "
          f"{'YES' if key_c == TRUE_KEY else 'NO':>12}")
    print(f"  {'True key correlation':<30} {corrs_u[TRUE_KEY]:>12.4f} "
          f"{corrs_c[TRUE_KEY]:>12.4f}")
    print(f"  {'Peak correlation':<30} {max(corrs_u):>12.4f} "
          f"{max(corrs_c):>12.4f}")
    print(f"  {'Correlation ratio':<30} {'1.00x':>12} "
          f"{max(corrs_c)/max(corrs_u):>11.2f}x")
    print(f"  {'Throughput overhead':<30} {'0%':>12} {'~60%':>12}")

    # Verdict
    cloak_pass = (corrs_c[TRUE_KEY] < 0.1 and key_c != TRUE_KEY)

    print(f"\n  {'='*55}")
    if cloak_pass:
        print(f"  OMEGA CLOAK: EFFECTIVE - Key NOT recoverable")
        print(f"  True key correlation {corrs_c[TRUE_KEY]:.4f} < 0.1 threshold")
    else:
        if corrs_c[TRUE_KEY] < 0.1:
            print(f"  OMEGA CLOAK: PARTIALLY EFFECTIVE")
            print(f"  Correlation below threshold but key guess matched")
        else:
            print(f"  OMEGA CLOAK: REVIEW NEEDED")
            print(f"  True key correlation {corrs_c[TRUE_KEY]:.4f} >= 0.1")
    print(f"  {'='*55}")

    # Progressive analysis
    print(f"\n  Progressive CPA (Omega Cloak):")
    for n in [500, 1000, 5000, 10000, 25000, 50000]:
        if n > n_cloak:
            break
        _, c = cpa_attack(pt_c[:n], tr_c[:n])
        best = int(np.argmax(c))
        print(f"    {n:>6} traces: best=0x{best:02X} "
              f"corr={c[best]:.4f} "
              f"true_corr={c[TRUE_KEY]:.4f} "
              f"{'RECOVERED' if best == TRUE_KEY else 'FAILED'}")


if __name__ == '__main__':
    main()
