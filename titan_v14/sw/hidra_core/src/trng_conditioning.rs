//! ★ B-4: TRNG Hash Conditioning (SP800-90B §3.1.5.1.1)
//!
//! Raw entropy from hardware TRNG is conditioned through SHA-256
//! to ensure uniform distribution. This is a software-side
//! post-processing step applied to entropy received via SPI.
//!
//! NIST SP 800-90B: Raw entropy output MUST be hashed before use
//! as cryptographic randomness. Von Neumann alone (hardware side)
//! is not sufficient for full-entropy conditioning.

use sha2::{Sha256, Digest};

/// Hash-condition raw TRNG entropy into cryptographic randomness.
///
/// Takes raw entropy bytes from hardware TRNG and produces
/// `n` bytes of conditioned output using SHA-256 in counter mode.
///
/// Each 32 bytes of output = SHA-256(counter || raw_entropy)
pub fn condition_entropy(raw_entropy: &[u8], output_len: usize) -> Vec<u8> {
    let mut result = Vec::with_capacity(output_len);
    let mut counter: u32 = 0;

    while result.len() < output_len {
        let mut hasher = Sha256::new();
        hasher.update(counter.to_be_bytes());
        hasher.update(raw_entropy);
        let hash = hasher.finalize();

        let remaining = output_len - result.len();
        let take = remaining.min(32);
        result.extend_from_slice(&hash[..take]);
        counter += 1;
    }

    result
}

/// Condition exactly 32 bytes (256 bits) for a key
pub fn condition_key(raw_entropy: &[u8]) -> [u8; 32] {
    let mut key = [0u8; 32];
    let conditioned = condition_entropy(raw_entropy, 32);
    key.copy_from_slice(&conditioned);
    key
}

/// Condition exactly 16 bytes (128 bits) for an IV/nonce
pub fn condition_iv(raw_entropy: &[u8]) -> [u8; 16] {
    let mut iv = [0u8; 16];
    // Use different domain separator from key conditioning
    let mut hasher = Sha256::new();
    hasher.update(b"HIDRA-IV-CONDITION");
    hasher.update(raw_entropy);
    let hash = hasher.finalize();
    iv.copy_from_slice(&hash[..16]);
    iv
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_condition_entropy_length() {
        let raw = [0x42u8; 64];
        let out = condition_entropy(&raw, 48);
        assert_eq!(out.len(), 48);
    }

    #[test]
    fn test_condition_key_deterministic() {
        let raw = [0xABu8; 128];
        let k1 = condition_key(&raw);
        let k2 = condition_key(&raw);
        assert_eq!(k1, k2);
    }

    #[test]
    fn test_condition_key_differs_from_iv() {
        let raw = [0x55u8; 64];
        let key = condition_key(&raw);
        let iv = condition_iv(&raw);
        assert_ne!(&key[..16], &iv[..]);
    }

    #[test]
    fn test_different_entropy_different_output() {
        let k1 = condition_key(&[0x11u8; 64]);
        let k2 = condition_key(&[0x22u8; 64]);
        assert_ne!(k1, k2);
    }
}
