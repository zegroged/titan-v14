//! ★ P5 #44: Constant-Time Cryptographic Operations
//!
//! Side-channel saldırılarına karşı zamanlama-güvenli yardımcı fonksiyonlar.
//!
//! ## Güvenlik
//! - Tüm karşılaştırmalar sabit zamanda yapılır (timing attack önlemi)
//! - Conditional select dallanma olmadan çalışır
//! - MAC doğrulama early-exit yapmaz

use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};
use zeroize::Zeroize;

/// Constant-time byte slice equality comparison.
/// Returns true iff a == b, without early exit.
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let result: Choice = a.ct_eq(b);
    result.into()
}

/// Constant-time 32-byte array equality.
pub fn ct_eq_32(a: &[u8; 32], b: &[u8; 32]) -> bool {
    ct_eq(a.as_slice(), b.as_slice())
}

/// Constant-time MAC verification.
/// Compares computed MAC against expected MAC without timing leakage.
pub fn ct_verify_mac(computed: &[u8; 32], expected: &[u8; 32]) -> bool {
    ct_eq_32(computed, expected)
}

/// Constant-time conditional select for u8.
/// Returns `a` if choice is 0, `b` if choice is 1.
pub fn ct_select_u8(a: u8, b: u8, choice: bool) -> u8 {
    let c = Choice::from(choice as u8);
    u8::conditional_select(&a, &b, c)
}

/// Constant-time conditional select for u64.
pub fn ct_select_u64(a: u64, b: u64, choice: bool) -> u64 {
    let c = Choice::from(choice as u8);
    u64::conditional_select(&a, &b, c)
}

/// Constant-time conditional copy of byte slices.
/// Copies `src` into `dst` only if `choice` is true.
pub fn ct_copy(dst: &mut [u8], src: &[u8], choice: bool) {
    assert_eq!(dst.len(), src.len());
    let c = Choice::from(choice as u8);
    for (d, s) in dst.iter_mut().zip(src.iter()) {
        *d = u8::conditional_select(d, s, c);
    }
}

/// Constant-time byte comparison returning ordering-neutral bool.
/// True if all bytes match, false otherwise.
/// Unlike memcmp, this doesn't reveal WHICH byte differs.
pub fn ct_byte_compare(a: &[u8], b: &[u8]) -> bool {
    ct_eq(a, b)
}

/// Securely clear a mutable byte slice.
pub fn secure_zero(buf: &mut [u8]) {
    buf.zeroize();
}

/// Securely clear a 32-byte array.
pub fn secure_zero_32(buf: &mut [u8; 32]) {
    buf.zeroize();
}

// =============================================================================
// Tests
// =============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn t1_ct_eq_equal() {
        let a = [0xDE, 0xAD, 0xBE, 0xEF];
        let b = [0xDE, 0xAD, 0xBE, 0xEF];
        assert!(ct_eq(&a, &b));
    }

    #[test]
    fn t2_ct_eq_not_equal() {
        let a = [0xDE, 0xAD, 0xBE, 0xEF];
        let b = [0xDE, 0xAD, 0xBE, 0x00];
        assert!(!ct_eq(&a, &b));
    }

    #[test]
    fn t3_ct_eq_different_length() {
        let a = [0x01, 0x02, 0x03];
        let b = [0x01, 0x02];
        assert!(!ct_eq(&a, &b));
    }

    #[test]
    fn t4_ct_verify_mac() {
        let mac1 = [0xAA; 32];
        let mac2 = [0xAA; 32];
        let mac3 = [0xBB; 32];

        assert!(ct_verify_mac(&mac1, &mac2));
        assert!(!ct_verify_mac(&mac1, &mac3));
    }

    #[test]
    fn t5_ct_select_u8() {
        assert_eq!(ct_select_u8(10, 20, false), 10);
        assert_eq!(ct_select_u8(10, 20, true), 20);
    }

    #[test]
    fn t6_ct_select_u64() {
        assert_eq!(ct_select_u64(100, 200, false), 100);
        assert_eq!(ct_select_u64(100, 200, true), 200);
    }

    #[test]
    fn t7_ct_copy() {
        let mut dst = [0u8; 4];
        let src = [1, 2, 3, 4];

        ct_copy(&mut dst, &src, false);
        assert_eq!(dst, [0, 0, 0, 0]); // Not copied

        ct_copy(&mut dst, &src, true);
        assert_eq!(dst, [1, 2, 3, 4]); // Copied
    }

    #[test]
    fn t8_secure_zero() {
        let mut buf = [0xFF; 32];
        secure_zero_32(&mut buf);
        assert_eq!(buf, [0u8; 32]);
    }
}
