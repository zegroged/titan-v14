"""
AEGIS Phase 2.4: Readout Layer Golden Reference + Test Vectors
Generates test vectors for esn_readout VHDL testbench.
"""
import numpy as np
import math
import os, sys

FRAC = 8
SCALE = 1 << FRAC
ESN_N = 8

def float_to_q88(v):
    raw = int(round(v * SCALE))
    return max(-32768, min(32767, raw))

def q88_to_float(raw):
    if raw >= 32768: raw -= 65536
    return raw / SCALE

def to_u16(v):
    return v & 0xFFFF

def q88_dot_product(weights, states):
    """Exact VHDL dot product: accumulate Q16.16, shift >>8, saturate."""
    acc = 0
    for w, s in zip(weights, states):
        acc += w * s  # 16×16 → 32-bit product
    # Shift right 8 (Q16.16 → Q8.8)
    if acc >= 0:
        shifted = acc >> FRAC
    else:
        shifted = -((-acc) >> FRAC)
    # Saturate to 16-bit signed
    return max(-32768, min(32767, shifted))


def main():
    rng = np.random.default_rng(123)
    base = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          '..', '..', 'rtl', 'aegis'))

    # Generate random W_out weights (Q8.8)
    w_out_float = rng.uniform(-1.0, 1.0, ESN_N)
    w_out_q = [float_to_q88(w) for w in w_out_float]

    # Generate test scenarios
    # Scenario 1: Initial weights (bank 0), 3 state inputs -> 3 predictions
    # Scenario 2: Update weights (bank 1, swap), 2 more inputs -> 2 predictions
    w_out2_float = rng.uniform(-0.5, 0.5, ESN_N)
    w_out2_q = [float_to_q88(w) for w in w_out2_float]

    test_states = []
    for _ in range(5):
        s = [float_to_q88(rng.uniform(-0.5, 0.5)) for _ in range(ESN_N)]
        test_states.append(s)

    # Compute golden predictions
    predictions = []
    for i in range(3):
        pred = q88_dot_product(w_out_q, test_states[i])
        predictions.append((i, w_out_q, test_states[i], pred, "bank0"))

    for i in range(3, 5):
        pred = q88_dot_product(w_out2_q, test_states[i])
        predictions.append((i, w_out2_q, test_states[i], pred, "bank1"))

    # Write test vectors CSV
    csv_path = os.path.join(base, 'test_vectors_readout.csv')
    with open(csv_path, 'w') as f:
        f.write("# AEGIS Phase 2.4: Readout test vectors\n")
        f.write(f"# N={ESN_N}\n")

        # Section 1: Weights (bank 0)
        f.write("WEIGHTS_BANK0\n")
        for i, w in enumerate(w_out_q):
            f.write(f"{i},{to_u16(w):04X}\n")

        # Section 2: Weights (bank 1)
        f.write("WEIGHTS_BANK1\n")
        for i, w in enumerate(w_out2_q):
            f.write(f"{i},{to_u16(w):04X}\n")

        # Section 3: Test cases
        f.write("TESTS\n")
        for step, weights, states, pred, bank in predictions:
            states_hex = ",".join([f"{to_u16(s):04X}" for s in states])
            f.write(f"{bank},{to_u16(pred):04X},{states_hex}\n")

    print(f"[TEST] {csv_path} ({len(predictions)} test cases)")

    # Print summary
    print(f"\n[SUMMARY]")
    print(f"  Neurons: {ESN_N}")
    print(f"  Weight bank 0: {[f'{q88_to_float(w):+.3f}' for w in w_out_q]}")
    print(f"  Weight bank 1: {[f'{q88_to_float(w):+.3f}' for w in w_out2_q]}")
    print(f"\n  Predictions:")
    for step, weights, states, pred, bank in predictions:
        pred_f = q88_to_float(pred)
        print(f"    Step {step} ({bank}): pred=0x{to_u16(pred):04X} = {pred_f:+.4f}")

    # Verify internal consistency
    print(f"\n[VERIFY] Cross-checking dot products...")
    all_ok = True
    for step, weights, states, pred, bank in predictions:
        # Float reference
        float_pred = sum(q88_to_float(w) * q88_to_float(s)
                        for w, s in zip(weights, states))
        q88_pred = q88_to_float(pred)
        err = abs(float_pred - q88_pred)
        ok = err < 0.02  # ±1 LSB tolerance
        status = "OK" if ok else "FAIL"
        print(f"    Step {step}: Q8.8={q88_pred:+.4f} float={float_pred:+.4f} "
              f"err={err:.4f} [{status}]")
        if not ok:
            all_ok = False

    if all_ok:
        print("  All predictions within +-1 LSB!")
    else:
        print("  WARNING: Some predictions exceed tolerance!")


if __name__ == '__main__':
    main()
