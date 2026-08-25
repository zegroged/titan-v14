//! HİDRA Network Framing — 512-byte Padded Encrypted Envelopes
//!
//! Every message transmitted over Hydra MQTT is wrapped in a
//! fixed-size encrypted envelope to defeat traffic analysis.
//!
//! ## Security Properties
//! - **Fixed 512-byte blocks**: All envelopes are exactly 512 bytes
//!   (or multiples of 512 for large payloads) — prevents message
//!   size fingerprinting.
//! - **Random padding**: PKCS#7-style but with random fill bytes
//!   to prevent padding oracle attacks.
//! - **Timestamp window**: ±5 minute tolerance prevents replay
//!   while allowing reasonable clock skew.
//! - **Nonce binding**: Each envelope has a unique 24-byte nonce
//!   bound to the XChaCha20 encryption.

use chacha20poly1305::{
    aead::{Aead, KeyInit, OsRng},
    XChaCha20Poly1305, XNonce,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

/// Block size for traffic analysis resistance
pub const ENVELOPE_BLOCK_SIZE: usize = 512;

/// Maximum timestamp skew allowed (5 minutes in milliseconds)
const MAX_TIMESTAMP_SKEW_MS: u64 = 5 * 60 * 1000;

/// Message types carried in envelopes
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum MessageType {
    Text = 1,
    File = 2,
    Command = 3,
    Ack = 4,
    KeyExchange = 5,
    Heartbeat = 6,
    /// ★ B3: Self-destructing message — receiver auto-deletes after TTL
    Ephemeral = 7,
    /// ★ C3: Decoy traffic (ignored by receiver, indistinguishable from real)
    Decoy = 8,
    /// ★ B5: Canary-watermarked message (leak detection)
    Canary = 9,
}

impl MessageType {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::Text),
            2 => Some(Self::File),
            3 => Some(Self::Command),
            4 => Some(Self::Ack),
            5 => Some(Self::KeyExchange),
            6 => Some(Self::Heartbeat),
            7 => Some(Self::Ephemeral),
            8 => Some(Self::Decoy),
            9 => Some(Self::Canary),
            _ => None,
        }
    }

    /// Is this a real message that should be displayed to the user?
    pub fn is_user_visible(&self) -> bool {
        matches!(self, Self::Text | Self::File | Self::Command | Self::Ephemeral | Self::Canary)
    }

    /// Does this message type auto-expire?
    pub fn has_ttl(&self) -> bool {
        matches!(self, Self::Ephemeral)
    }
}

/// Errors specific to framing operations
#[derive(Debug, Error)]
pub enum FramingError {
    #[error("Envelope too small: {0} bytes (minimum {ENVELOPE_BLOCK_SIZE})")]
    TooSmall(usize),
    #[error("Envelope size not aligned to {ENVELOPE_BLOCK_SIZE}-byte blocks")]
    NotAligned,
    #[error("Timestamp outside allowed window: delta={0}ms, max={MAX_TIMESTAMP_SKEW_MS}ms")]
    TimestampOutOfWindow(u64),
    #[error("Invalid message type: {0}")]
    InvalidMessageType(u8),
    #[error("Padding length invalid: {0}")]
    InvalidPadding(usize),
    #[error("Encryption failed: {0}")]
    EncryptionFailed(String),
    #[error("Decryption failed: {0}")]
    DecryptionFailed(String),
    #[error("Deserialization failed: {0}")]
    DeserializationFailed(String),
}

/// Inner plaintext structure before encryption
/// Layout: [version:1][type:1][timestamp:8][sender_id:32][payload_len:4][payload:N][padding:M]
#[derive(Debug, Clone)]
pub struct EnvelopeInner {
    pub version: u8,
    pub msg_type: MessageType,
    pub timestamp_ms: u64,
    pub sender_id: [u8; 32],
    pub payload: Vec<u8>,
}

/// Sealed (encrypted) envelope ready for wire transmission
/// Layout: [nonce:24][ciphertext:N] — total padded to 512-byte blocks
#[derive(Debug, Clone)]
pub struct SealedEnvelope {
    pub nonce: [u8; 24],
    pub ciphertext: Vec<u8>,
}

impl SealedEnvelope {
    /// Total wire size
    pub fn wire_size(&self) -> usize {
        24 + self.ciphertext.len()
    }

    /// Serialize to bytes for MQTT publish
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.wire_size());
        out.extend_from_slice(&self.nonce);
        out.extend_from_slice(&self.ciphertext);
        out
    }

    /// Deserialize from wire bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self, FramingError> {
        if data.len() < ENVELOPE_BLOCK_SIZE {
            return Err(FramingError::TooSmall(data.len()));
        }
        if data.len() % ENVELOPE_BLOCK_SIZE != 0 {
            return Err(FramingError::NotAligned);
        }
        let mut nonce = [0u8; 24];
        nonce.copy_from_slice(&data[..24]);
        Ok(Self {
            nonce,
            ciphertext: data[24..].to_vec(),
        })
    }
}

/// Current timestamp in milliseconds
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Pad plaintext to make total envelope = multiple of 512 bytes.
/// Format: [plaintext][random_padding][pad_len:2]
/// The last 2 bytes store padding length (u16 LE) so we can strip it.
fn pad_to_block(plaintext: &[u8]) -> Vec<u8> {
    // After encryption: nonce(24) + ciphertext(plaintext_len + 16 AEAD tag)
    // We need: 24 + (padded_plaintext_len + 16) = N * 512
    // So: padded_plaintext_len = N * 512 - 24 - 16 = N * 512 - 40
    let encrypted_overhead = 24 + 16; // nonce + AEAD tag
    let min_total = plaintext.len() + 2 + encrypted_overhead; // +2 for pad_len field
    let blocks = (min_total + ENVELOPE_BLOCK_SIZE - 1) / ENVELOPE_BLOCK_SIZE;
    let target_plaintext_len = blocks * ENVELOPE_BLOCK_SIZE - encrypted_overhead;
    // ★ H-9 FIX: saturating_sub prevents underflow panic on edge-case sizes
    let pad_len = target_plaintext_len.saturating_sub(plaintext.len() + 2);

    let mut padded = Vec::with_capacity(target_plaintext_len);
    padded.extend_from_slice(plaintext);

    // Random padding bytes (not zeros — prevents pattern detection)
    let mut rng = rand::thread_rng();
    let mut pad_bytes = vec![0u8; pad_len];
    rng.fill_bytes(&mut pad_bytes);
    padded.extend_from_slice(&pad_bytes);

    // Padding length as u16 LE (last 2 bytes)
    padded.extend_from_slice(&(pad_len as u16).to_le_bytes());
    padded
}

/// Strip padding from decrypted plaintext
fn unpad(padded: &[u8]) -> Result<&[u8], FramingError> {
    if padded.len() < 2 {
        return Err(FramingError::InvalidPadding(padded.len()));
    }
    let pad_len = u16::from_le_bytes([
        padded[padded.len() - 2],
        padded[padded.len() - 1],
    ]) as usize;
    let data_len = padded
        .len()
        .checked_sub(pad_len + 2)
        .ok_or(FramingError::InvalidPadding(pad_len))?;
    Ok(&padded[..data_len])
}

/// Serialize inner envelope to plaintext bytes
fn serialize_inner(inner: &EnvelopeInner) -> Vec<u8> {
    let payload_len = inner.payload.len() as u32;
    let total = 1 + 1 + 8 + 32 + 4 + inner.payload.len();
    let mut buf = Vec::with_capacity(total);
    buf.push(inner.version);
    buf.push(inner.msg_type as u8);
    buf.extend_from_slice(&inner.timestamp_ms.to_le_bytes());
    buf.extend_from_slice(&inner.sender_id);
    buf.extend_from_slice(&payload_len.to_le_bytes());
    buf.extend_from_slice(&inner.payload);
    buf
}

/// Deserialize inner envelope from plaintext bytes
fn deserialize_inner(data: &[u8]) -> Result<EnvelopeInner, FramingError> {
    // Minimum: version(1) + type(1) + timestamp(8) + sender(32) + payload_len(4) = 46
    if data.len() < 46 {
        return Err(FramingError::DeserializationFailed(
            format!("Inner too short: {} bytes", data.len()),
        ));
    }
    let version = data[0];
    let msg_type = MessageType::from_u8(data[1])
        .ok_or(FramingError::InvalidMessageType(data[1]))?;
    let timestamp_ms = u64::from_le_bytes(data[2..10].try_into().unwrap());
    let mut sender_id = [0u8; 32];
    sender_id.copy_from_slice(&data[10..42]);
    let payload_len = u32::from_le_bytes(data[42..46].try_into().unwrap()) as usize;
    if data.len() < 46 + payload_len {
        return Err(FramingError::DeserializationFailed(
            format!("Payload truncated: need {} have {}", payload_len, data.len() - 46),
        ));
    }
    let payload = data[46..46 + payload_len].to_vec();
    Ok(EnvelopeInner {
        version,
        msg_type,
        timestamp_ms,
        sender_id,
        payload,
    })
}

/// Seal (encrypt + pad) a message into a fixed-size envelope.
///
/// # Arguments
/// - `key`: 256-bit XChaCha20-Poly1305 key
/// - `msg_type`: Type of message
/// - `sender_id`: 32-byte sender identifier (pubkey hash)
/// - `payload`: Raw message bytes
///
/// # Returns
/// A `SealedEnvelope` whose wire size is a multiple of 512 bytes.
pub fn seal(
    key: &[u8; 32],
    msg_type: MessageType,
    sender_id: &[u8; 32],
    payload: &[u8],
) -> Result<SealedEnvelope, FramingError> {
    let inner = EnvelopeInner {
        version: 0x01,
        msg_type,
        timestamp_ms: now_ms(),
        sender_id: *sender_id,
        payload: payload.to_vec(),
    };

    let plaintext = serialize_inner(&inner);
    let padded = pad_to_block(&plaintext);

    // Generate random nonce
    let mut nonce_bytes = [0u8; 24];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = XNonce::from_slice(&nonce_bytes);

    // Encrypt
    let cipher = XChaCha20Poly1305::new_from_slice(key)
        .map_err(|e| FramingError::EncryptionFailed(e.to_string()))?;
    let ciphertext = cipher
        .encrypt(nonce, padded.as_ref())
        .map_err(|e| FramingError::EncryptionFailed(e.to_string()))?;

    Ok(SealedEnvelope {
        nonce: nonce_bytes,
        ciphertext,
    })
}

/// Open (decrypt + unpad + validate) a sealed envelope.
///
/// # Arguments
/// - `key`: 256-bit XChaCha20-Poly1305 key
/// - `envelope`: The sealed envelope to open
///
/// # Returns
/// The decrypted `EnvelopeInner` after padding removal and timestamp validation.
pub fn open(
    key: &[u8; 32],
    envelope: &SealedEnvelope,
) -> Result<EnvelopeInner, FramingError> {
    let nonce = XNonce::from_slice(&envelope.nonce);
    let cipher = XChaCha20Poly1305::new_from_slice(key)
        .map_err(|e| FramingError::DecryptionFailed(e.to_string()))?;

    let padded = cipher
        .decrypt(nonce, envelope.ciphertext.as_ref())
        .map_err(|e| FramingError::DecryptionFailed(e.to_string()))?;

    let plaintext = unpad(&padded)?;
    let inner = deserialize_inner(plaintext)?;

    // Timestamp validation
    let now = now_ms();
    let delta = if inner.timestamp_ms > now {
        inner.timestamp_ms - now
    } else {
        now - inner.timestamp_ms
    };
    if delta > MAX_TIMESTAMP_SKEW_MS {
        return Err(FramingError::TimestampOutOfWindow(delta));
    }

    Ok(inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> [u8; 32] {
        let mut key = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut key);
        key
    }

    fn test_sender() -> [u8; 32] {
        [0xAB; 32]
    }

    #[test]
    fn test_seal_open_roundtrip() {
        let key = test_key();
        let msg = b"Merhaba HIDRA!";
        let sealed = seal(&key, MessageType::Text, &test_sender(), msg).unwrap();
        let inner = open(&key, &sealed).unwrap();

        assert_eq!(inner.version, 0x01);
        assert_eq!(inner.msg_type, MessageType::Text);
        assert_eq!(inner.sender_id, test_sender());
        assert_eq!(inner.payload, msg.to_vec());
    }

    #[test]
    fn test_512_byte_alignment() {
        let key = test_key();

        // Small message
        let sealed_small = seal(&key, MessageType::Text, &test_sender(), b"kisa").unwrap();
        assert_eq!(sealed_small.wire_size() % ENVELOPE_BLOCK_SIZE, 0);
        assert_eq!(sealed_small.wire_size(), ENVELOPE_BLOCK_SIZE);

        // Medium message (200 bytes)
        let medium = vec![0x42u8; 200];
        let sealed_med = seal(&key, MessageType::File, &test_sender(), &medium).unwrap();
        assert_eq!(sealed_med.wire_size() % ENVELOPE_BLOCK_SIZE, 0);

        // Large message (600 bytes — should span 2 blocks)
        let large = vec![0x7Fu8; 600];
        let sealed_large = seal(&key, MessageType::File, &test_sender(), &large).unwrap();
        assert_eq!(sealed_large.wire_size() % ENVELOPE_BLOCK_SIZE, 0);
        assert!(sealed_large.wire_size() >= 1024); // 2+ blocks
    }

    #[test]
    fn test_tampered_ciphertext_rejected() {
        let key = test_key();
        let sealed = seal(&key, MessageType::Command, &test_sender(), b"cmd").unwrap();

        let mut tampered = sealed.clone();
        // Flip a bit in ciphertext
        if let Some(byte) = tampered.ciphertext.get_mut(10) {
            *byte ^= 0xFF;
        }
        assert!(open(&key, &tampered).is_err());
    }

    #[test]
    fn test_wrong_key_rejected() {
        let key1 = test_key();
        let key2 = test_key();
        let sealed = seal(&key1, MessageType::Text, &test_sender(), b"secret").unwrap();
        assert!(open(&key2, &sealed).is_err());
    }

    #[test]
    fn test_wire_serialization_roundtrip() {
        let key = test_key();
        let sealed = seal(&key, MessageType::Ack, &test_sender(), b"ack").unwrap();

        let wire = sealed.to_bytes();
        assert_eq!(wire.len() % ENVELOPE_BLOCK_SIZE, 0);

        let restored = SealedEnvelope::from_bytes(&wire).unwrap();
        let inner = open(&key, &restored).unwrap();
        assert_eq!(inner.payload, b"ack");
    }

    #[test]
    fn test_all_message_types() {
        let key = test_key();
        for (mt, expected) in [
            (MessageType::Text, 1u8),
            (MessageType::File, 2),
            (MessageType::Command, 3),
            (MessageType::Ack, 4),
            (MessageType::KeyExchange, 5),
            (MessageType::Heartbeat, 6),
        ] {
            let sealed = seal(&key, mt, &test_sender(), b"test").unwrap();
            let inner = open(&key, &sealed).unwrap();
            assert_eq!(inner.msg_type, mt);
            assert_eq!(inner.msg_type as u8, expected);
        }
    }
}
