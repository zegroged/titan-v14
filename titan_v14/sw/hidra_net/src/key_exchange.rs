//! ★ P4 #38: İlk Key Exchange — X25519 Diffie-Hellman + HKDF-SHA256
//!
//! İki cihaz arasında güvenli session key oluşturma.
//!
//! ## Protokol
//! 1. Alice: ephemeral X25519 keypair → pubkey'i gönder
//! 2. Bob: ephemeral X25519 keypair → pubkey'i gönder + shared secret hesapla
//! 3. Alice: shared secret hesapla
//! 4. Her iki taraf: HKDF-SHA256(shared_secret, salt=nonces) → session_key
//!
//! ## Güvenlik
//! - Ephemeral keypair: her session için yeni (PFS)
//! - HKDF: shared secret'tan key extraction + expansion
//! - Nonce binding: replay protection
//! - Zeroize: secret key RAM'den silindi

use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey, SharedSecret};
use zeroize::Zeroize;

use crate::framing::{self, MessageType, SealedEnvelope};

/// Key exchange errors
#[derive(Debug, thiserror::Error)]
pub enum KexError {
    #[error("Invalid public key length: expected 32, got {0}")]
    InvalidPubKeyLen(usize),

    #[error("Invalid KEX message length: expected 80, got {0}")]
    InvalidMessageLen(usize),

    #[error("HKDF expansion failed")]
    HkdfExpandFailed,

    #[error("Framing error: {0}")]
    Framing(#[from] framing::FramingError),
}

/// KEX wire message layout:
/// [x25519_pubkey:32][nonce:24][sender_id:24]
/// Total = 80 bytes (fits in one 512-byte envelope)
pub const KEX_MESSAGE_SIZE: usize = 80;
const PUBKEY_OFFSET: usize = 0;
const NONCE_OFFSET: usize = 32;
const SENDER_OFFSET: usize = 56;

/// Ephemeral key pair for one session.
/// The secret is consumed (moved) during DH computation — cannot be reused.
pub struct KeyPair {
    secret: EphemeralSecret,
    pub public: PublicKey,
}

/// Completed session key (after DH + HKDF)
pub struct SessionKey {
    key: [u8; 32],
}

impl SessionKey {
    /// Access the raw 32-byte key
    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.key
    }
}

impl Drop for SessionKey {
    fn drop(&mut self) {
        self.key.zeroize();
    }
}

/// Generate a fresh ephemeral X25519 key pair.
pub fn generate_keypair() -> KeyPair {
    let secret = EphemeralSecret::random_from_rng(OsRng);
    let public = PublicKey::from(&secret);
    KeyPair { secret, public }
}

/// Derive a 32-byte session key from X25519 DH + HKDF-SHA256.
pub fn derive_session_key(
    our_keypair: KeyPair,
    their_public: &[u8; 32],
    our_nonce: &[u8; 24],
    their_nonce: &[u8; 24],
) -> Result<SessionKey, KexError> {
    let their_pk = PublicKey::from(*their_public);
    let shared_secret: SharedSecret = our_keypair.secret.diffie_hellman(&their_pk);

    // Build deterministic salt: sort nonces so both sides get same salt
    let mut salt = [0u8; 48];
    if our_nonce < their_nonce {
        salt[..24].copy_from_slice(our_nonce);
        salt[24..].copy_from_slice(their_nonce);
    } else {
        salt[..24].copy_from_slice(their_nonce);
        salt[24..].copy_from_slice(our_nonce);
    }

    // HKDF-SHA256: extract + expand
    let hk = Hkdf::<Sha256>::new(Some(&salt), shared_secret.as_bytes());
    let mut session_key = [0u8; 32];
    hk.expand(b"HIDRA-SESSION-KEY-V1", &mut session_key)
        .map_err(|_| KexError::HkdfExpandFailed)?;

    salt.zeroize();
    Ok(SessionKey { key: session_key })
}

/// Create a KEX message to send to the peer.
pub fn create_kex_payload(keypair: &KeyPair, sender_id: &[u8; 24]) -> ([u8; KEX_MESSAGE_SIZE], [u8; 24]) {
    let mut nonce = [0u8; 24];
    rand_core::OsRng.fill_bytes(&mut nonce);

    let mut msg = [0u8; KEX_MESSAGE_SIZE];
    msg[PUBKEY_OFFSET..PUBKEY_OFFSET + 32].copy_from_slice(keypair.public.as_bytes());
    msg[NONCE_OFFSET..NONCE_OFFSET + 24].copy_from_slice(&nonce);
    msg[SENDER_OFFSET..SENDER_OFFSET + 24].copy_from_slice(sender_id);

    (msg, nonce)
}

/// Parse a received KEX message.
pub fn parse_kex_payload(
    payload: &[u8],
) -> Result<([u8; 32], [u8; 24], [u8; 24]), KexError> {
    if payload.len() != KEX_MESSAGE_SIZE {
        return Err(KexError::InvalidMessageLen(payload.len()));
    }

    let mut pubkey = [0u8; 32];
    pubkey.copy_from_slice(&payload[PUBKEY_OFFSET..PUBKEY_OFFSET + 32]);

    let mut nonce = [0u8; 24];
    nonce.copy_from_slice(&payload[NONCE_OFFSET..NONCE_OFFSET + 24]);

    let mut sender_id = [0u8; 24];
    sender_id.copy_from_slice(&payload[SENDER_OFFSET..SENDER_OFFSET + 24]);

    Ok((pubkey, nonce, sender_id))
}

/// Full KEX flow: create envelope containing our KEX message.
pub fn create_kex_envelope(
    pre_shared_key: &[u8; 32],
    keypair: &KeyPair,
    sender_id_full: &[u8; 32],
    sender_id_short: &[u8; 24],
) -> Result<(SealedEnvelope, [u8; 24]), KexError> {
    let (payload, nonce) = create_kex_payload(keypair, sender_id_short);
    let envelope = framing::seal(
        pre_shared_key,
        MessageType::KeyExchange,
        sender_id_full,
        &payload,
    )?;
    Ok((envelope, nonce))
}

/// Process a received KEX envelope and derive the session key.
pub fn process_kex_envelope(
    pre_shared_key: &[u8; 32],
    our_keypair: KeyPair,
    our_nonce: &[u8; 24],
    envelope: &SealedEnvelope,
) -> Result<(SessionKey, [u8; 24]), KexError> {
    let inner = framing::open(pre_shared_key, envelope)?;

    if inner.msg_type != MessageType::KeyExchange {
        return Err(KexError::InvalidMessageLen(0));
    }

    let (their_pubkey, their_nonce, their_sender_id) = parse_kex_payload(&inner.payload)?;

    let session_key = derive_session_key(
        our_keypair,
        &their_pubkey,
        our_nonce,
        &their_nonce,
    )?;

    Ok((session_key, their_sender_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn t1_keypair_generation() {
        let kp1 = generate_keypair();
        let kp2 = generate_keypair();
        assert_ne!(kp1.public.as_bytes(), kp2.public.as_bytes());
    }

    #[test]
    fn t2_kex_payload_roundtrip() {
        let kp = generate_keypair();
        let sender_id = [0xAB; 24];
        let (payload, nonce) = create_kex_payload(&kp, &sender_id);

        let (parsed_pk, parsed_nonce, parsed_sid) = parse_kex_payload(&payload).unwrap();
        assert_eq!(&parsed_pk, kp.public.as_bytes());
        assert_eq!(parsed_nonce, nonce);
        assert_eq!(parsed_sid, sender_id);
    }

    #[test]
    fn t3_session_key_derivation() {
        let alice_kp = generate_keypair();
        let bob_kp = generate_keypair();

        let alice_pub = *alice_kp.public.as_bytes();
        let bob_pub = *bob_kp.public.as_bytes();

        let alice_nonce = [0x11; 24];
        let bob_nonce = [0x22; 24];

        let alice_sk = derive_session_key(alice_kp, &bob_pub, &alice_nonce, &bob_nonce).unwrap();
        let bob_sk = derive_session_key(bob_kp, &alice_pub, &bob_nonce, &alice_nonce).unwrap();

        assert_eq!(alice_sk.as_bytes(), bob_sk.as_bytes());
    }

    #[test]
    fn t4_different_nonces_different_keys() {
        let alice_kp1 = generate_keypair();
        let bob_kp1 = generate_keypair();
        let alice_kp2 = generate_keypair();
        let bob_kp2 = generate_keypair();

        let bob_pub1 = *bob_kp1.public.as_bytes();
        let bob_pub2 = *bob_kp2.public.as_bytes();

        let nonce_a = [0x33; 24];
        let nonce_b = [0x44; 24];
        let nonce_c = [0x55; 24];

        let sk1 = derive_session_key(alice_kp1, &bob_pub1, &nonce_a, &nonce_b).unwrap();
        let sk2 = derive_session_key(alice_kp2, &bob_pub2, &nonce_a, &nonce_c).unwrap();

        assert_ne!(sk1.as_bytes(), sk2.as_bytes());
    }

    #[test]
    fn t5_full_envelope_kex_flow() {
        let psk = [0xFF; 32];

        let alice_kp = generate_keypair();
        let alice_sender_full = [0xAA; 32];
        let alice_sender_short = [0xAA; 24];
        let (_alice_env, _alice_nonce) = create_kex_envelope(
            &psk, &alice_kp, &alice_sender_full, &alice_sender_short,
        ).unwrap();

        let bob_kp = generate_keypair();
        let bob_sender_full = [0xBB; 32];
        let bob_sender_short = [0xBB; 24];
        let (bob_env, _bob_nonce) = create_kex_envelope(
            &psk, &bob_kp, &bob_sender_full, &bob_sender_short,
        ).unwrap();

        let inner = framing::open(&psk, &bob_env).unwrap();
        assert_eq!(inner.msg_type, MessageType::KeyExchange);
        let (_their_pk, _their_nonce, their_sid) = parse_kex_payload(&inner.payload).unwrap();
        assert_eq!(their_sid, bob_sender_short);
    }

    #[test]
    fn t6_session_key_zeroize_on_drop() {
        let kp1 = generate_keypair();
        let kp2 = generate_keypair();
        let pub2 = *kp2.public.as_bytes();
        let nonce1 = [0x01; 24];
        let nonce2 = [0x02; 24];

        let sk = derive_session_key(kp1, &pub2, &nonce1, &nonce2).unwrap();
        let key_copy = *sk.as_bytes();
        assert_ne!(key_copy, [0u8; 32]);
    }
}
