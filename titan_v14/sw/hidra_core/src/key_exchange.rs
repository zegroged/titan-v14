//! Hybrid Key Exchange: X25519 (Classical) + Kyber-768 (Post-Quantum)
//!
//! # Why Hybrid?
//! - X25519 alone: Broken by quantum computers (Shor's algorithm, ~4000 logical qubits)
//! - Kyber-768 alone: New algorithm, may have undiscovered vulnerabilities
//! - Hybrid (X25519 || Kyber-768): If EITHER survives, the key is secure
//!
//! # Protocol Flow
//! ```text
//! Alice                                    Bob
//!   │                                       │
//!   ├─ x25519_pub ──────────────────────►   │
//!   ├─ kyber_pub  ──────────────────────►   │
//!   │                                       │
//!   │   ◄────────────────────── x25519_pub ─┤
//!   │   ◄────────────── kyber_ciphertext ───┤
//!   │                                       │
//!   │  shared = HKDF(x25519_ss || kyber_ss) │
//! ```
//!
//! # Key Derivation
//! From the combined shared secret, we derive 3 independent keys using HKDF:
//! - Layer 1 key: AES-256-GCM-SIV (32 bytes)
//! - Layer 3 key: XChaCha20-Poly1305 (32 bytes)
//! - Ratchet root key: Double Ratchet seed (32 bytes)

use x25519_dalek::{EphemeralSecret, PublicKey as X25519Public};
use pqcrypto_kyber::kyber768;
use pqcrypto_traits::kem::{Ciphertext, PublicKey, SecretKey, SharedSecret as KyberSS};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop};
use rand_core::OsRng;
use serde::{Serialize, Deserialize};

use crate::HidraError;

/// HKDF info strings for domain separation
const HKDF_INFO_LAYER1: &[u8] = b"HIDRA-v1-Layer1-AES256-GCM-SIV";
const HKDF_INFO_LAYER3: &[u8] = b"HIDRA-v1-Layer3-XChaCha20-Poly1305";
const HKDF_INFO_RATCHET: &[u8] = b"HIDRA-v1-Ratchet-Root-Key";

/// Derived session keys from hybrid key exchange
#[derive(ZeroizeOnDrop)]
pub struct SessionKeys {
    /// Layer 1 key: AES-256-GCM-SIV (32 bytes)
    pub layer1_key: [u8; 32],
    /// Layer 3 key: XChaCha20-Poly1305 (32 bytes)
    pub layer3_key: [u8; 32],
    /// Double Ratchet root key (32 bytes)
    pub ratchet_root: [u8; 32],
}

/// Alice's key exchange state (initiator)
pub struct AliceKeyExchange {
    x25519_secret: Option<EphemeralSecret>,
    x25519_public: X25519Public,
    kyber_public: Vec<u8>,
    kyber_secret: Vec<u8>,
}

/// ★ SECURITY FIX: Zeroize Kyber key material on drop
impl Drop for AliceKeyExchange {
    fn drop(&mut self) {
        self.kyber_secret.zeroize();
        self.kyber_public.zeroize();
    }
}

/// Bob's key exchange response
#[derive(Serialize, Deserialize, Clone)]
pub struct KeyExchangeResponse {
    pub x25519_public: [u8; 32],
    pub kyber_ciphertext: Vec<u8>,
}

/// Alice's initial key exchange message
#[derive(Serialize, Deserialize, Clone)]
pub struct KeyExchangeInit {
    pub x25519_public: [u8; 32],
    pub kyber_public: Vec<u8>,
}

impl AliceKeyExchange {
    /// Generate Alice's ephemeral keys (X25519 + Kyber-768)
    pub fn new() -> Self {
        // X25519 ephemeral keypair
        let x25519_secret = EphemeralSecret::random_from_rng(OsRng);
        let x25519_public = X25519Public::from(&x25519_secret);

        // Kyber-768 keypair
        let (kyber_pk, kyber_sk) = kyber768::keypair();

        Self {
            x25519_secret: Some(x25519_secret),
            x25519_public,
            kyber_public: kyber_pk.as_bytes().to_vec(),
            kyber_secret: kyber_sk.as_bytes().to_vec(),
        }
    }

    /// Get the init message to send to Bob
    pub fn get_init_message(&self) -> KeyExchangeInit {
        KeyExchangeInit {
            x25519_public: self.x25519_public.to_bytes(),
            kyber_public: self.kyber_public.clone(),
        }
    }

    /// Complete key exchange with Bob's response → derive session keys
    pub fn complete(mut self, response: &KeyExchangeResponse) -> Result<SessionKeys, HidraError> {
        // X25519 shared secret — take() moves the secret out of Option
        let x25519_secret = self.x25519_secret.take()
            .ok_or_else(|| HidraError::KeyExchangeFailed("X25519 secret already consumed".to_string()))?;
        let bob_x25519 = X25519Public::from(response.x25519_public);
        let x25519_ss = x25519_secret.diffie_hellman(&bob_x25519);

        // Kyber-768 decapsulate
        let kyber_ct = kyber768::Ciphertext::from_bytes(&response.kyber_ciphertext)
            .map_err(|_| HidraError::KeyExchangeFailed("Invalid Kyber ciphertext".to_string()))?;
        let kyber_sk = kyber768::SecretKey::from_bytes(&self.kyber_secret)
            .map_err(|_| HidraError::KeyExchangeFailed("Invalid Kyber secret key".to_string()))?;
        let kyber_ss = kyber768::decapsulate(&kyber_ct, &kyber_sk);

        // Combine shared secrets: HKDF-SHA256(X25519_ss || Kyber_ss)
        derive_session_keys(x25519_ss.as_bytes(), kyber_ss.as_bytes())
    }
}

/// Bob's side of the key exchange (responder)
pub struct BobKeyExchange;

impl BobKeyExchange {
    /// Process Alice's init message and generate response + session keys
    pub fn respond(init: &KeyExchangeInit) -> Result<(KeyExchangeResponse, SessionKeys), HidraError> {
        // X25519: Generate Bob's ephemeral keypair
        let bob_secret = EphemeralSecret::random_from_rng(OsRng);
        let bob_public = X25519Public::from(&bob_secret);

        // X25519 shared secret
        let alice_x25519 = X25519Public::from(init.x25519_public);
        let x25519_ss = bob_secret.diffie_hellman(&alice_x25519);

        // Kyber-768: Encapsulate with Alice's public key
        let alice_kyber_pk = kyber768::PublicKey::from_bytes(&init.kyber_public)
            .map_err(|_| HidraError::KeyExchangeFailed("Invalid Kyber public key".to_string()))?;
        let (kyber_ss, kyber_ct) = kyber768::encapsulate(&alice_kyber_pk);

        // Derive session keys
        let keys = derive_session_keys(x25519_ss.as_bytes(), kyber_ss.as_bytes())?;

        let response = KeyExchangeResponse {
            x25519_public: bob_public.to_bytes(),
            kyber_ciphertext: kyber_ct.as_bytes().to_vec(),
        };

        Ok((response, keys))
    }
}

/// Derive 3 independent session keys from combined shared secrets using HKDF-SHA256
fn derive_session_keys(
    x25519_ss: &[u8],
    kyber_ss: &[u8],
) -> Result<SessionKeys, HidraError> {
    // Combine: IKM = X25519_ss || Kyber_ss
    let mut ikm = Vec::with_capacity(x25519_ss.len() + kyber_ss.len());
    ikm.extend_from_slice(x25519_ss);
    ikm.extend_from_slice(kyber_ss);

    let hkdf = Hkdf::<Sha256>::new(Some(b"HIDRA-v1-salt"), &ikm);

    // Derive Layer 1 key
    let mut layer1_key = [0u8; 32];
    hkdf.expand(HKDF_INFO_LAYER1, &mut layer1_key)
        .map_err(|_| HidraError::KeyExchangeFailed("HKDF expand failed for L1".to_string()))?;

    // Derive Layer 3 key
    let mut layer3_key = [0u8; 32];
    hkdf.expand(HKDF_INFO_LAYER3, &mut layer3_key)
        .map_err(|_| HidraError::KeyExchangeFailed("HKDF expand failed for L3".to_string()))?;

    // Derive Ratchet root key
    let mut ratchet_root = [0u8; 32];
    hkdf.expand(HKDF_INFO_RATCHET, &mut ratchet_root)
        .map_err(|_| HidraError::KeyExchangeFailed("HKDF expand failed for ratchet".to_string()))?;

    // Zeroize intermediate key material
    ikm.zeroize();

    Ok(SessionKeys {
        layer1_key,
        layer3_key,
        ratchet_root,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_full_key_exchange() {
        // Alice initiates
        let alice = AliceKeyExchange::new();
        let init_msg = alice.get_init_message();

        // Bob responds
        let (response, bob_keys) = BobKeyExchange::respond(&init_msg).unwrap();

        // Alice completes
        let alice_keys = alice.complete(&response).unwrap();

        // Both sides should derive identical keys
        assert_eq!(alice_keys.layer1_key, bob_keys.layer1_key);
        assert_eq!(alice_keys.layer3_key, bob_keys.layer3_key);
        assert_eq!(alice_keys.ratchet_root, bob_keys.ratchet_root);
    }

    #[test]
    fn test_different_sessions_different_keys() {
        // Session 1
        let alice1 = AliceKeyExchange::new();
        let init1 = alice1.get_init_message();
        let (resp1, _) = BobKeyExchange::respond(&init1).unwrap();
        let keys1 = alice1.complete(&resp1).unwrap();

        // Session 2
        let alice2 = AliceKeyExchange::new();
        let init2 = alice2.get_init_message();
        let (resp2, _) = BobKeyExchange::respond(&init2).unwrap();
        let keys2 = alice2.complete(&resp2).unwrap();

        // Keys must differ
        assert_ne!(keys1.layer1_key, keys2.layer1_key);
        assert_ne!(keys1.layer3_key, keys2.layer3_key);
        assert_ne!(keys1.ratchet_root, keys2.ratchet_root);
    }

    #[test]
    fn test_derived_keys_are_independent() {
        let alice = AliceKeyExchange::new();
        let init_msg = alice.get_init_message();
        let (response, keys) = BobKeyExchange::respond(&init_msg).unwrap();

        // All 3 derived keys should be different from each other
        assert_ne!(keys.layer1_key, keys.layer3_key);
        assert_ne!(keys.layer1_key, keys.ratchet_root);
        assert_ne!(keys.layer3_key, keys.ratchet_root);
    }
}
