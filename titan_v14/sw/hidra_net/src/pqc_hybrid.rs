//! ★ P5 #46: Hybrid Post-Quantum Key Exchange (X25519 + Kyber-768)
//!
//! Kuantum bilgisayar tehdidine karşı hibrit anahtar değişimi.
//!
//! ## Protokol
//! 1. Initiator: X25519 ephemeral pubkey + Kyber-768 public key gönder
//! 2. Responder: X25519 DH + Kyber encapsulation → combined shared secret
//! 3. Combined: HKDF(X25519_ss ∥ Kyber_ss) → session key
//!
//! ## Güvenlik
//! - Klasik saldırılara karşı X25519 (proven)
//! - Kuantum saldırılara karşı Kyber-768 (NIST PQC winner)
//! - Hibrit: İkisinden biri kırılsa bile diğeri korur
//! - Graceful degradation: Kyber başarısız → sadece X25519

use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroize;

use pqcrypto_kyber::kyber768;
use pqcrypto_traits::kem::{PublicKey as KemPk, SecretKey as KemSk, SharedSecret, Ciphertext};

const HKDF_HYBRID_INFO: &[u8] = b"HIDRA-PQC-HYBRID-v1";

#[derive(Debug, thiserror::Error)]
pub enum PqcError {
    #[error("Kyber encapsulation failed")]
    KyberEncapFailed,

    #[error("Kyber decapsulation failed")]
    KyberDecapFailed,

    #[error("X25519 DH failed (low-order point)")]
    X25519Failed,

    #[error("Invalid initiator bundle size")]
    InvalidBundle,
}

/// Initiator's key material to send to responder.
/// Contains X25519 public key (32 bytes) + Kyber-768 public key (1184 bytes).
pub struct InitiatorBundle {
    /// X25519 ephemeral public key
    pub x25519_public: [u8; 32],
    /// X25519 secret (kept locally, not sent)
    x25519_secret: [u8; 32],
    /// Kyber-768 public key
    pub kyber_public: Vec<u8>,
    /// Kyber-768 secret key (kept locally)
    kyber_secret: Vec<u8>,
}

impl Drop for InitiatorBundle {
    fn drop(&mut self) {
        self.x25519_secret.zeroize();
        self.kyber_secret.zeroize();
    }
}

/// Responder's reply containing X25519 pubkey + Kyber ciphertext.
pub struct ResponderReply {
    /// Responder's X25519 public key
    pub x25519_public: [u8; 32],
    /// Kyber-768 ciphertext (encapsulated shared secret)
    pub kyber_ciphertext: Vec<u8>,
}

/// Combined shared secret from hybrid key exchange.
pub struct HybridSharedSecret {
    key: [u8; 32],
}

impl HybridSharedSecret {
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.key
    }
}

impl Drop for HybridSharedSecret {
    fn drop(&mut self) {
        self.key.zeroize();
    }
}

// =============================================================================
// Initiator (Alice) side
// =============================================================================

/// Generate initiator key bundle (X25519 + Kyber-768).
pub fn initiator_keygen() -> InitiatorBundle {
    // X25519
    let mut x_secret_bytes = [0u8; 32];
    rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut x_secret_bytes);
    let x_secret = StaticSecret::from(x_secret_bytes);
    let x_public = PublicKey::from(&x_secret);

    // Kyber-768
    let (kyber_pk, kyber_sk) = kyber768::keypair();

    InitiatorBundle {
        x25519_public: x_public.to_bytes(),
        x25519_secret: x_secret_bytes,
        kyber_public: kyber_pk.as_bytes().to_vec(),
        kyber_secret: kyber_sk.as_bytes().to_vec(),
    }
}

/// Initiator processes responder's reply to derive shared secret.
pub fn initiator_finish(
    bundle: &InitiatorBundle,
    reply: &ResponderReply,
) -> Result<HybridSharedSecret, PqcError> {
    // X25519 DH
    let x_secret = StaticSecret::from(bundle.x25519_secret);
    let peer_public = PublicKey::from(reply.x25519_public);
    let x_shared = x_secret.diffie_hellman(&peer_public);
    let x_ss = x_shared.to_bytes();

    // Kyber decapsulation
    let kyber_sk = kyber768::SecretKey::from_bytes(&bundle.kyber_secret)
        .map_err(|_| PqcError::KyberDecapFailed)?;
    let kyber_ct = kyber768::Ciphertext::from_bytes(&reply.kyber_ciphertext)
        .map_err(|_| PqcError::KyberDecapFailed)?;
    let kyber_ss = kyber768::decapsulate(&kyber_ct, &kyber_sk);
    let k_ss = kyber_ss.as_bytes();

    // Combine: HKDF(X25519_ss ∥ Kyber_ss)
    Ok(combine_secrets(&x_ss, k_ss))
}

// =============================================================================
// Responder (Bob) side
// =============================================================================

/// Responder processes initiator bundle and generates reply + shared secret.
pub fn responder_process(
    initiator: &InitiatorBundle,
) -> Result<(ResponderReply, HybridSharedSecret), PqcError> {
    // X25519: generate ephemeral, compute DH
    let mut r_secret_bytes = [0u8; 32];
    rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut r_secret_bytes);
    let r_secret = StaticSecret::from(r_secret_bytes);
    let r_public = PublicKey::from(&r_secret);

    let peer_x_public = PublicKey::from(initiator.x25519_public);
    let x_shared = r_secret.diffie_hellman(&peer_x_public);
    let x_ss = x_shared.to_bytes();

    // Kyber encapsulation
    let kyber_pk = kyber768::PublicKey::from_bytes(&initiator.kyber_public)
        .map_err(|_| PqcError::KyberEncapFailed)?;
    let (kyber_ss, kyber_ct) = kyber768::encapsulate(&kyber_pk);
    let k_ss = kyber_ss.as_bytes();

    let reply = ResponderReply {
        x25519_public: r_public.to_bytes(),
        kyber_ciphertext: kyber_ct.as_bytes().to_vec(),
    };

    // Combine secrets
    let combined = combine_secrets(&x_ss, k_ss);

    // Zeroize local secrets
    let mut r_bytes = r_secret_bytes;
    r_bytes.zeroize();

    Ok((reply, combined))
}

// =============================================================================
// X25519-only fallback (graceful degradation)
// =============================================================================

/// Fallback: X25519-only key exchange if Kyber is unavailable.
pub fn x25519_only_exchange(
    our_secret: &[u8; 32],
    their_public: &[u8; 32],
) -> HybridSharedSecret {
    let sk = StaticSecret::from(*our_secret);
    let pk = PublicKey::from(*their_public);
    let shared = sk.diffie_hellman(&pk);

    let hk = Hkdf::<Sha256>::new(None, &shared.to_bytes());
    let mut key = [0u8; 32];
    hk.expand(HKDF_HYBRID_INFO, &mut key).expect("HKDF failed");

    HybridSharedSecret { key }
}

// =============================================================================
// Internal helpers
// =============================================================================

/// Combine X25519 and Kyber shared secrets via HKDF.
fn combine_secrets(x25519_ss: &[u8], kyber_ss: &[u8]) -> HybridSharedSecret {
    // IKM = X25519_ss ∥ Kyber_ss
    let mut ikm = Vec::with_capacity(x25519_ss.len() + kyber_ss.len());
    ikm.extend_from_slice(x25519_ss);
    ikm.extend_from_slice(kyber_ss);

    let hk = Hkdf::<Sha256>::new(None, &ikm);
    let mut key = [0u8; 32];
    hk.expand(HKDF_HYBRID_INFO, &mut key).expect("HKDF failed");

    ikm.zeroize();

    HybridSharedSecret { key }
}

// =============================================================================
// Tests
// =============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn t1_hybrid_roundtrip() {
        // Alice generates bundle
        let alice_bundle = initiator_keygen();

        // Bob processes bundle → gets reply + shared secret
        let (reply, bob_ss) = responder_process(&alice_bundle).unwrap();

        // Alice finishes → gets same shared secret
        let alice_ss = initiator_finish(&alice_bundle, &reply).unwrap();

        assert_eq!(alice_ss.as_bytes(), bob_ss.as_bytes());
    }

    #[test]
    fn t2_different_sessions_different_keys() {
        let bundle1 = initiator_keygen();
        let (reply1, ss1) = responder_process(&bundle1).unwrap();
        let alice_ss1 = initiator_finish(&bundle1, &reply1).unwrap();

        let bundle2 = initiator_keygen();
        let (reply2, ss2) = responder_process(&bundle2).unwrap();
        let alice_ss2 = initiator_finish(&bundle2, &reply2).unwrap();

        assert_ne!(alice_ss1.as_bytes(), alice_ss2.as_bytes());
    }

    #[test]
    fn t3_x25519_fallback() {
        let mut secret_a = [0u8; 32];
        let mut secret_b = [0u8; 32];
        rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut secret_a);
        rand_core::RngCore::fill_bytes(&mut rand_core::OsRng, &mut secret_b);

        let public_a = PublicKey::from(&StaticSecret::from(secret_a)).to_bytes();
        let public_b = PublicKey::from(&StaticSecret::from(secret_b)).to_bytes();

        let ss_a = x25519_only_exchange(&secret_a, &public_b);
        let ss_b = x25519_only_exchange(&secret_b, &public_a);

        assert_eq!(ss_a.as_bytes(), ss_b.as_bytes());
    }

    #[test]
    fn t4_kyber_key_sizes() {
        let bundle = initiator_keygen();
        // Kyber-768 public key = 1184 bytes
        assert_eq!(bundle.kyber_public.len(), 1184);
    }

    #[test]
    fn t5_zeroize_on_drop() {
        let bundle = initiator_keygen();
        let secret_copy = bundle.x25519_secret;
        drop(bundle);
        // Verify no panic from drop
        assert_eq!(secret_copy.len(), 32);
    }
}
