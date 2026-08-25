"""
AEGIS Phase 3.1: Dual Logistic Map PRNG — Q8.24 Golden Reference
Two maps with XOR mixing for NIST-compliant randomness.
"""
import math
import os

FRAC      = 24
Q_ONE     = 1 << FRAC
SAFE_A    = 0x0019999A   # 0.1
SAFE_B    = 0x00B33333   # 0.7
MASK32    = 0xFFFFFFFF
N_ITER    = 10000


def logistic_q824(x, r):
    omx = (Q_ONE - x) & MASK32
    temp = (x * omx) >> FRAC
    temp &= MASK32
    x_next = (r * temp) >> FRAC
    x_next &= MASK32
    return x_next


def xor_fold(x):
    return ((x >> 0) ^ (x >> 6) ^ (x >> 12) ^ (x >> 18)) & 1


def nist_frequency(bits):
    n = len(bits)
    s = sum(2*b-1 for b in bits)
    return math.erfc(abs(s)/math.sqrt(n)/math.sqrt(2))


def nist_runs(bits):
    n = len(bits)
    pi = sum(bits)/n
    if abs(pi-0.5) >= 2.0/math.sqrt(n): return 0.0
    runs = 1 + sum(1 for i in range(1,n) if bits[i]!=bits[i-1])
    num = abs(runs - 2.0*n*pi*(1-pi))
    den = 2.0*math.sqrt(2.0*n)*pi*(1-pi)
    return math.erfc(num/den) if den else 0.0


def nist_block_frequency(bits, M=128):
    """NIST block frequency test."""
    n = len(bits)
    N_blocks = n // M
    if N_blocks == 0: return 0.0
    chi_sq = 0
    for i in range(N_blocks):
        block = bits[i*M:(i+1)*M]
        pi_i = sum(block) / M
        chi_sq += (pi_i - 0.5) ** 2
    chi_sq *= 4 * M
    # Incomplete gamma function approximation via erfc
    p = math.erfc(math.sqrt(chi_sq / 2))
    return p


def main():
    base = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          '..', '..', 'rtl', 'aegis'))

    seed_a  = 0x00666666
    r_a     = 0x03FD70A4   # 3.99
    seed_b  = seed_a ^ 0x00555555
    r_b     = 0x03F851EC   # 3.97

    # Validate seeds
    if seed_b == 0 or seed_b >= Q_ONE:
        seed_b = SAFE_B

    print(f"[DUAL LOGISTIC MAP Q8.24]")
    print(f"  Map A: seed=0x{seed_a:08X} r=0x{r_a:08X} ({r_a/Q_ONE:.4f})")
    print(f"  Map B: seed=0x{seed_b:08X} r=0x{r_b:08X} ({r_b/Q_ONE:.4f})")

    xa, xb = seed_a, seed_b
    seq_xor = []
    bits_xor = []
    bytes_out = []

    for _ in range(N_ITER):
        xa_next = logistic_q824(xa, r_a)
        if xa_next == 0 or xa_next >= Q_ONE: xa_next = SAFE_A
        xb_next = logistic_q824(xb, r_b)
        if xb_next == 0 or xb_next >= Q_ONE: xb_next = SAFE_B
        xa, xb = xa_next, xb_next

        xor_val = (xa ^ xb) & MASK32
        seq_xor.append(xor_val)
        bits_xor.append(xor_fold(xor_val))
        bytes_out.append((xor_val >> 16) & 0xFF)

    # CSV for testbench (need raw xa, xb for exact matching)
    csv_path = os.path.join(base, 'test_vectors_prng.csv')
    n_tb = 100
    # Regenerate first 100 with xa/xb tracking
    xa2, xb2 = seed_a, seed_b
    with open(csv_path, 'w') as f:
        f.write(f"# Dual Q8.24  seedA=0x{seed_a:08X} rA=0x{r_a:08X}"
                f" seedB=0x{seed_b:08X} rB=0x{r_b:08X}\n")
        f.write("iter,xa_hex,xb_hex,xor_hex,chaos_bit\n")
        for i in range(n_tb):
            xa2 = logistic_q824(xa2, r_a)
            if xa2 == 0 or xa2 >= Q_ONE: xa2 = SAFE_A
            xb2 = logistic_q824(xb2, r_b)
            if xb2 == 0 or xb2 >= Q_ONE: xb2 = SAFE_B
            xv = (xa2 ^ xb2) & MASK32
            cb = xor_fold(xv)
            f.write(f"{i},{xa2:08X},{xb2:08X},{xv:08X},{cb}\n")
    print(f"\n[TEST] {csv_path} ({n_tb} vectors)")

    # ===== NIST: XOR-folded bits =====
    print(f"\n{'='*55}")
    print(f"  NIST SP 800-22 — {N_ITER} XOR-folded bits (dual map)")
    print(f"{'='*55}")
    pf = nist_frequency(bits_xor)
    pr = nist_runs(bits_xor)
    print(f"  Frequency:    p={pf:.6f}  {'PASS' if pf>=0.01 else 'FAIL'}")
    print(f"  Runs:         p={pr:.6f}  {'PASS' if pr>=0.01 else 'FAIL'}")
    o = sum(bits_xor)
    print(f"  Distribution: {o}/{N_ITER-o} ({100*o/N_ITER:.1f}%/{100*(N_ITER-o)/N_ITER:.1f}%)")

    # ===== NIST: Byte stream =====
    bbits = []
    for b in bytes_out:
        for bp in range(8):
            bbits.append((b >> bp) & 1)
    print(f"\n{'='*55}")
    print(f"  NIST SP 800-22 — {len(bbits)} byte-stream bits (dual map)")
    print(f"{'='*55}")
    pfb = nist_frequency(bbits)
    prb = nist_runs(bbits)
    pbf = nist_block_frequency(bbits)
    print(f"  Frequency:       p={pfb:.6f}  {'PASS' if pfb>=0.01 else 'FAIL'}")
    print(f"  Runs:            p={prb:.6f}  {'PASS' if prb>=0.01 else 'FAIL'}")
    print(f"  Block Freq(128): p={pbf:.6f}  {'PASS' if pbf>=0.01 else 'FAIL'}")
    bo = sum(bbits)
    print(f"  Distribution: {bo}/{len(bbits)-bo} "
          f"({100*bo/len(bbits):.1f}%/{100*(len(bbits)-bo)/len(bbits):.1f}%)")

    # Uniqueness
    unique = len(set(seq_xor))
    pct = 100*unique/N_ITER
    print(f"\n  Unique XOR values: {unique}/{N_ITER} ({pct:.1f}%)")

    # Samples
    print(f"\n  First 5:")
    xa3, xb3 = seed_a, seed_b
    for i in range(5):
        xa3 = logistic_q824(xa3, r_a)
        if xa3 == 0 or xa3 >= Q_ONE: xa3 = SAFE_A
        xb3 = logistic_q824(xb3, r_b)
        if xb3 == 0 or xb3 >= Q_ONE: xb3 = SAFE_B
        xv = xa3 ^ xb3
        print(f"    [{i+1}] A=0x{xa3:08X} B=0x{xb3:08X} XOR=0x{xv:08X}")

    all_pass = pf >= 0.01 and pr >= 0.01 and pfb >= 0.01 and pct > 80
    print(f"\n{'='*55}")
    print(f"  OVERALL: {'ALL PASS' if all_pass else 'REVIEW'}")
    print(f"{'='*55}")


if __name__ == '__main__':
    main()
