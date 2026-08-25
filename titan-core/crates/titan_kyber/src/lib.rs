//! Titan Kyber — PQC Key Encapsulation Mechanism
//!
//! Wraps pqcrypto-kyber (Kyber-1024, NIST Level 5).
//! Used for: initial handshake, DH ratchet turns, Root Key rotation.

use pqcrypto_kyber::kyber1024;
use pqcrypto_traits::kem::{Ciphertext, PublicKey, SecretKey, SharedSecret};
use zeroize::Zeroize;

/// Kyber-1024 key pair.
pub struct KyberKeyPair {
    pub public_key: Vec<u8>,
    secret_key: Vec<u8>,
}

impl KyberKeyPair {
    /// Generate a new Kyber-1024 key pair.
    pub fn generate() -> Self {
        let (pk, sk) = kyber1024::keypair();
        Self {
            public_key: pk.as_bytes().to_vec(),
            secret_key: sk.as_bytes().to_vec(),
        }
    }

    /// Get the secret key bytes (for decapsulation).
    pub fn secret_key_bytes(&self) -> &[u8] {
        &self.secret_key
    }
}

impl Drop for KyberKeyPair {
    fn drop(&mut self) {
        self.secret_key.zeroize();
    }
}

/// Result of encapsulation: ciphertext + shared secret.
pub struct EncapsulationResult {
    pub ciphertext: Vec<u8>,
    shared_secret: Vec<u8>,
}

impl EncapsulationResult {
    /// Get the shared secret bytes.
    pub fn shared_secret(&self) -> &[u8] {
        &self.shared_secret
    }
}

impl Drop for EncapsulationResult {
    fn drop(&mut self) {
        self.shared_secret.zeroize();
    }
}

/// Encapsulate: generate shared secret using recipient's public key.
/// Returns ciphertext (to send) + shared secret (to keep).
pub fn encapsulate(public_key_bytes: &[u8]) -> Result<EncapsulationResult, &'static str> {
    let pk = kyber1024::PublicKey::from_bytes(public_key_bytes)
        .map_err(|_| "Invalid Kyber public key")?;
    let (ss, ct) = kyber1024::encapsulate(&pk);
    Ok(EncapsulationResult {
        ciphertext: ct.as_bytes().to_vec(),
        shared_secret: ss.as_bytes().to_vec(),
    })
}

/// Decapsulate: recover shared secret from ciphertext using secret key.
pub fn decapsulate(
    secret_key_bytes: &[u8],
    ciphertext_bytes: &[u8],
) -> Result<Vec<u8>, &'static str> {
    let sk = kyber1024::SecretKey::from_bytes(secret_key_bytes)
        .map_err(|_| "Invalid Kyber secret key")?;
    let ct = kyber1024::Ciphertext::from_bytes(ciphertext_bytes)
        .map_err(|_| "Invalid Kyber ciphertext")?;
    let ss = kyber1024::decapsulate(&ct, &sk);
    Ok(ss.as_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keygen_encapsulate_decapsulate() {
        let kp = KyberKeyPair::generate();

        // Encapsulate with public key
        let enc = encapsulate(&kp.public_key).expect("encapsulate failed");

        // Decapsulate with secret key
        let ss = decapsulate(kp.secret_key_bytes(), &enc.ciphertext)
            .expect("decapsulate failed");

        // Shared secrets must match
        assert_eq!(enc.shared_secret(), &ss[..]);
    }

    #[test]
    fn test_different_keypairs_different_secrets() {
        let kp1 = KyberKeyPair::generate();
        let kp2 = KyberKeyPair::generate();
        assert_ne!(kp1.public_key, kp2.public_key);
    }

    #[test]
    fn test_invalid_public_key() {
        let result = encapsulate(&[0u8; 32]);
        assert!(result.is_err());
    }
}
