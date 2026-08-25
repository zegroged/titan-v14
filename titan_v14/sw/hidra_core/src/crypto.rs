//! Layer 1: AES-256-GCM-SIV — Nonce-Misuse Resistant AEAD
//!
//! Why GCM-SIV over GCM?
//! - GCM: If nonce is EVER reused, authentication is completely broken (catastrophic)
//! - GCM-SIV: If nonce is reused, only reveals whether two plaintexts are identical
//!            — confidentiality and authentication survive nonce misuse
//!
//! This is Layer 1 of the triple-layer encryption stack.
//! Layer 2 (TITAN AES-256-CTR) is handled via SPI in titan_spi.rs.
//! Layer 3 (XChaCha20-Poly1305) is in transport_crypto.rs.

use aes_gcm_siv::{
    Aes256GcmSiv, Key, Nonce,
    aead::{Aead, KeyInit, OsRng},
};
use rand::RngCore;
use zeroize::Zeroize;

use crate::HidraError;

/// Maximum plaintext size per message (4 KiB)
pub const MAX_PLAINTEXT_SIZE: usize = 4096;

/// AES-256-GCM-SIV nonce size (96 bits)
const NONCE_SIZE: usize = 12;

/// Layer 1 encrypted message format:
/// [nonce: 12 bytes][ciphertext + tag: N + 16 bytes]
#[derive(Clone)]
pub struct Layer1Envelope {
    pub nonce: [u8; NONCE_SIZE],
    pub ciphertext: Vec<u8>, // includes 16-byte auth tag
}

impl Layer1Envelope {
    /// Serialize to wire format
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(NONCE_SIZE + self.ciphertext.len());
        buf.extend_from_slice(&self.nonce);
        buf.extend_from_slice(&self.ciphertext);
        buf
    }

    /// Deserialize from wire format
    pub fn from_bytes(data: &[u8]) -> Result<Self, HidraError> {
        if data.len() < NONCE_SIZE + 16 {
            return Err(HidraError::ProtocolError(
                "Layer1 envelope too short".to_string(),
            ));
        }
        let mut nonce = [0u8; NONCE_SIZE];
        nonce.copy_from_slice(&data[..NONCE_SIZE]);
        let ciphertext = data[NONCE_SIZE..].to_vec();
        Ok(Self { nonce, ciphertext })
    }
}

/// AES-256-GCM-SIV cipher engine
/// ★ H-6 FIX: ManuallyDrop kaldırıldı — UB-adjacent raw pointer zeroing yerine
/// safe zeroize + normal Drop kullanılıyor.
pub struct Layer1Cipher {
    cipher: Aes256GcmSiv,
    /// Raw key bytes — zeroized on drop
    key_bytes: [u8; 32],
}

impl Drop for Layer1Cipher {
    fn drop(&mut self) {
        // Zeroize the raw key bytes (safe, no UB)
        self.key_bytes.zeroize();
        // cipher drops normally — internal round keys freed by allocator
        // No ManuallyDrop, no raw pointer manipulation, no UB risk
    }
}

impl Layer1Cipher {
    /// Create from a 256-bit key
    pub fn new(key: &[u8; 32]) -> Self {
        let aes_key = Key::<Aes256GcmSiv>::from_slice(key);
        Self {
            cipher: Aes256GcmSiv::new(aes_key),
            key_bytes: *key,
        }
    }

    /// Generate a new random cipher
    pub fn generate() -> Self {
        let mut key_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut key_bytes);
        let result = Self::new(&key_bytes);
        key_bytes.zeroize();
        result
    }

    /// Encrypt plaintext → Layer1Envelope
    ///
    /// Each call generates a fresh random nonce.
    /// Even with GCM-SIV's nonce-misuse resistance, we still use random nonces
    /// for defense-in-depth.
    pub fn encrypt(&self, plaintext: &[u8]) -> Result<Layer1Envelope, HidraError> {
        if plaintext.len() > MAX_PLAINTEXT_SIZE {
            return Err(HidraError::MessageTooLarge {
                size: plaintext.len(),
                max: MAX_PLAINTEXT_SIZE,
            });
        }

        // Generate random nonce (96-bit)
        let mut nonce_bytes = [0u8; NONCE_SIZE];
        OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        // Encrypt with AEAD (ciphertext includes 16-byte auth tag)
        let ciphertext = self
            .cipher
            .encrypt(nonce, plaintext)
            .map_err(|_| HidraError::Layer1EncryptFailed)?;

        Ok(Layer1Envelope {
            nonce: nonce_bytes,
            ciphertext,
        })
    }

    /// Decrypt Layer1Envelope → plaintext
    ///
    /// Verifies the 128-bit authentication tag. Returns error if tampered.
    pub fn decrypt(&self, envelope: &Layer1Envelope) -> Result<Vec<u8>, HidraError> {
        let nonce = Nonce::from_slice(&envelope.nonce);

        self.cipher
            .decrypt(nonce, envelope.ciphertext.as_ref())
            .map_err(|_| HidraError::Layer1DecryptFailed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let cipher = Layer1Cipher::generate();
        let plaintext = b"PROJECT HIDRA - Paranoid-Grade Secure Communication";

        let envelope = cipher.encrypt(plaintext).unwrap();
        let decrypted = cipher.decrypt(&envelope).unwrap();

        assert_eq!(plaintext.as_slice(), decrypted.as_slice());
    }

    #[test]
    fn test_different_nonces_each_call() {
        let cipher = Layer1Cipher::generate();
        let plaintext = b"same message";

        let env1 = cipher.encrypt(plaintext).unwrap();
        let env2 = cipher.encrypt(plaintext).unwrap();

        // Nonces should differ (random)
        assert_ne!(env1.nonce, env2.nonce);
        // Ciphertexts should differ (different nonces)
        assert_ne!(env1.ciphertext, env2.ciphertext);
    }

    #[test]
    fn test_tampered_ciphertext_fails() {
        let cipher = Layer1Cipher::generate();
        let plaintext = b"tamper test";

        let mut envelope = cipher.encrypt(plaintext).unwrap();
        // Flip a bit in ciphertext
        envelope.ciphertext[0] ^= 0x01;

        let result = cipher.decrypt(&envelope);
        assert!(result.is_err());
    }

    #[test]
    fn test_wrong_key_fails() {
        let cipher1 = Layer1Cipher::generate();
        let cipher2 = Layer1Cipher::generate();
        let plaintext = b"wrong key test";

        let envelope = cipher1.encrypt(plaintext).unwrap();
        let result = cipher2.decrypt(&envelope);
        assert!(result.is_err());
    }

    #[test]
    fn test_max_size_enforcement() {
        let cipher = Layer1Cipher::generate();
        let oversized = vec![0u8; MAX_PLAINTEXT_SIZE + 1];

        let result = cipher.encrypt(&oversized);
        assert!(matches!(result, Err(HidraError::MessageTooLarge { .. })));
    }

    #[test]
    fn test_serialization_roundtrip() {
        let cipher = Layer1Cipher::generate();
        let plaintext = b"serialization test";

        let envelope = cipher.encrypt(plaintext).unwrap();
        let bytes = envelope.to_bytes();
        let recovered = Layer1Envelope::from_bytes(&bytes).unwrap();
        let decrypted = cipher.decrypt(&recovered).unwrap();

        assert_eq!(plaintext.as_slice(), decrypted.as_slice());
    }
}

/// ★ Property-Based Tests (proptest)
/// Verifies encrypt/decrypt roundtrip holds ∀ arbitrary plaintext
#[cfg(test)]
mod proptest_tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn prop_layer1_roundtrip(plaintext in proptest::collection::vec(any::<u8>(), 0..4096)) {
            let cipher = Layer1Cipher::generate();
            let envelope = cipher.encrypt(&plaintext).unwrap();
            let decrypted = cipher.decrypt(&envelope).unwrap();
            prop_assert_eq!(plaintext, decrypted);
        }

        #[test]
        fn prop_layer1_serialization_roundtrip(plaintext in proptest::collection::vec(any::<u8>(), 0..4096)) {
            let cipher = Layer1Cipher::generate();
            let envelope = cipher.encrypt(&plaintext).unwrap();
            let bytes = envelope.to_bytes();
            let recovered = Layer1Envelope::from_bytes(&bytes).unwrap();
            let decrypted = cipher.decrypt(&recovered).unwrap();
            prop_assert_eq!(plaintext, decrypted);
        }

        #[test]
        fn prop_layer1_unique_nonces(plaintext in proptest::collection::vec(any::<u8>(), 1..128)) {
            let cipher = Layer1Cipher::generate();
            let env1 = cipher.encrypt(&plaintext).unwrap();
            let env2 = cipher.encrypt(&plaintext).unwrap();
            // Same plaintext must produce different nonces
            prop_assert_ne!(env1.nonce, env2.nonce);
        }
    }
}
