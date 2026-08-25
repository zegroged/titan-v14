"""
Generate golden reference test vectors for shift_add_multiplier testbench.

Produces a CSV file with columns: a_hex, b_hex, expected_hex, overflow
using the EXACT same algorithm as the VHDL (shift-add, single right-shift).
"""
import sys
import numpy as np

def shift_add_multiply_golden(a_raw, b_raw, width=16, frac_bits=8):
    """
    Exact golden reference matching VHDL shift-add multiplier.
    
    Both inputs are signed 16-bit integers (Q8.8).
    Returns (result_raw, overflow).
    """
    # Determine sign
    a_signed = a_raw if a_raw < 32768 else a_raw - 65536
    b_signed = b_raw if b_raw < 32768 else b_raw - 65536
    
    result_sign = (a_signed < 0) != (b_signed < 0)
    
    a_mag = abs(a_signed)
    b_mag = abs(b_signed)
    
    # Shift-add accumulation (unsigned)
    acc = 0
    for bit in range(width):
        if (b_mag >> bit) & 1:
            acc += a_mag << bit
    
    # Apply sign
    if result_sign:
        acc = -acc
    
    # Right-shift by frac_bits
    # Python's >> on negative numbers does arithmetic shift
    if acc >= 0:
        acc = acc >> frac_bits
    else:
        # Match VHDL shift_right behavior for signed
        acc = -((-acc) >> frac_bits)
    
    # Saturation
    max_pos = (1 << (width - 1)) - 1   # 32767
    max_neg = -(1 << (width - 1))      # -32768
    
    overflow = 0
    if acc > max_pos:
        acc = max_pos
        overflow = 1
    elif acc < max_neg:
        acc = max_neg
        overflow = 1
    
    # Convert back to unsigned 16-bit representation
    if acc < 0:
        result_raw = acc + 65536
    else:
        result_raw = acc
    
    return result_raw, overflow


def main():
    rng = np.random.default_rng(42)
    
    n_tests = 1000
    
    # Generate test vectors
    vectors = []
    
    # Include edge cases first
    edge_cases = [
        (0x0000, 0x0000),  # 0 * 0
        (0x0100, 0x0100),  # 1.0 * 1.0
        (0xFF00, 0x0100),  # -1.0 * 1.0
        (0x0100, 0xFF00),  # 1.0 * -1.0
        (0xFF00, 0xFF00),  # -1.0 * -1.0
        (0x0200, 0x0300),  # 2.0 * 3.0
        (0x0080, 0x0080),  # 0.5 * 0.5
        (0x7FFF, 0x0100),  # max_pos * 1.0
        (0x8000, 0x0100),  # max_neg * 1.0
        (0x7FFF, 0x7FFF),  # max_pos * max_pos → overflow
        (0x8000, 0x8000),  # max_neg * max_neg → overflow
        (0x0001, 0x0001),  # smallest * smallest
        (0x0100, 0x0000),  # 1.0 * 0
        (0xFE00, 0x0200),  # -2.0 * 2.0
        (0x0180, 0x0180),  # 1.5 * 1.5
    ]
    
    for a, b in edge_cases:
        result, ovf = shift_add_multiply_golden(a, b)
        vectors.append((a, b, result, ovf))
    
    # Random vectors
    n_random = n_tests - len(edge_cases)
    for _ in range(n_random):
        a = int(rng.integers(0, 65536))
        b = int(rng.integers(0, 65536))
        result, ovf = shift_add_multiply_golden(a, b)
        vectors.append((a, b, result, ovf))
    
    # Write CSV
    with open('test_vectors_mul.csv', 'w') as f:
        f.write("a_hex,b_hex,expected_hex,overflow\n")
        for a, b, r, o in vectors:
            f.write(f"{a:04X},{b:04X},{r:04X},{o}\n")
    
    print(f"Generated {len(vectors)} test vectors -> test_vectors_mul.csv")
    
    # Quick validation
    n_overflow = sum(1 for _, _, _, o in vectors if o)
    print(f"  Edge cases: {len(edge_cases)}")
    print(f"  Random: {n_random}")
    print(f"  Overflow cases: {n_overflow}")
    
    # Verify some known values
    tests = [
        (0x0100, 0x0100, 0x0100, 0),   # 1.0 * 1.0 = 1.0
        (0xFF00, 0x0100, 0xFF00, 0),    # -1.0 * 1.0 = -1.0
        (0x0200, 0x0300, 0x0600, 0),    # 2.0 * 3.0 = 6.0
        (0x0080, 0x0080, 0x0040, 0),    # 0.5 * 0.5 = 0.25
    ]
    
    print("\n  Verification:")
    all_ok = True
    for a, b, exp, exp_ovf in tests:
        got, got_ovf = shift_add_multiply_golden(a, b)
        ok = (got == exp) and (got_ovf == exp_ovf)
        a_f = (a if a < 32768 else a - 65536) / 256
        b_f = (b if b < 32768 else b - 65536) / 256
        r_f = (got if got < 32768 else got - 65536) / 256
        status = "OK" if ok else "FAIL"
        print(f"    {a_f:>7.2f} * {b_f:>7.2f} = {r_f:>7.2f}  [{status}]")
        if not ok:
            all_ok = False
    
    if all_ok:
        print("  All verifications passed!")
    else:
        print("  ERROR: Some verifications failed!")
        sys.exit(1)


if __name__ == '__main__':
    main()
