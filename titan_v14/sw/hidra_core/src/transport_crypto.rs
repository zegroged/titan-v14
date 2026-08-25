//! Layer 3: XChaCha20-Poly1305 — Transport Encryption
//!
//! This provides **algorithmic diversity** in the encryption stack:
//! - Layer 1: AES (Rijndael family — substitution-permutation network)
//! - Layer 2: AES (TITAN FPGA hardware — same algorithm, different implementation)
//! - Layer 3: ChaCha20 (Salsa family — ARX cipher, completely different design)
//!
//! Why XChaCha20 (not ChaCha20)?
//! - Standard ChaCha20: 96-bit nonce → birthday bound collision risk at 2^48 messages
//! - XChaCha20: 192-bit nonce → collision risk at 2^96 messages (practically impossible)
//! - No need for a nonce counter — random nonces are safe forever
//!
//! This layer wraps the already-doubly-encrypted blob before transmitting
//! over Hydra MQTT / Tor, ensuring that even if the transport is compromised,
//! the inner AES layers remain intact.

use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, OsRng},
};
use rand::RngCore;
use zeroize::Zeroize;

use crate::HidraError;

/// XChaCha20 nonce size (192 bits = 24 bytes)
const XCHACHA_NONCE_SIZE: usize = 24;

/// Layer 3 transport envelope:
/// [nonce: 24 bytes][ciphertext + Poly1305 tag: N + 16 bytes]
#[derive(Clone)]
pub struct TransportEnvelope {
    pub nonce: [u8; XCHACHA_NONCE_SIZE],
    pub ciphertext: Vec<u8>, // includes 16-byte Poly1305 tag
}

impl TransportEnvelope {
    /// Serialize to wire format
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(XCHACHA_NONCE_SIZE + self.ciphertext.len());
        buf.extend_from_slice(&self.nonce);
        buf.extend_from_slice(&self.ciphertext);
        buf
    }

    /// Deserialize from wire format
    pub fn from_bytes(data: &[u8]) -> Result<Self, HidraError> {
        if data.len() < XCHACHA_NONCE_SIZE + 16 {
            return Err(HidraError::ProtocolError(
                "Transport envelope too short".to_string(),
            ));
        }
        let mut nonce = [0u8; XCHACHA_NONCE_SIZE];
        nonce.copy_from_slice(&data[..XCHACHA_NONCE_SIZE]);
        let ciphertext = data[XCHACHA_NONCE_SIZE..].to_vec();
        Ok(Self { nonce, ciphertext })
    }
}

/// XChaCha20-Poly1305 transport cipher
/// ★ H-6 FIX: ManuallyDrop kaldırıldı — safe zeroize + normal Drop
pub struct TransportCipher {
    cipher: XChaCha20Poly1305,
    key_bytes: [u8; 32],
}

impl Drop for TransportCipher {
    fn drop(&mut self) {
        self.key_bytes.zeroize();
        // cipher drops normally — no ManuallyDrop, no raw pointer, no UB
    }
}

impl TransportCipher {
    /// Create from a 256-bit key
    pub fn new(key: &[u8; 32]) -> Self {
        let cha_key = chacha20poly1305::Key::from_slice(key);
        Self {
            cipher: XChaCha20Poly1305::new(cha_key),
            key_bytes: *key,
        }
    }

    /// Generate a new random transport cipher
    pub fn generate() -> Self {
        let mut key_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut key_bytes);
        let result = Self::new(&key_bytes);
        key_bytes.zeroize();
        result
    }

    /// Encrypt data for transport → TransportEnvelope
    ///
    /// Uses random 192-bit nonce. With XChaCha20's extended nonce space,
    /// the birthday bound collision probability is ~2^-96 even after 2^48 messages.
    pub fn encrypt(&self, data: &[u8]) -> Result<TransportEnvelope, HidraError> {
        // Generate random 192-bit nonce
        let mut nonce_bytes = [0u8; XCHACHA_NONCE_SIZE];
        OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = XNonce::from_slice(&nonce_bytes);

        let ciphertext = self
            .cipher
            .encrypt(nonce, data)
            .map_err(|_| HidraError::Layer3EncryptFailed)?;

        Ok(TransportEnvelope {
            nonce: nonce_bytes,
            ciphertext,
        })
    }

    /// Decrypt transport envelope → plaintext
    pub fn decrypt(&self, envelope: &TransportEnvelope) -> Result<Vec<u8>, HidraError> {
        let nonce = XNonce::from_slice(&envelope.nonce);

        self.cipher
            .decrypt(nonce, envelope.ciphertext.as_ref())
            .map_err(|_| HidraError::Layer3DecryptFailed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_transport_roundtrip() {
        let cipher = TransportCipher::generate();
        let data = b"Triple-encrypted transport payload via Tor + MQTT mesh";

        let envelope = cipher.encrypt(data).unwrap();
        let decrypted = cipher.decrypt(&envelope).unwrap();

        assert_eq!(data.as_slice(), decrypted.as_slice());
    }

    #[test]
    fn test_192bit_nonce_uniqueness() {
        let cipher = TransportCipher::generate();
        let data = b"nonce test";

        // Generate 100 envelopes, all nonces must be unique
        let envelopes: Vec<_> = (0..100)
            .map(|_| cipher.encrypt(data).unwrap())
            .collect();

        for i in 0..envelopes.len() {
            for j in (i + 1)..envelopes.len() {
                assert_ne!(envelopes[i].nonce, envelopes[j].nonce);
            }
        }
    }

    #[test]
    fn test_transport_tamper_detection() {
        let cipher = TransportCipher::generate();
        let data = b"tamper me";

        let mut envelope = cipher.encrypt(data).unwrap();
        envelope.ciphertext[5] ^= 0xFF;

        assert!(cipher.decrypt(&envelope).is_err());
    }

    #[test]
    fn test_transport_serialization() {
        let cipher = TransportCipher::generate();
        let data = b"serialize me over the wire";

        let envelope = cipher.encrypt(data).unwrap();
        let bytes = envelope.to_bytes();
        let recovered = TransportEnvelope::from_bytes(&bytes).unwrap();
        let decrypted = cipher.decrypt(&recovered).unwrap();

        assert_eq!(data.as_slice(), decrypted.as_slice());
    }
}
