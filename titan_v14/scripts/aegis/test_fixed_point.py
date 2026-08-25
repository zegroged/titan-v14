"""
================================================================================
AEGIS ENGINEERING - PHASE 1.1: Fixed-Point Arithmetic Tests
================================================================================
PURPOSE: Validate fixed_point.py against float reference.

SUCCESS CRITERIA:
  1. float ↔ Q8.8 error < 2% for all basic operations
  2. Overflow/underflow saturation works correctly
  3. 1000 random multiplications: MSE < 0.01
  4. Sigmoid LUT accuracy acceptable
  5. Shift-add multiply matches Python * within quantization

RUN:
  cd titan_v13/scripts/aegis
  python test_fixed_point.py
================================================================================
"""

import sys
import random
import math

from fixed_point import FixedPoint, fp_array, fp_dot_product, fp_matrix_vector_multiply


# =========================================================================
# TEST UTILITIES
# =========================================================================

class TestResult:
    """Simple test result tracker."""

    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.errors = []

    def check(self, condition, name, detail=""):
        if condition:
            self.passed += 1
            print(f"  ✅ PASS: {name}")
        else:
            self.failed += 1
            self.errors.append(name)
            print(f"  ❌ FAIL: {name} — {detail}")

    def summary(self):
        total = self.passed + self.failed
        print(f"\n{'=' * 60}")
        print(f"RESULTS: {self.passed}/{total} passed, {self.failed} failed")
        if self.errors:
            print("FAILURES:")
            for e in self.errors:
                print(f"  - {e}")
        print(f"{'=' * 60}")
        return self.failed == 0


results = TestResult()


# =========================================================================
# TEST 1: Float ↔ Fixed Conversion
# =========================================================================

def test_conversion():
    print("\n" + "=" * 60)
    print("TEST 1: Float ↔ Fixed-Point Conversion")
    print("=" * 60)

    # Positive values
    test_values = [0.0, 1.0, 0.5, 0.25, 0.125, 3.14, 7.99, 100.0, 127.0]
    for v in test_values:
        fp = FixedPoint(v, 8, 8)
        back = fp.to_float()
        err = abs(v - back)
        # For values within range, error should be < 1/256 quantization + rounding
        if v <= 127.99:
            results.check(
                err < 0.01 or err / max(abs(v), 0.001) < 0.02,
                f"Convert {v} → Q8.8 → {back:.4f}",
                f"error={err:.6f}"
            )

    # Negative values
    neg_values = [-1.0, -0.5, -3.14, -50.0, -128.0]
    for v in neg_values:
        fp = FixedPoint(v, 8, 8)
        back = fp.to_float()
        err = abs(v - back)
        if abs(v) <= 128.0:
            results.check(
                err < 0.01 or err / max(abs(v), 0.001) < 0.02,
                f"Convert {v} → Q8.8 → {back:.4f}",
                f"error={err:.6f}"
            )

    # Two's complement check
    fp_neg = FixedPoint(-1.0, 8, 8)
    binary = fp_neg.to_binary()
    results.check(
        len(binary) == 16,
        f"Binary width: {len(binary)} bits",
        f"expected 16"
    )
    results.check(
        binary[0] == '1',
        f"Negative sign bit: MSB={binary[0]}",
        f"expected '1'"
    )

    # Zero
    fp_zero = FixedPoint(0.0, 8, 8)
    results.check(fp_zero.raw == 0, "Zero raw == 0")
    results.check(fp_zero.to_float() == 0.0, "Zero float == 0.0")


# =========================================================================
# TEST 2: Addition & Subtraction
# =========================================================================

def test_add_sub():
    print("\n" + "=" * 60)
    print("TEST 2: Addition & Subtraction")
    print("=" * 60)

    test_cases = [
        (1.0, 2.0, 3.0, "1+2=3"),
        (0.5, 0.25, 0.75, "0.5+0.25=0.75"),
        (3.14, 2.72, 5.86, "3.14+2.72≈5.86"),
        (-1.0, 1.0, 0.0, "-1+1=0"),
        (-3.5, -2.5, -6.0, "-3.5+(-2.5)=-6"),
        (100.0, 27.0, 127.0, "100+27=127"),
    ]

    for a_val, b_val, expected, name in test_cases:
        a = FixedPoint(a_val, 8, 8)
        b = FixedPoint(b_val, 8, 8)
        c = a.add(b)
        err = abs(c.to_float() - expected)
        results.check(
            err < 0.02 or err / max(abs(expected), 0.001) < 0.02,
            f"Add: {name} → {c.to_float():.4f}",
            f"expected={expected}, error={err:.6f}"
        )

    # Subtraction
    sub_cases = [
        (5.0, 3.0, 2.0, "5-3=2"),
        (1.0, 1.0, 0.0, "1-1=0"),
        (0.0, 1.0, -1.0, "0-1=-1"),
        (-2.0, 3.0, -5.0, "-2-3=-5"),
    ]

    for a_val, b_val, expected, name in sub_cases:
        a = FixedPoint(a_val, 8, 8)
        b = FixedPoint(b_val, 8, 8)
        c = a.sub(b)
        err = abs(c.to_float() - expected)
        results.check(
            err < 0.02,
            f"Sub: {name} → {c.to_float():.4f}",
            f"expected={expected}, error={err:.6f}"
        )


# =========================================================================
# TEST 3: Overflow / Underflow Saturation
# =========================================================================

def test_overflow():
    print("\n" + "=" * 60)
    print("TEST 3: Overflow / Underflow Saturation")
    print("=" * 60)

    # Q8.8 range: [-128.0, +127.99609375]
    max_val = (1 << 15) - 1  # 32767 → 127.996
    min_val = -(1 << 15)      # -32768 → -128.0

    # Overflow: 127 + 10 should saturate to ~127.99
    a = FixedPoint(127.0, 8, 8)
    b = FixedPoint(10.0, 8, 8)
    c = a.add(b)
    results.check(
        c.raw == max_val,
        f"Overflow saturation: 127+10 → raw={c.raw}",
        f"expected={max_val}"
    )

    # Underflow: -128 - 10 should saturate to -128
    a = FixedPoint(-120.0, 8, 8)
    b = FixedPoint(-20.0, 8, 8)
    c = a.add(b)
    results.check(
        c.raw == min_val,
        f"Underflow saturation: -120+(-20) → raw={c.raw}",
        f"expected={min_val}"
    )

    # Direct large value
    fp_big = FixedPoint(500.0, 8, 8)
    results.check(
        fp_big.raw == max_val,
        f"Direct overflow: 500 → raw={fp_big.raw}",
        f"expected saturate to {max_val}"
    )

    # Direct small value
    fp_small = FixedPoint(-500.0, 8, 8)
    results.check(
        fp_small.raw == min_val,
        f"Direct underflow: -500 → raw={fp_small.raw}",
        f"expected saturate to {min_val}"
    )

    # Wrap mode test
    fp_wrap = FixedPoint(130.0, 8, 8, overflow='wrap')
    results.check(
        fp_wrap.raw != max_val,
        f"Wrap mode: 130 → raw={fp_wrap.raw} (should wrap, not saturate)",
    )


# =========================================================================
# TEST 4: Shift-Add Multiplication
# =========================================================================

def test_multiply():
    print("\n" + "=" * 60)
    print("TEST 4: Shift-Add Multiplication")
    print("=" * 60)

    test_cases = [
        (2.0, 3.0, 6.0, "2×3=6"),
        (0.5, 4.0, 2.0, "0.5×4=2"),
        (1.5, 1.5, 2.25, "1.5×1.5=2.25"),
        (-2.0, 3.0, -6.0, "-2×3=-6"),
        (-1.5, -2.0, 3.0, "-1.5×-2=3"),
        (0.0, 100.0, 0.0, "0×100=0"),
        (1.0, 1.0, 1.0, "1×1=1"),
        (0.25, 0.25, 0.0625, "0.25×0.25=0.0625"),
        (10.0, 10.0, 100.0, "10×10=100"),
    ]

    for a_val, b_val, expected, name in test_cases:
        a = FixedPoint(a_val, 8, 8)
        b = FixedPoint(b_val, 8, 8)
        c = a.multiply(b)
        result = c.to_float()
        err = abs(result - expected)
        rel_err = err / max(abs(expected), 0.001) if expected != 0 else err
        results.check(
            rel_err < 0.02 or err < 0.02,
            f"Mul: {name} → {result:.4f}",
            f"expected={expected}, error={err:.6f} ({rel_err*100:.2f}%)"
        )


# =========================================================================
# TEST 5: 1000 Random Multiplications (MSE < 0.01)
# =========================================================================

def test_random_multiply():
    print("\n" + "=" * 60)
    print("TEST 5: 1000 Random Multiplications (MSE < 0.01)")
    print("=" * 60)

    random.seed(42)  # Reproducible!
    N = 1000
    squared_errors = []
    max_err = 0.0
    err_count = 0

    for i in range(N):
        # Random values in representable range (avoid overflow in product)
        a_val = random.uniform(-10.0, 10.0)
        b_val = random.uniform(-10.0, 10.0)

        a = FixedPoint(a_val, 8, 8)
        b = FixedPoint(b_val, 8, 8)
        c = a.multiply(b)

        # Float reference (using quantized inputs for fair comparison)
        a_quant = a.to_float()
        b_quant = b.to_float()
        expected = a_quant * b_quant

        # Clamp expected to Q8.8 range
        expected_clamped = max(-128.0, min(127.99609375, expected))

        result = c.to_float()
        err = (result - expected_clamped) ** 2
        squared_errors.append(err)

        abs_err = abs(result - expected_clamped)
        if abs_err > max_err:
            max_err = abs_err

        # Count large errors (> 5%)
        if abs(expected_clamped) > 0.1 and abs_err / abs(expected_clamped) > 0.05:
            err_count += 1

    mse = sum(squared_errors) / N
    rmse = math.sqrt(mse)

    print(f"  MSE: {mse:.6f}")
    print(f"  RMSE: {rmse:.6f}")
    print(f"  Max absolute error: {max_err:.6f}")
    print(f"  Large error count (>5%): {err_count}/{N}")

    results.check(mse < 0.01, f"MSE = {mse:.6f} < 0.01", f"MSE={mse:.6f}")
    results.check(
        err_count < N * 0.05,
        f"Large errors: {err_count} < {N * 0.05:.0f} (5%)",
    )


# =========================================================================
# TEST 6: ReLU Activation
# =========================================================================

def test_relu():
    print("\n" + "=" * 60)
    print("TEST 6: ReLU Activation")
    print("=" * 60)

    # Positive: unchanged
    for v in [0.0, 0.5, 1.0, 3.14, 100.0]:
        fp = FixedPoint(v, 8, 8)
        r = fp.relu()
        results.check(
            r.raw == fp.raw,
            f"ReLU({v}) = {r.to_float():.4f} (unchanged)",
        )

    # Negative: zero
    for v in [-0.5, -1.0, -3.14, -100.0]:
        fp = FixedPoint(v, 8, 8)
        r = fp.relu()
        results.check(
            r.raw == 0,
            f"ReLU({v}) = {r.to_float():.4f} (zero)",
        )


# =========================================================================
# TEST 7: Sigmoid LUT
# =========================================================================

def test_sigmoid():
    print("\n" + "=" * 60)
    print("TEST 7: Sigmoid LUT Approximation")
    print("=" * 60)

    test_values = [
        (0.0, 0.5),
        (1.0, 0.7311),
        (-1.0, 0.2689),
        (3.0, 0.9526),
        (-3.0, 0.0474),
        (8.0, 0.9997),
        (-8.0, 0.0003),
    ]

    for x_val, expected in test_values:
        fp = FixedPoint(x_val, 8, 8)
        sig = fp.sigmoid()
        result = sig.to_float()
        err = abs(result - expected)
        # LUT approximation: allow more error (quantized input + output)
        results.check(
            err < 0.05,
            f"sigmoid({x_val}) = {result:.4f} (expected {expected:.4f})",
            f"error={err:.4f}"
        )

    # Boundary: very negative → near 0
    fp_neg = FixedPoint(-10.0, 8, 8)
    sig_neg = fp_neg.sigmoid()
    results.check(
        sig_neg.to_float() < 0.01,
        f"sigmoid(-10) = {sig_neg.to_float():.4f} ≈ 0",
    )

    # Boundary: very positive → near 1
    fp_pos = FixedPoint(10.0, 8, 8)
    sig_pos = fp_pos.sigmoid()
    results.check(
        sig_pos.to_float() > 0.99,
        f"sigmoid(10) = {sig_pos.to_float():.4f} ≈ 1",
    )


# =========================================================================
# TEST 8: Q16.16 Format
# =========================================================================

def test_q16_16():
    print("\n" + "=" * 60)
    print("TEST 8: Q16.16 Format (Extended Precision)")
    print("=" * 60)

    # Higher precision
    a = FixedPoint(3.14159, 16, 16)
    back = a.to_float()
    err = abs(back - 3.14159)
    results.check(
        err < 0.0001,
        f"Q16.16 precision: 3.14159 → {back:.6f}",
        f"error={err:.8f}"
    )

    # Larger range
    big = FixedPoint(30000.0, 16, 16)
    results.check(
        abs(big.to_float() - 30000.0) < 0.001,
        f"Q16.16 range: 30000.0 → {big.to_float():.2f}",
    )

    # Multiply precision
    a = FixedPoint(1.41421, 16, 16)
    b = FixedPoint(1.41421, 16, 16)
    c = a.multiply(b)
    expected = 1.41421 * 1.41421  # ~2.0
    err = abs(c.to_float() - expected)
    results.check(
        err < 0.01,
        f"Q16.16 mul: √2 × √2 ≈ {c.to_float():.6f} (expected ~2.0)",
        f"error={err:.6f}"
    )


# =========================================================================
# TEST 9: Dot Product & Matrix-Vector
# =========================================================================

def test_linear_algebra():
    print("\n" + "=" * 60)
    print("TEST 9: Dot Product & Matrix-Vector Multiply")
    print("=" * 60)

    # Dot product: [1, 2, 3] · [4, 5, 6] = 4+10+18 = 32
    a = fp_array([1.0, 2.0, 3.0])
    b = fp_array([4.0, 5.0, 6.0])
    dot = fp_dot_product(a, b)
    results.check(
        abs(dot.to_float() - 32.0) < 0.5,
        f"Dot product: [1,2,3]·[4,5,6] = {dot.to_float():.2f} (expected 32)",
    )

    # Matrix-vector: [[1,0],[0,1]] × [3,5] = [3,5]
    identity = [fp_array([1.0, 0.0]), fp_array([0.0, 1.0])]
    vec = fp_array([3.0, 5.0])
    result = fp_matrix_vector_multiply(identity, vec)
    results.check(
        abs(result[0].to_float() - 3.0) < 0.1
        and abs(result[1].to_float() - 5.0) < 0.1,
        f"Identity × [3,5] = [{result[0].to_float():.2f}, {result[1].to_float():.2f}]",
    )

    # Non-trivial: [[2,1],[1,3]] × [1,2] = [4, 7]
    mat = [fp_array([2.0, 1.0]), fp_array([1.0, 3.0])]
    vec = fp_array([1.0, 2.0])
    result = fp_matrix_vector_multiply(mat, vec)
    results.check(
        abs(result[0].to_float() - 4.0) < 0.1
        and abs(result[1].to_float() - 7.0) < 0.1,
        f"[[2,1],[1,3]] × [1,2] = [{result[0].to_float():.2f}, {result[1].to_float():.2f}]",
    )


# =========================================================================
# TEST 10: Binary & Hex Representation
# =========================================================================

def test_representation():
    print("\n" + "=" * 60)
    print("TEST 10: Binary & Hex Representation")
    print("=" * 60)

    # 1.0 in Q8.8 = 256 = 0x0100
    fp_one = FixedPoint(1.0, 8, 8)
    results.check(fp_one.raw == 256, f"1.0 raw = {fp_one.raw} (expected 256)")
    results.check(
        fp_one.to_hex() == '0x100',
        f"1.0 hex = {fp_one.to_hex()} (expected 0x100)",
    )

    # 0.5 in Q8.8 = 128 = 0x0080
    fp_half = FixedPoint(0.5, 8, 8)
    results.check(fp_half.raw == 128, f"0.5 raw = {fp_half.raw} (expected 128)")

    # -1.0 in Q8.8 two's complement = 0xFF00
    fp_neg = FixedPoint(-1.0, 8, 8)
    results.check(fp_neg.raw == -256, f"-1.0 raw = {fp_neg.raw} (expected -256)")
    results.check(
        fp_neg.to_binary() == '1111111100000000',
        f"-1.0 binary = {fp_neg.to_binary()}",
    )


# =========================================================================
# MAIN
# =========================================================================

if __name__ == '__main__':
    print("=" * 60)
    print(" AEGIS PHASE 1.1: Fixed-Point Arithmetic Validation")
    print("=" * 60)

    test_conversion()
    test_add_sub()
    test_overflow()
    test_multiply()
    test_random_multiply()
    test_relu()
    test_sigmoid()
    test_q16_16()
    test_linear_algebra()
    test_representation()

    success = results.summary()
    sys.exit(0 if success else 1)
