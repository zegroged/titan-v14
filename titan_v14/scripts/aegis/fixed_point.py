"""
================================================================================
AEGIS ENGINEERING - PHASE 1.1: Fixed-Point Arithmetic Library
================================================================================
PURPOSE: FPGA-compatible fixed-point arithmetic (NO float in hardware path!)

FORMATS:
  Q8.8:   8 bit integer + 8 bit fraction = 16 bit total
  Q16.16: 16 bit integer + 16 bit fraction = 32 bit total

DESIGN RULES:
  1. Multiplication uses SHIFT-ADD only (no Python `*` in multiply path)
  2. Overflow → SATURATE (clamp to max/min, never wrap silently)
  3. Negative numbers: Two's complement
  4. Intermediate results: 2x width, then truncate back

FPGA MAPPING:
  FixedPoint.add()       → VHDL: std_logic_vector + std_logic_vector
  FixedPoint.multiply()  → VHDL: shift-add tree (no DSP48 needed!)
  FixedPoint.relu()      → VHDL: mux on MSB (sign bit)
  FixedPoint.sigmoid()   → VHDL: BRAM/LUT lookup table

USAGE:
  >>> a = FixedPoint(3.14, int_bits=8, frac_bits=8)
  >>> b = FixedPoint(-1.5, int_bits=8, frac_bits=8)
  >>> c = a.add(b)
  >>> print(c.to_float())  # ~1.64
================================================================================
"""

import math


class FixedPoint:
    """
    FPGA-compatible fixed-point number.

    Internal representation: raw integer in two's complement.
    Value = raw / (2^frac_bits)

    Parameters
    ----------
    value : float or int
        The numeric value to represent.
    int_bits : int
        Number of integer bits (including sign bit).
    frac_bits : int
        Number of fractional bits.
    overflow : str
        'saturate' (default) or 'wrap'.
    _raw : int or None
        Internal: set raw value directly (skip float conversion).
    """

    def __init__(self, value=0.0, int_bits=8, frac_bits=8,
                 overflow='saturate', _raw=None):
        self.int_bits = int_bits
        self.frac_bits = frac_bits
        self.total_bits = int_bits + frac_bits
        self.overflow = overflow

        # Two's complement range
        self.max_raw = (1 << (self.total_bits - 1)) - 1
        self.min_raw = -(1 << (self.total_bits - 1))

        if _raw is not None:
            self.raw = self._clamp(_raw)
        else:
            self.raw = self._from_float(value)

    # ------------------------------------------------------------------
    # Conversion: float ↔ fixed
    # ------------------------------------------------------------------

    def _from_float(self, value):
        """Convert float to fixed-point raw integer."""
        # Scale by 2^frac_bits, round to nearest, clamp
        scaled = value * (1 << self.frac_bits)
        raw = int(round(scaled))
        return self._clamp(raw)

    def to_float(self):
        """Convert fixed-point raw integer back to float."""
        return self.raw / (1 << self.frac_bits)

    # ------------------------------------------------------------------
    # Overflow handling
    # ------------------------------------------------------------------

    def _clamp(self, raw):
        """Saturate or wrap on overflow."""
        if self.overflow == 'saturate':
            if raw > self.max_raw:
                return self.max_raw
            if raw < self.min_raw:
                return self.min_raw
            return raw
        else:  # wrap
            # Mask to total_bits, then sign-extend
            mask = (1 << self.total_bits) - 1
            raw = raw & mask
            if raw >= (1 << (self.total_bits - 1)):
                raw -= (1 << self.total_bits)
            return raw

    def _make(self, raw):
        """Create a new FixedPoint with same format from raw value."""
        return FixedPoint(
            int_bits=self.int_bits,
            frac_bits=self.frac_bits,
            overflow=self.overflow,
            _raw=raw,
        )

    # ------------------------------------------------------------------
    # Arithmetic operations
    # ------------------------------------------------------------------

    def add(self, other):
        """
        Fixed-point addition with saturation.

        FPGA: Single adder, carry-chain propagation, 1 clock cycle.
        """
        self._check_format(other)
        result_raw = self.raw + other.raw
        return self._make(result_raw)

    def sub(self, other):
        """
        Fixed-point subtraction with saturation.

        FPGA: Single subtractor, borrow-chain, 1 clock cycle.
        """
        self._check_format(other)
        result_raw = self.raw - other.raw
        return self._make(result_raw)

    def negate(self):
        """
        Two's complement negation.

        FPGA: Invert all bits, add 1.
        """
        return self._make(-self.raw)

    def multiply(self, other):
        """
        Fixed-point multiplication using SHIFT-ADD ONLY.

        NO Python `*` operator is used on the data values.
        This directly maps to an FPGA shift-add tree.

        Algorithm:
          1. Determine signs, work with magnitudes
          2. For each '1' bit in multiplier, shift multiplicand and add
          3. Result is 2x width (32-bit for Q8.8)
          4. Right-shift by frac_bits to realign
          5. Truncate back to original width

        FPGA: Generates a shift-add tree (combinatorial or pipelined).
              No DSP48 slice required!
        """
        self._check_format(other)

        a_raw = self.raw
        b_raw = other.raw

        # Determine result sign
        result_negative = (a_raw < 0) != (b_raw < 0)

        # Work with magnitudes
        a_mag = abs(a_raw)
        b_mag = abs(b_raw)

        # ---- SHIFT-ADD MULTIPLICATION ----
        # This is the FPGA-compatible multiply!
        # Equivalent to: accumulator += (a << bit_position) for each '1' bit in b
        accumulator = 0
        double_width = self.total_bits << 1  # 32 bits for Q8.8

        for bit_pos in range(self.total_bits):
            if (b_mag >> bit_pos) & 1:
                accumulator += a_mag << bit_pos

        # Mask to double width to prevent Python arbitrary precision bleed
        acc_mask = (1 << double_width) - 1
        accumulator = accumulator & acc_mask

        # ---- REALIGN ----
        # Product of Q8.8 × Q8.8 = Q16.16 (frac bits doubled)
        # Shift right by frac_bits to get back to Q8.8
        result_raw = accumulator >> self.frac_bits

        # ---- APPLY SIGN ----
        if result_negative:
            result_raw = -result_raw

        return self._make(result_raw)

    def abs_val(self):
        """Absolute value."""
        return self._make(abs(self.raw))

    # ------------------------------------------------------------------
    # Activation functions (Neural Network support)
    # ------------------------------------------------------------------

    def relu(self):
        """
        Rectified Linear Unit.

        FPGA: Single MUX controlled by MSB (sign bit).
              if sign_bit = '1' then output <= 0;
              else output <= input;
              Zero LUT cost if using dedicated MUX.
        """
        if self.raw < 0:
            return self._make(0)
        return self._make(self.raw)

    def sigmoid(self):
        """
        Sigmoid approximation via 256-entry LUT.

        FPGA: Uses a Block RAM or distributed RAM as lookup table.
              Input range clamped to [-8.0, +8.0] (beyond this, output ≈ 0 or 1).
              Resolution: 16.0 / 256 = 0.0625 per entry.

        Algorithm:
          1. Clamp input to [-8, +8]
          2. Map to LUT index [0, 255]
          3. Look up pre-computed sigmoid value
        """
        x = self.to_float()

        # Clamp input range
        if x < -8.0:
            return self._make(0)
        if x > 8.0:
            return self._make(1 << self.frac_bits)  # 1.0 in fixed

        # Map to LUT index: [0, 255]
        # index = (x + 8) / 16 * 256 = (x + 8) * 16
        index = int((x + 8.0) * 16.0)
        if index < 0:
            index = 0
        if index > 255:
            index = 255

        # LUT lookup
        lut_value = _SIGMOID_LUT[index]
        return self._make(self._from_float(lut_value))

    def tanh_approx(self):
        """
        Tanh approximation: tanh(x) = 2*sigmoid(2x) - 1

        FPGA: Reuses sigmoid LUT with input shift and output offset.
        """
        # 2x input (shift left 1 in fixed-point)
        doubled = self._make(self.raw << 1)
        sig = doubled.sigmoid()
        # 2 * sig - 1
        two = FixedPoint(2.0, self.int_bits, self.frac_bits, self.overflow)
        one = FixedPoint(1.0, self.int_bits, self.frac_bits, self.overflow)
        return sig.multiply(two).sub(one)

    # ------------------------------------------------------------------
    # Comparison & utility
    # ------------------------------------------------------------------

    def _check_format(self, other):
        """Ensure both operands have the same format."""
        if self.int_bits != other.int_bits or self.frac_bits != other.frac_bits:
            raise ValueError(
                f"Format mismatch: Q{self.int_bits}.{self.frac_bits} vs "
                f"Q{other.int_bits}.{other.frac_bits}"
            )

    def to_binary(self):
        """Return binary string representation (two's complement)."""
        if self.raw >= 0:
            bits = bin(self.raw)[2:].zfill(self.total_bits)
        else:
            # Two's complement
            val = (1 << self.total_bits) + self.raw
            bits = bin(val)[2:].zfill(self.total_bits)
        return bits

    def to_hex(self):
        """Return hex string representation."""
        if self.raw >= 0:
            return hex(self.raw)
        val = (1 << self.total_bits) + self.raw
        return hex(val)

    def __repr__(self):
        return (
            f"FixedPoint(Q{self.int_bits}.{self.frac_bits}, "
            f"raw={self.raw}, float={self.to_float():.4f}, "
            f"bin={self.to_binary()})"
        )

    def __eq__(self, other):
        if isinstance(other, FixedPoint):
            return self.raw == other.raw
        return False


# =========================================================================
# SIGMOID LOOKUP TABLE (256 entries)
# =========================================================================
# Pre-computed: sigmoid(x) = 1/(1+exp(-x)) for x in [-8, +8]
# Step size: 16/256 = 0.0625
# FPGA: This becomes a ROM/BRAM initialization vector
# =========================================================================

def _generate_sigmoid_lut(size=256, x_min=-8.0, x_max=8.0):
    """Generate sigmoid LUT (run once at import time)."""
    lut = []
    step = (x_max - x_min) / size
    for i in range(size):
        x = x_min + i * step
        lut.append(1.0 / (1.0 + math.exp(-x)))
    return lut


_SIGMOID_LUT = _generate_sigmoid_lut()


# =========================================================================
# UTILITY FUNCTIONS
# =========================================================================

def fp_array(values, int_bits=8, frac_bits=8, overflow='saturate'):
    """Convert a list of floats to a list of FixedPoint numbers."""
    return [FixedPoint(v, int_bits, frac_bits, overflow) for v in values]


def fp_to_float_array(fp_list):
    """Convert a list of FixedPoint numbers back to floats."""
    return [fp.to_float() for fp in fp_list]


def fp_dot_product(a_list, b_list):
    """
    Fixed-point dot product (MAC chain).

    FPGA: Cascaded multiply-accumulate units.
    """
    if len(a_list) != len(b_list):
        raise ValueError("Length mismatch for dot product")
    if len(a_list) == 0:
        raise ValueError("Empty arrays for dot product")

    # Use first element's format
    ref = a_list[0]
    accumulator = FixedPoint(0.0, ref.int_bits, ref.frac_bits, ref.overflow)

    for a, b in zip(a_list, b_list):
        product = a.multiply(b)
        accumulator = accumulator.add(product)

    return accumulator


def fp_matrix_vector_multiply(matrix, vector):
    """
    Fixed-point matrix-vector multiplication.

    matrix: list of lists of FixedPoint (rows × cols)
    vector: list of FixedPoint (cols)

    FPGA: Parallel MAC units, one per output element.
    """
    result = []
    for row in matrix:
        result.append(fp_dot_product(row, vector))
    return result


def export_sigmoid_lut_vhdl(filename="sigmoid_lut.vhd", frac_bits=8):
    """
    Export sigmoid LUT as VHDL ROM initialization.

    Output: Ready-to-paste VHDL constant array.
    """
    lines = [
        "-- Auto-generated sigmoid LUT for FPGA",
        f"-- Format: Q8.{frac_bits}",
        f"-- Entries: {len(_SIGMOID_LUT)}",
        "type sigmoid_rom_t is array (0 to 255) of "
        f"std_logic_vector({7 + frac_bits} downto 0);",
        "constant SIGMOID_ROM : sigmoid_rom_t := (",
    ]

    scale = 1 << frac_bits
    for i, val in enumerate(_SIGMOID_LUT):
        raw = int(round(val * scale))
        raw = max(0, min(raw, (1 << (8 + frac_bits)) - 1))
        hex_str = f'x"{raw:0{(8 + frac_bits + 3) // 4}X}"'
        comma = "," if i < 255 else ""
        lines.append(f"    {i} => {hex_str}{comma}  -- sigmoid({-8 + i * 0.0625:.4f}) = {val:.6f}")

    lines.append(");")

    with open(filename, 'w') as f:
        f.write('\n'.join(lines))

    print(f"[EXPORT] VHDL sigmoid LUT written to {filename}")
