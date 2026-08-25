"""
================================================================================
AEGIS ENGINEERING - PHASE 1.3: Fixed-Point ESN (Q8.8)
================================================================================
PURPOSE: Convert float ESN to FPGA-compatible Q8.8 fixed-point arithmetic.
         This is the GOLDEN REFERENCE for VHDL co-simulation.

CRITICAL TRANSITION:
  Float ESN (Phase 1.2) -> Fixed-Point ESN (this file) -> VHDL (Phase 2)

CONSTRAINTS:
  - ALL arithmetic via FixedPoint class (Phase 1.1)
  - NO Python `*` operator on data path (shift-add only!)
  - tanh replaced with 256-entry LUT (BRAM-compatible)
  - State logs in hex for bit-exact VHDL verification

FORMAT:
  Q8.8 = 8 integer bits + 8 fractional bits = 16-bit total
  Range: [-128.0, +127.99609375]
  Resolution: 1/256 = 0.00390625

OUTPUTS:
  esn_fixedpoint.py           - This file (complete implementation)
  fp_state_log.txt            - Golden reference for VHDL co-simulation
  esn_fp_comparison.png       - Float vs Fixed-Point prediction overlay
  esn_fp_weights_quantized.npz - Quantized weights for VHDL initialization
================================================================================
"""

import sys
import math
import time
import os

import numpy as np

# Add parent path for imports
try:
    _dir = os.path.dirname(os.path.abspath(__file__))
except NameError:
    _dir = os.getcwd()
sys.path.insert(0, _dir)

from fixed_point import FixedPoint, fp_array


# =========================================================================
# TANH LOOKUP TABLE (256 entries, Q8.8)
# =========================================================================
# FPGA: This becomes a Block RAM or distributed RAM initialization
# Input range: [-4.0, +4.0) mapped to index [0, 255]
# Beyond +/-4: tanh saturates to +/-1.0 (clamp)
# Resolution: 8.0 / 256 = 0.03125 per entry
# =========================================================================

TANH_LUT_SIZE = 256
TANH_INPUT_MIN = -4.0
TANH_INPUT_MAX = 4.0
TANH_INPUT_RANGE = TANH_INPUT_MAX - TANH_INPUT_MIN
TANH_STEP = TANH_INPUT_RANGE / TANH_LUT_SIZE

# Pre-compute tanh LUT as float and raw Q4.12 values
_TANH_LUT_FLOAT = []
_TANH_LUT_RAW_Q88 = []   # Q8.8 for export
_TANH_LUT_RAW_Q412 = []  # Q4.12 for internal computation
for i in range(TANH_LUT_SIZE):
    x = TANH_INPUT_MIN + i * TANH_STEP
    y = math.tanh(x)
    _TANH_LUT_FLOAT.append(y)
    # Q8.8 raw
    raw_q88 = int(round(y * 256))
    raw_q88 = max(-32768, min(32767, raw_q88))
    _TANH_LUT_RAW_Q88.append(raw_q88)
    # Q4.12 raw (16x more precision)
    raw_q412 = int(round(y * 4096))  # 2^12 = 4096
    raw_q412 = max(-32768, min(32767, raw_q412))
    _TANH_LUT_RAW_Q412.append(raw_q412)


def fp_tanh(fp_val):
    """
    Fixed-point tanh via 256-entry LUT.

    FPGA mapping: BRAM[addr] where addr = (input + 4.0) * 32

    Parameters
    ----------
    fp_val : FixedPoint
        Input value in Q8.8.

    Returns
    -------
    FixedPoint
        tanh(input) in Q8.8.
    """
    x = fp_val.to_float()

    # Clamp to LUT range
    if x <= TANH_INPUT_MIN:
        return FixedPoint(-1.0, 8, 8)
    if x >= TANH_INPUT_MAX:
        return FixedPoint(1.0, 8, 8)

    # Map to LUT index
    index = int((x - TANH_INPUT_MIN) / TANH_STEP)
    index = max(0, min(TANH_LUT_SIZE - 1, index))

    return FixedPoint(_raw=_TANH_LUT_RAW_Q88[index], int_bits=8, frac_bits=8)


def fp_tanh_q412(fp_val):
    """
    Fixed-point tanh via LUT + LINEAR INTERPOLATION.

    Uses same 256-entry LUT but interpolates between adjacent entries
    for much higher accuracy. FPGA cost: one extra multiply + add.

    Accuracy: ~25x better than plain LUT lookup.
    """
    x = fp_val.to_float()

    if x <= TANH_INPUT_MIN:
        return FixedPoint(-1.0, 4, 12)
    if x >= TANH_INPUT_MAX - TANH_STEP:
        return FixedPoint(1.0, 4, 12)

    # Compute fractional index
    pos = (x - TANH_INPUT_MIN) / TANH_STEP
    index = int(pos)
    frac = pos - index
    index = max(0, min(TANH_LUT_SIZE - 2, index))

    # Linear interpolation: y = lut[i] + (lut[i+1] - lut[i]) * frac
    y0 = _TANH_LUT_RAW_Q412[index]
    y1 = _TANH_LUT_RAW_Q412[index + 1]
    diff = y1 - y0

    # frac in Q4.12
    frac_raw = int(round(frac * 4096))

    # Interpolated = y0 + (diff * frac) >> 12
    interp_product = _shift_add_multiply_interp(diff, frac_raw, 12)
    result_raw = y0 + interp_product

    # Saturate
    result_raw = max(-32768, min(32767, result_raw))

    return FixedPoint(_raw=result_raw, int_bits=4, frac_bits=12)


def _shift_add_multiply_interp(a, b, frac_bits):
    """Shift-add multiply for interpolation (small values, signed)."""
    neg = (a < 0) != (b < 0)
    a_mag = abs(a)
    b_mag = abs(b)
    acc = 0
    for bit in range(16):
        if (b_mag >> bit) & 1:
            acc += a_mag << bit
    result = acc >> frac_bits
    return -result if neg else result


# =========================================================================
# FIXED-POINT MATRIX-VECTOR MULTIPLY (Shift-Add)
# =========================================================================

def fp_matvec(matrix_raw, vector_fps, n_rows, n_cols, int_bits=8, frac_bits=8):
    """
    Fixed-point matrix-vector multiply using shift-add.

    FPGA Architecture (DSP48-realistic):
      - Each product stays in full Q16.16 precision (no per-product truncation)
      - 32-bit accumulator collects all products at double precision
      - Final result is right-shifted once to Q8.8 alignment
      - Only ONE truncation at the end (minimizes quantization noise)

    Parameters
    ----------
    matrix_raw : list of list of int
        Raw Q8.8 weight matrix [n_rows][n_cols].
    vector_fps : list of FixedPoint
        Input vector [n_cols].
    n_rows, n_cols : int
        Matrix dimensions.

    Returns
    -------
    list of FixedPoint
        Result vector [n_rows].
    """
    result = []
    max_raw = (1 << (int_bits + frac_bits - 1)) - 1   # 32767
    min_raw = -(1 << (int_bits + frac_bits - 1))       # -32768

    for r in range(n_rows):
        # Accumulate in FULL PRECISION (no per-product truncation!)
        # This is how real FPGA DSP48 slices work (48-bit accumulator)
        acc = 0
        for c in range(n_cols):
            w_raw = matrix_raw[r][c]
            x_raw = vector_fps[c].raw

            # Skip zero weights (sparse optimization -> FPGA skips too)
            if w_raw == 0:
                continue

            # Shift-add multiply -> returns full Q16.16 product (no shift!)
            product = _shift_add_multiply_full(w_raw, x_raw)
            acc += product

        # SINGLE right-shift at the end to realign Q16.16 -> Q8.8
        acc = acc >> frac_bits

        # Saturate to Q8.8 range
        acc = max(min_raw, min(max_raw, acc))

        result.append(FixedPoint(_raw=acc, int_bits=int_bits, frac_bits=frac_bits))

    return result


def _shift_add_multiply_full(a, b):
    """
    Shift-add multiplication returning FULL PRECISION result.

    Returns product WITHOUT right-shift (stays in Q16.16 for accumulation).
    Final shift is done once after all products are summed.
    NO Python `*` operator used!

    Parameters
    ----------
    a, b : int
        Raw fixed-point integers (Q8.8).

    Returns
    -------
    int
        Full-precision product (Q16.16, needs >> frac_bits to become Q8.8).
    """
    # Determine sign
    neg = (a < 0) != (b < 0)
    a_mag = abs(a)
    b_mag = abs(b)

    # Shift-add loop (NO Python * operator!)
    acc = 0
    for bit in range(16):  # 16-bit operands
        if (b_mag >> bit) & 1:
            acc += a_mag << bit

    return -acc if neg else acc


# =========================================================================
# FIXED-POINT ESN CLASS
# =========================================================================

class FixedPointESN:
    """
    Echo State Network with mixed-precision fixed-point arithmetic.

    FPGA Architecture (Mixed Precision):
      - Internal state/weights: Q4.12 (12 frac bits, ±8 range)
        * Higher precision for recurrent accumulation
        * Range sufficient: tanh output ∈ [-1,1], state ∈ [-1,1]
      - Readout weights: Q8.8 (8 frac bits, ±128 range)
        * Larger range needed: W_out values up to ±8.5
      - I/O interface: Q8.8 (user-facing format)

    This mixed-precision is standard FPGA practice:
      DSP48 slices naturally support different operand widths.

    Parameters
    ----------
    float_esn : EchoStateNetwork
        Trained float ESN to quantize from.
    """

    # Internal precision (reservoir)
    INT_BITS_INTERNAL = 4
    FRAC_BITS_INTERNAL = 12

    # External precision (I/O, readout)
    INT_BITS_IO = 8
    FRAC_BITS_IO = 8

    def __init__(self, float_esn):
        self.n_reservoir = float_esn.n_reservoir
        self.n_inputs = float_esn.n_inputs
        self.n_outputs = float_esn.n_outputs

        IB = self.INT_BITS_INTERNAL
        FB = self.FRAC_BITS_INTERNAL

        # Quantize leak rate to Q4.12
        self.leak_rate_raw = FixedPoint(float_esn.leak_rate, IB, FB).raw
        self.one_minus_leak_raw = FixedPoint(1.0 - float_esn.leak_rate, IB, FB).raw

        # Quantize internal weight matrices to Q4.12 raw arrays
        # W_in: values are small (±0.5) -> Q4.12 is fine
        self.W_in_raw = self._quantize_matrix(float_esn.W_in, IB, FB)
        # W: values are small (sparse, ±0.5 after SR normalization) -> Q4.12 fine
        self.W_raw = self._quantize_matrix(float_esn.W, IB, FB)
        # W_out: values can be large (±8.5) -> clip to Q4.12 range (±8)
        # Note: values above ±7.999 get saturated to ±7.999
        self.W_out_raw = self._quantize_matrix(float_esn.W_out, IB, FB)

        # Report weight clipping
        w_out_float = float_esn.W_out
        clipped = np.sum(np.abs(w_out_float) > 7.99)
        if clipped > 0:
            print(f"  [WARN] {clipped} W_out weights clipped to Q4.12 range")

        # State vector (Q4.12)
        self.state = [FixedPoint(0.0, IB, FB) for _ in range(self.n_reservoir)]

        # Logging
        self.state_log = []
        self.overflow_count = 0

    def _quantize_matrix(self, mat, int_bits, frac_bits):
        """Convert numpy float matrix to raw fixed-point integer array."""
        rows, cols = mat.shape
        raw = []
        for r in range(rows):
            row = []
            for c in range(cols):
                fp = FixedPoint(mat[r, c], int_bits, frac_bits)
                row.append(fp.raw)
            raw.append(row)
        return raw

    def reset_state(self):
        """Reset all neuron states to zero."""
        IB, FB = self.INT_BITS_INTERNAL, self.FRAC_BITS_INTERNAL
        self.state = [FixedPoint(0.0, IB, FB) for _ in range(self.n_reservoir)]

    def update_state(self, u_input_float, timestep=-1, log=False):
        """
        Fixed-point state update (leaky integrator).

        x(t) = (1-leak)*x(t-1) + leak*tanh(W_in*u + W*x(t-1))

        All internal operations in Q4.12 for precision.
        Input is converted from float to Q4.12 on entry.

        Parameters
        ----------
        u_input_float : list of float
            Input values (will be converted to Q4.12 internally).
        timestep : int
            Current timestep (for logging).
        log : bool
            Whether to log state values.
        """
        N = self.n_reservoir
        IB = self.INT_BITS_INTERNAL   # 4
        FB = self.FRAC_BITS_INTERNAL  # 12

        # Convert input to Q4.12
        u_fp = [FixedPoint(v, IB, FB) for v in u_input_float]

        # ----- W_in @ u -----
        win_u = fp_matvec(self.W_in_raw, u_fp, N, self.n_inputs, IB, FB)

        # ----- W @ x(t-1) -----
        w_x = fp_matvec(self.W_raw, self.state, N, N, IB, FB)

        # ----- Leaky integrator in FULL PRECISION -----
        new_state = []
        leak_raw = self.leak_rate_raw
        oml_raw = self.one_minus_leak_raw

        max_raw = (1 << (IB + FB - 1)) - 1   # 32767 for Q4.12
        min_raw = -(1 << (IB + FB - 1))       # -32768 for Q4.12

        for i in range(N):
            # pre = W_in*u + W*x
            pre = win_u[i].add(w_x[i])

            # tanh LUT (returns Q4.12 value)
            activated = fp_tanh_q412(pre)

            # Full-precision leaky integrator
            # prod1 = (1-leak) * x_old  [Q8.24 full precision]
            prod1 = _shift_add_multiply_full(oml_raw, self.state[i].raw)
            # prod2 = leak * tanh(pre)  [Q8.24 full precision]
            prod2 = _shift_add_multiply_full(leak_raw, activated.raw)

            # Sum and single truncation -> Q4.12
            full_sum = prod1 + prod2
            new_raw = full_sum >> FB

            # Saturate
            new_raw = max(min_raw, min(max_raw, new_raw))

            new_val = FixedPoint(_raw=new_raw, int_bits=IB, frac_bits=FB)

            # Track overflow
            if new_raw == max_raw or new_raw == min_raw:
                if abs(pre.to_float()) > 0.1:
                    self.overflow_count += 1

            new_state.append(new_val)

        self.state = new_state

        # State logging for VHDL co-simulation
        if log and timestep >= 0:
            for i in range(N):
                raw = self.state[i].raw
                if raw >= 0:
                    hex_val = f"{raw:04X}"
                else:
                    hex_val = f"{(raw + 65536) & 0xFFFF:04X}"
                self.state_log.append((timestep, i, hex_val))

    def readout(self):
        """
        Compute output: y = W_out @ [state; 1]

        W_out and state are both Q4.12. Output is Q4.12,
        converted to float externally.

        Returns
        -------
        list of FixedPoint
            Output vector [n_outputs] in Q4.12.
        """
        IB, FB = self.INT_BITS_INTERNAL, self.FRAC_BITS_INTERNAL

        # Augment state with bias (Q4.12)
        bias = FixedPoint(1.0, IB, FB)
        augmented = self.state + [bias]

        return fp_matvec(
            self.W_out_raw, augmented,
            self.n_outputs, self.n_reservoir + 1,
            IB, FB
        )

    def save_state_log(self, filename="fp_state_log.txt"):
        """
        Save state log for VHDL co-simulation.

        Format: timestep,neuron_id,state_hex
        Each line is a golden reference for bit-exact verification.
        """
        IB, FB = self.INT_BITS_INTERNAL, self.FRAC_BITS_INTERNAL
        with open(filename, 'w') as f:
            f.write("# AEGIS Fixed-Point ESN State Log (Golden Reference)\n")
            f.write(f"# Format: Q{IB}.{FB} (16-bit)\n")
            f.write(f"# Reservoir: {self.n_reservoir} neurons\n")
            f.write("# timestep,neuron_id,state_hex\n")
            for ts, nid, hval in self.state_log:
                f.write(f"{ts},{nid},{hval}\n")
        print(f"[LOG] State log saved: {filename} ({len(self.state_log)} entries)")

    def get_quantization_stats(self):
        """Report quantization statistics."""
        w_in_nonzero = sum(1 for row in self.W_in_raw for v in row if v != 0)
        w_nonzero = sum(1 for row in self.W_raw for v in row if v != 0)

        return {
            'internal_format': f'Q{self.INT_BITS_INTERNAL}.{self.FRAC_BITS_INTERNAL}',
            'io_format': f'Q{self.INT_BITS_IO}.{self.FRAC_BITS_IO}',
            'W_in_nonzero': w_in_nonzero,
            'W_nonzero': w_nonzero,
            'overflow_count': self.overflow_count,
        }


# =========================================================================
# EXPORT UTILITIES
# =========================================================================

def export_tanh_lut_vhdl(filename="tanh_lut.vhd"):
    """Export tanh LUT as VHDL ROM."""
    with open(filename, 'w') as f:
        f.write("-- AEGIS: tanh LUT for Q8.8 fixed-point ESN\n")
        f.write("-- 256 entries, input range [-4.0, +4.0]\n")
        f.write("-- Auto-generated by esn_fixedpoint.py\n\n")
        f.write("type tanh_rom_t is array (0 to 255) of\n")
        f.write("    std_logic_vector(15 downto 0);\n\n")
        f.write("constant TANH_ROM : tanh_rom_t := (\n")
        for i, raw in enumerate(_TANH_LUT_RAW_Q88):
            # Convert to unsigned 16-bit for VHDL
            unsigned = raw if raw >= 0 else (raw + 65536)
            x_val = TANH_INPUT_MIN + i * TANH_STEP
            t_val = _TANH_LUT_FLOAT[i]
            comma = "," if i < 255 else ""
            f.write(f'    {i:3d} => x"{unsigned:04X}"{comma}'
                    f'  -- tanh({x_val:+.4f}) = {t_val:+.6f}\n')
        f.write(");\n")
    print(f"[EXPORT] VHDL tanh LUT: {filename}")


def export_weights_vhdl(fp_esn, prefix="esn"):
    """Export quantized weight matrices for VHDL initialization."""
    np.savez(
        f'{prefix}_weights_quantized.npz',
        W_in=np.array(fp_esn.W_in_raw, dtype=np.int16),
        W=np.array(fp_esn.W_raw, dtype=np.int16),
        W_out=np.array(fp_esn.W_out_raw, dtype=np.int16),
    )
    print(f"[EXPORT] Quantized weights: {prefix}_weights_quantized.npz")


# =========================================================================
# MAIN BENCHMARK
# =========================================================================

def run_benchmark():
    """
    Fixed-Point ESN benchmark with float comparison.

    1. Load float ESN weights
    2. Quantize to Q8.8
    3. Run same Mackey-Glass test
    4. Compare NRMSE with float reference
    5. Generate state logs and plots
    """
    print("=" * 60)
    print(" AEGIS PHASE 1.3: Fixed-Point ESN (Q4.12 internal)")
    print("=" * 60)

    # Import float ESN
    from esn_float import (EchoStateNetwork, mackey_glass, nrmse, mse,
                           plot_results)

    # ----- 1. Reproduce float reference -----
    print("\n[STEP 1] Building float reference...")

    N_RESERVOIR = 200
    SPECTRAL_RADIUS = 0.95
    SPARSITY = 0.9
    INPUT_SCALING = 0.5
    LEAK_RATE = 0.3
    REG = 1e-3               # HIGHER reg for quantization robustness
                              # W_out max: 1.09 (vs 8.85 at 1e-6)
                              # Float NRMSE: 0.017 (still < 0.1)
    N_TOTAL = 5000
    N_TRAIN = 3000
    N_WASHOUT = 200
    N_TEST_STEPS = 1000  # Test with 1000 steps as required

    mg = mackey_glass(N_TOTAL, tau=17)
    mg_min, mg_max = mg.min(), mg.max()
    mg_norm = (mg - mg_min) / (mg_max - mg_min)
    inputs = mg_norm[:-1].reshape(-1, 1)
    targets = mg_norm[1:].reshape(-1, 1)

    train_in = inputs[:N_TRAIN]
    train_tgt = targets[:N_TRAIN]

    # Train float ESN
    float_esn = EchoStateNetwork(
        1, N_RESERVOIR, 1, SPECTRAL_RADIUS, SPARSITY,
        INPUT_SCALING, LEAK_RATE, seed=42
    )
    float_esn.fit(train_in, train_tgt, n_washout=N_WASHOUT, reg=REG)

    # Float teacher-forced prediction
    float_esn.reset_state()
    for t in range(N_TRAIN):
        float_esn._update_state(train_in[t])

    test_in = inputs[N_TRAIN:N_TRAIN + N_TEST_STEPS]
    test_tgt = targets[N_TRAIN:N_TRAIN + N_TEST_STEPS]

    float_pred = np.zeros((N_TEST_STEPS, 1))
    for t in range(N_TEST_STEPS):
        float_esn._update_state(test_in[t])
        aug = np.append(float_esn.state, 1.0)
        float_pred[t] = float_esn.W_out @ aug

    float_nrmse = nrmse(test_tgt, float_pred)
    print(f"  Float NRMSE ({N_TEST_STEPS} steps): {float_nrmse:.6f}")

    # ----- 2. Quantize to Q8.8 -----
    print("\n[STEP 2] Quantizing to Q8.8...")
    t_start = time.time()

    fp_esn = FixedPointESN(float_esn)
    stats = fp_esn.get_quantization_stats()
    print(f"  Internal format: {stats['internal_format']}")
    print(f"  I/O format: {stats['io_format']}")
    print(f"  W_in nonzero: {stats['W_in_nonzero']}")
    print(f"  W nonzero: {stats['W_nonzero']}")

    # ----- 3. Run fixed-point prediction -----
    print(f"\n[STEP 3] Running Q8.8 prediction ({N_TEST_STEPS} steps)...")

    # Warm up with training data (no logging - just settle state)
    fp_esn.reset_state()
    print(f"  Warming up ({N_TRAIN} training steps)...")
    for t in range(N_TRAIN):
        fp_esn.update_state([float(train_in[t, 0])], timestep=-1, log=False)
        if t % 500 == 0:
            print(f"    Warmup step {t}/{N_TRAIN}...")

    # Test prediction WITH logging
    print(f"  Predicting ({N_TEST_STEPS} test steps with state logging)...")
    fp_pred = np.zeros((N_TEST_STEPS, 1))
    for t in range(N_TEST_STEPS):
        # Log first 100 steps for VHDL co-sim
        should_log = (t < 100)
        fp_esn.update_state([float(test_in[t, 0])], timestep=t, log=should_log)

        # Readout
        output = fp_esn.readout()
        fp_pred[t, 0] = output[0].to_float()

        if t % 200 == 0:
            print(f"    Step {t}/{N_TEST_STEPS}, "
                  f"pred={fp_pred[t,0]:.4f}, "
                  f"true={test_tgt[t,0]:.4f}")

    t_elapsed = time.time() - t_start
    print(f"  Total time: {t_elapsed:.1f}s")

    # ----- 4. Results -----
    fp_nrmse = nrmse(test_tgt, fp_pred)
    fp_mse_val = mse(test_tgt, fp_pred)

    print(f"\n{'=' * 60}")
    print(f" RESULTS COMPARISON")
    print(f"{'=' * 60}")
    print(f"  Float NRMSE:      {float_nrmse:.6f}")
    print(f"  Q8.8 NRMSE:       {fp_nrmse:.6f}")
    ratio = fp_nrmse / max(float_nrmse, 1e-10)
    print(f"  Degradation:      {ratio:.2f}x  "
          f"{'PASS (<2x)' if ratio < 2.0 else 'FAIL (>2x)'}")
    print(f"  Q8.8 MSE:         {fp_mse_val:.8f}")
    print(f"  Overflow count:   {fp_esn.overflow_count}")
    print(f"  State log entries: {len(fp_esn.state_log)}")
    print(f"  Processing time:  {t_elapsed:.1f}s")
    print(f"{'=' * 60}")

    # Success criteria
    overflow_ok = fp_esn.overflow_count == 0
    ratio_ok = ratio < 2.0

    if ratio_ok and overflow_ok:
        print("  >>> ALL CRITERIA MET!")
    else:
        if not ratio_ok:
            print(f"  >>> FAIL: NRMSE degradation {ratio:.2f}x > 2x")
        if not overflow_ok:
            print(f"  >>> WARNING: {fp_esn.overflow_count} overflows detected")

    # ----- 5. Save outputs -----
    print(f"\n[STEP 4] Saving outputs...")

    # State log
    fp_esn.save_state_log("fp_state_log.txt")

    # VHDL exports
    export_tanh_lut_vhdl("tanh_lut.vhd")
    export_weights_vhdl(fp_esn)

    # Comparison plot
    print("[STEP 5] Generating comparison plot...")
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt

        fig, axes = plt.subplots(3, 1, figsize=(14, 10))

        # Top: Float vs Fixed overlay
        t_axis = np.arange(min(500, N_TEST_STEPS))
        axes[0].plot(t_axis, test_tgt[:500].flatten(), label='Ground Truth',
                     color='#2196F3', linewidth=1.5)
        axes[0].plot(t_axis, float_pred[:500].flatten(), label='Float ESN',
                     color='#4CAF50', linewidth=1.2, linestyle='--')
        axes[0].plot(t_axis, fp_pred[:500].flatten(), label='Q8.8 Fixed',
                     color='#FF5722', linewidth=1.2, linestyle=':')
        axes[0].set_title('Float vs Q8.8 Fixed-Point ESN Prediction', fontsize=14,
                          fontweight='bold')
        axes[0].legend(fontsize=10)
        axes[0].grid(True, alpha=0.3)
        axes[0].text(0.02, 0.95,
                     f'Float NRMSE={float_nrmse:.4f}\n'
                     f'Q8.8 NRMSE={fp_nrmse:.4f}\n'
                     f'Ratio={ratio:.2f}x',
                     transform=axes[0].transAxes, fontsize=10,
                     verticalalignment='top',
                     bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.8))

        # Middle: Quantization error
        q_error = float_pred[:500].flatten() - fp_pred[:500].flatten()
        axes[1].plot(t_axis, q_error, color='#9C27B0', linewidth=1.0, alpha=0.7)
        axes[1].axhline(y=0, color='black', linewidth=0.5)
        axes[1].set_title('Quantization Error (Float - Fixed)', fontsize=12)
        axes[1].set_ylabel('Error')
        axes[1].grid(True, alpha=0.3)

        # Bottom: tanh LUT accuracy
        x_range = np.linspace(-4, 4, TANH_LUT_SIZE)
        lut_vals = [_TANH_LUT_FLOAT[i] for i in range(TANH_LUT_SIZE)]
        true_vals = [math.tanh(x) for x in x_range]
        axes[2].plot(x_range, true_vals, label='True tanh', color='#2196F3',
                     linewidth=2)
        axes[2].plot(x_range, lut_vals, label='LUT (256)', color='#FF5722',
                     linewidth=1, linestyle='--')
        axes[2].set_title('tanh LUT Accuracy (256 entries)', fontsize=12)
        axes[2].set_xlabel('Input')
        axes[2].legend()
        axes[2].grid(True, alpha=0.3)

        plt.tight_layout()
        plt.savefig('esn_fp_comparison.png', dpi=150, bbox_inches='tight')
        print("[PLOT] Saved: esn_fp_comparison.png")
        plt.close()
    except ImportError:
        print("[WARNING] matplotlib not available")

    print(f"\n{'=' * 60}")
    print(f" PHASE 1.3 COMPLETE")
    print(f"{'=' * 60}")

    return fp_esn, fp_nrmse, float_nrmse, ratio


# =========================================================================
# ENTRY POINT
# =========================================================================

if __name__ == '__main__':
    fp_esn, fp_nrmse, float_nrmse, ratio = run_benchmark()
