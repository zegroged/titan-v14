//! Titan Entropy Pool
//!
//! Faz 1: OS CSPRNG placeholder.
//! Faz 3: Sensor harvesting + USB TRNG + SHA-3 mixing.

use rand::rngs::OsRng;
use rand::RngCore;
use zeroize::Zeroize;

/// Trait for entropy sources — future sensor/USB TRNG implementations.
pub trait EntropySource {
    fn fill_bytes(&mut self, dest: &mut [u8]);
}

/// OS CSPRNG-based entropy (placeholder for Faz 1).
pub struct OsEntropy;

impl EntropySource for OsEntropy {
    fn fill_bytes(&mut self, dest: &mut [u8]) {
        OsRng.fill_bytes(dest);
    }
}

/// Generate a 256-bit cryptographic seed.
pub fn generate_seed() -> [u8; 32] {
    let mut seed = [0u8; 32];
    OsRng.fill_bytes(&mut seed);
    seed
}

/// Generate random padding bytes (for envelope padding — never zeros).
pub fn random_padding(len: usize) -> Vec<u8> {
    let mut buf = vec![0u8; len];
    OsRng.fill_bytes(&mut buf);
    buf
}

/// Securely zeroize a seed after use.
pub fn zeroize_seed(seed: &mut [u8; 32]) {
    seed.zeroize();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_seed_not_zero() {
        let seed = generate_seed();
        assert_ne!(seed, [0u8; 32], "Seed must not be all zeros");
    }

    #[test]
    fn test_generate_seed_unique() {
        let s1 = generate_seed();
        let s2 = generate_seed();
        assert_ne!(s1, s2, "Two seeds must differ");
    }

    #[test]
    fn test_random_padding_correct_length() {
        let pad = random_padding(512);
        assert_eq!(pad.len(), 512);
    }

    #[test]
    fn test_random_padding_not_zeros() {
        let pad = random_padding(64);
        assert!(pad.iter().any(|&b| b != 0), "Padding must not be all zeros");
    }

    #[test]
    fn test_zeroize_seed() {
        let mut seed = generate_seed();
        zeroize_seed(&mut seed);
        assert_eq!(seed, [0u8; 32], "Seed must be zeroed after zeroize");
    }
}
