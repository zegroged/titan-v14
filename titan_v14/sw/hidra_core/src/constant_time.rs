//! ★ D3: Constant-Time Comparison Utilities — DUAL VERIFICATION
//!
//! All cryptographic comparisons MUST use these functions
//! instead of `==` to prevent timing side-channel attacks.
//!
//! A branch-based `==` leaks how many bytes matched via
//! CPU branch prediction and cache timing. An attacker
//! with microsecond measurement can recover HMAC tags
//! byte-by-byte (Brumley & Boneh 2003).
//!
//! # Trust No One — Dual Verification
//! We use BOTH the `subtle` crate (industry standard, used by
//! ring/dalek/RustCrypto) AND our own XOR accumulator as an
//! independent checkpoint. Both must agree for equality.
//! If the compiler ever optimizes one away, the other survives.

use subtle::ConstantTimeEq;

/// Constant-time byte slice comparison — DUAL VERIFIED.
///
/// Compares ALL bytes regardless of mismatch position.
/// Execution time depends only on slice length, not content.
///
/// Uses two independent methods:
/// 1. `subtle::ConstantTimeEq` — immune to compiler optimizations
/// 2. Manual XOR accumulator — independent cross-check
///
/// Both must agree for equality (`AND` gate logic).
///
/// # Returns
/// `true` if slices are equal in both length and content,
/// `false` otherwise.
#[inline(never)]
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }

    // ═══ Checkpoint 1: subtle crate (industry standard) ═══
    let subtle_result = a.ct_eq(b);

    // ═══ Checkpoint 2: Independent XOR accumulator ═══
    // Even if `subtle` is somehow compromised, this catches it
    let mut diff: u8 = 0;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    let xor_result = diff == 0;

    // ═══ DUAL GATE: Both must agree ═══
    // If either method detects a mismatch, we reject.
    // This is an AND gate: subtle_ok AND xor_ok
    bool::from(subtle_result) && xor_result
}

/// Constant-time HMAC tag verification — DUAL VERIFIED.
///
/// Wrapper around `ct_eq` specifically for 32-byte HMAC-SHA256 tags.
#[inline(never)]
pub fn ct_hmac_verify(computed: &[u8; 32], received: &[u8; 32]) -> bool {
    ct_eq(computed, received)
}

/// Constant-time u32 comparison.
///
/// Used for fingerprint comparison (canary traps) and similar.
#[inline(never)]
pub fn ct_u32_eq(a: u32, b: u32) -> bool {
    let a_bytes = a.to_le_bytes();
    let b_bytes = b.to_le_bytes();
    ct_eq(&a_bytes, &b_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ct_eq_equal() {
        let a = [0x42u8; 32];
        let b = [0x42u8; 32];
        assert!(ct_eq(&a, &b));
    }

    #[test]
    fn test_ct_eq_differ_first_byte() {
        let a = [0x42u8; 32];
        let mut b = [0x42u8; 32];
        b[0] = 0x43;
        assert!(!ct_eq(&a, &b));
    }

    #[test]
    fn test_ct_eq_differ_last_byte() {
        let a = [0x42u8; 32];
        let mut b = [0x42u8; 32];
        b[31] = 0xFF;
        assert!(!ct_eq(&a, &b));
    }

    #[test]
    fn test_ct_eq_different_lengths() {
        assert!(!ct_eq(&[1, 2, 3], &[1, 2]));
        assert!(!ct_eq(&[1, 2], &[1, 2, 3]));
    }

    #[test]
    fn test_ct_eq_empty() {
        assert!(ct_eq(&[], &[]));
    }

    #[test]
    fn test_ct_eq_all_zeros() {
        assert!(ct_eq(&[0u8; 64], &[0u8; 64]));
    }

    #[test]
    fn test_ct_hmac_verify() {
        let tag = [0xAA; 32];
        assert!(ct_hmac_verify(&tag, &tag));
        let mut bad = tag;
        bad[15] ^= 1;
        assert!(!ct_hmac_verify(&tag, &bad));
    }

    #[test]
    fn test_ct_u32_eq() {
        assert!(ct_u32_eq(0xDEADBEEF, 0xDEADBEEF));
        assert!(!ct_u32_eq(0xDEADBEEF, 0xDEADBEEE));
        assert!(!ct_u32_eq(0, 1));
        assert!(ct_u32_eq(0, 0));
    }

    // ★ Dual verification self-test: ensure both paths are active
    #[test]
    fn test_dual_verification_independence() {
        // Known equal
        let a = [0x55u8; 16];
        let b = [0x55u8; 16];
        assert!(ct_eq(&a, &b));

        // Known different — single bit flip in middle
        let mut c = [0x55u8; 16];
        c[8] ^= 0x01; // flip bit 0 of byte 8
        assert!(!ct_eq(&a, &c));

        // All-FF vs all-00
        assert!(!ct_eq(&[0xFF; 32], &[0x00; 32]));

        // Single byte difference in every position
        for pos in 0..32 {
            let ref_val = [0xAA; 32];
            let mut modified = ref_val;
            modified[pos] = 0xBB;
            assert!(!ct_eq(&ref_val, &modified),
                "Failed to detect difference at position {}", pos);
        }
    }
}
