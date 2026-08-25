//! Titan Dilithium — PQC Digital Signatures (ML-DSA)
//!
//! Wraps pqcrypto-dilithium (Dilithium Level 5 / ML-DSA-87).
//! Used ONLY for: handshake, ratchet turn, group operations.
//! NOT used for every message (Poly1305 MAC suffices).

use pqcrypto_dilithium::dilithium5;
use pqcrypto_traits::sign::{DetachedSignature, PublicKey, SecretKey};
use zeroize::Zeroize;

/// Dilithium-5 signing key pair.
pub struct DilithiumKeyPair {
    pub public_key: Vec<u8>,
    secret_key: Vec<u8>,
}

impl DilithiumKeyPair {
    /// Generate a new Dilithium-5 key pair.
    pub fn generate() -> Self {
        let (pk, sk) = dilithium5::keypair();
        Self {
            public_key: pk.as_bytes().to_vec(),
            secret_key: sk.as_bytes().to_vec(),
        }
    }

    /// Sign a message with the secret key (detached signature).
    pub fn sign(&self, message: &[u8]) -> Vec<u8> {
        let sk = dilithium5::SecretKey::from_bytes(&self.secret_key)
            .expect("internal: invalid secret key");
        let sig = dilithium5::detached_sign(message, &sk);
        sig.as_bytes().to_vec()
    }
}

impl Drop for DilithiumKeyPair {
    fn drop(&mut self) {
        self.secret_key.zeroize();
    }
}

/// Verify a detached signature against a public key.
pub fn verify(
    public_key_bytes: &[u8],
    message: &[u8],
    signature_bytes: &[u8],
) -> Result<(), &'static str> {
    let pk = dilithium5::PublicKey::from_bytes(public_key_bytes)
        .map_err(|_| "Invalid Dilithium public key")?;
    let sig = dilithium5::DetachedSignature::from_bytes(signature_bytes)
        .map_err(|_| "Invalid Dilithium signature")?;
    dilithium5::verify_detached_signature(&sig, message, &pk)
        .map_err(|_| "Signature verification failed")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sign_and_verify() {
        let kp = DilithiumKeyPair::generate();
        let msg = b"Titan Mobile Protocol Handshake";
        let sig = kp.sign(msg);
        verify(&kp.public_key, msg, &sig).expect("valid signature should verify");
    }

    #[test]
    fn test_tampered_message_fails() {
        let kp = DilithiumKeyPair::generate();
        let msg = b"Original message";
        let sig = kp.sign(msg);
        let tampered = b"Tampered message";
        assert!(verify(&kp.public_key, tampered, &sig).is_err());
    }

    #[test]
    fn test_wrong_key_fails() {
        let kp1 = DilithiumKeyPair::generate();
        let kp2 = DilithiumKeyPair::generate();
        let msg = b"test";
        let sig = kp1.sign(msg);
        assert!(verify(&kp2.public_key, msg, &sig).is_err());
    }

    #[test]
    fn test_invalid_public_key() {
        assert!(verify(&[0u8; 32], b"test", &[0u8; 64]).is_err());
    }
}
