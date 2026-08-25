//! ★ P4 #39: Remote Revocation — Uzaktan Anahtar İptali
//!
//! Ele geçirilen bir cihazın anahtarlarını uzaktan geçersiz kılma.
//!
//! Wire Format: [MAGIC:4][entry_count:4][entries:N*72][hmac:32]
//! Entry: [pubkey_hash:32][timestamp:8][reason_len:4][reason:28]

use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

const ENTRY_SIZE: usize = 72;
const HMAC_SIZE: usize = 32;
const REVOCATION_MAGIC: &[u8; 4] = b"REVK";

#[derive(Debug, thiserror::Error)]
pub enum RevocationError {
    #[error("Invalid revocation list format")]
    InvalidFormat,

    #[error("HMAC verification failed — list may be tampered")]
    HmacFailed,

    #[error("Revocation list too large: {0} entries (max 256)")]
    TooManyEntries(usize),

    #[error("Reason string too long: {0} bytes (max 28)")]
    ReasonTooLong(usize),
}

#[derive(Debug, Clone)]
pub struct RevocationEntry {
    pub pubkey_hash: [u8; 32],
    pub timestamp: u64,
    pub reason: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct RevocationList {
    pub entries: Vec<RevocationEntry>,
}

impl RevocationEntry {
    fn to_bytes(&self) -> [u8; ENTRY_SIZE] {
        let mut buf = [0u8; ENTRY_SIZE];
        buf[0..32].copy_from_slice(&self.pubkey_hash);
        buf[32..40].copy_from_slice(&self.timestamp.to_be_bytes());
        let reason_len = self.reason.len().min(28) as u32;
        buf[40..44].copy_from_slice(&reason_len.to_be_bytes());
        buf[44..44 + reason_len as usize].copy_from_slice(&self.reason[..reason_len as usize]);
        buf
    }

    fn from_bytes(data: &[u8; ENTRY_SIZE]) -> Self {
        let mut pubkey_hash = [0u8; 32];
        pubkey_hash.copy_from_slice(&data[0..32]);

        let timestamp = u64::from_be_bytes([
            data[32], data[33], data[34], data[35],
            data[36], data[37], data[38], data[39],
        ]);

        let reason_len = u32::from_be_bytes([
            data[40], data[41], data[42], data[43],
        ]) as usize;
        let reason_len = reason_len.min(28);
        let reason = data[44..44 + reason_len].to_vec();

        Self { pubkey_hash, timestamp, reason }
    }
}

impl RevocationList {
    pub fn new() -> Self {
        Self { entries: Vec::new() }
    }

    pub fn add(
        &mut self,
        pubkey_hash: [u8; 32],
        reason: &str,
    ) -> Result<(), RevocationError> {
        if self.entries.len() >= 256 {
            return Err(RevocationError::TooManyEntries(self.entries.len()));
        }
        let reason_bytes = reason.as_bytes();
        if reason_bytes.len() > 28 {
            return Err(RevocationError::ReasonTooLong(reason_bytes.len()));
        }

        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        self.entries.push(RevocationEntry {
            pubkey_hash,
            timestamp,
            reason: reason_bytes.to_vec(),
        });
        Ok(())
    }

    pub fn serialize_and_sign(&self, signing_key: &[u8; 32]) -> Vec<u8> {
        let entry_count = self.entries.len() as u32;
        let total_size = 4 + 4 + (self.entries.len() * ENTRY_SIZE) + HMAC_SIZE;
        let mut buf = Vec::with_capacity(total_size);

        buf.extend_from_slice(REVOCATION_MAGIC);
        buf.extend_from_slice(&entry_count.to_be_bytes());

        for entry in &self.entries {
            buf.extend_from_slice(&entry.to_bytes());
        }

        let mut mac = <HmacSha256 as Mac>::new_from_slice(signing_key)
            .expect("HMAC key length is always valid for SHA256");
        mac.update(&buf);
        let hmac_result = mac.finalize().into_bytes();
        buf.extend_from_slice(&hmac_result);

        buf
    }

    pub fn verify_and_deserialize(
        data: &[u8],
        verification_key: &[u8; 32],
    ) -> Result<Self, RevocationError> {
        if data.len() < 40 {
            return Err(RevocationError::InvalidFormat);
        }

        if &data[0..4] != REVOCATION_MAGIC {
            return Err(RevocationError::InvalidFormat);
        }

        let hmac_offset = data.len() - HMAC_SIZE;
        let message_bytes = &data[..hmac_offset];
        let received_hmac = &data[hmac_offset..];

        let mut mac = <HmacSha256 as Mac>::new_from_slice(verification_key)
            .expect("HMAC key length is always valid for SHA256");
        mac.update(message_bytes);
        mac.verify_slice(received_hmac)
            .map_err(|_| RevocationError::HmacFailed)?;

        let entry_count = u32::from_be_bytes([
            data[4], data[5], data[6], data[7],
        ]) as usize;

        if entry_count > 256 {
            return Err(RevocationError::TooManyEntries(entry_count));
        }

        let expected_size = 4 + 4 + (entry_count * ENTRY_SIZE) + HMAC_SIZE;
        if data.len() != expected_size {
            return Err(RevocationError::InvalidFormat);
        }

        let mut entries = Vec::with_capacity(entry_count);
        for i in 0..entry_count {
            let offset = 8 + (i * ENTRY_SIZE);
            let mut entry_bytes = [0u8; ENTRY_SIZE];
            entry_bytes.copy_from_slice(&data[offset..offset + ENTRY_SIZE]);
            entries.push(RevocationEntry::from_bytes(&entry_bytes));
        }

        Ok(Self { entries })
    }

    pub fn is_revoked(&self, pubkey_hash: &[u8; 32]) -> bool {
        self.entries.iter().any(|e| {
            let mut diff = 0u8;
            for i in 0..32 {
                diff |= e.pubkey_hash[i] ^ pubkey_hash[i];
            }
            diff == 0
        })
    }

    pub fn revocation_reason(&self, pubkey_hash: &[u8; 32]) -> Option<String> {
        self.entries.iter().find_map(|e| {
            let mut diff = 0u8;
            for i in 0..32 {
                diff |= e.pubkey_hash[i] ^ pubkey_hash[i];
            }
            if diff == 0 {
                Some(String::from_utf8_lossy(&e.reason).to_string())
            } else {
                None
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_signing_key() -> [u8; 32] { [0xAA; 32] }
    fn test_pubkey_hash() -> [u8; 32] { [0xBB; 32] }

    #[test]
    fn t1_create_and_verify_list() {
        let key = test_signing_key();
        let mut list = RevocationList::new();
        list.add(test_pubkey_hash(), "compromised").unwrap();

        let wire = list.serialize_and_sign(&key);
        let restored = RevocationList::verify_and_deserialize(&wire, &key).unwrap();

        assert_eq!(restored.entries.len(), 1);
        assert_eq!(restored.entries[0].pubkey_hash, test_pubkey_hash());
        assert_eq!(restored.entries[0].reason, b"compromised");
    }

    #[test]
    fn t2_hmac_tamper_detection() {
        let key = test_signing_key();
        let mut list = RevocationList::new();
        list.add(test_pubkey_hash(), "stolen").unwrap();

        let mut wire = list.serialize_and_sign(&key);
        wire[10] ^= 0xFF;

        let result = RevocationList::verify_and_deserialize(&wire, &key);
        assert!(result.is_err());
    }

    #[test]
    fn t3_wrong_key_rejected() {
        let key = test_signing_key();
        let wrong_key = [0xCC; 32];
        let mut list = RevocationList::new();
        list.add(test_pubkey_hash(), "lost").unwrap();

        let wire = list.serialize_and_sign(&key);
        let result = RevocationList::verify_and_deserialize(&wire, &wrong_key);
        assert!(result.is_err());
    }

    #[test]
    fn t4_is_revoked_check() {
        let revoked_pk = test_pubkey_hash();
        let innocent_pk = [0xDD; 32];

        let mut list = RevocationList::new();
        list.add(revoked_pk, "compromised").unwrap();

        assert!(list.is_revoked(&revoked_pk));
        assert!(!list.is_revoked(&innocent_pk));
    }

    #[test]
    fn t5_multiple_entries() {
        let key = test_signing_key();
        let mut list = RevocationList::new();

        let pk1 = [0x01; 32];
        let pk2 = [0x02; 32];
        let pk3 = [0x03; 32];

        list.add(pk1, "lost device").unwrap();
        list.add(pk2, "stolen").unwrap();
        list.add(pk3, "decommissioned").unwrap();

        let wire = list.serialize_and_sign(&key);
        let restored = RevocationList::verify_and_deserialize(&wire, &key).unwrap();

        assert_eq!(restored.entries.len(), 3);
        assert!(restored.is_revoked(&pk1));
        assert!(restored.is_revoked(&pk2));
        assert!(restored.is_revoked(&pk3));
        assert!(!restored.is_revoked(&[0xFF; 32]));
    }

    #[test]
    fn t6_revocation_reason() {
        let mut list = RevocationList::new();
        let pk = [0xEE; 32];
        list.add(pk, "suspicious activity").unwrap();

        let reason = list.revocation_reason(&pk);
        assert_eq!(reason, Some("suspicious activity".to_string()));
        assert_eq!(list.revocation_reason(&[0xFF; 32]), None);
    }

    #[test]
    fn t7_empty_list() {
        let key = test_signing_key();
        let list = RevocationList::new();

        let wire = list.serialize_and_sign(&key);
        let restored = RevocationList::verify_and_deserialize(&wire, &key).unwrap();
        assert_eq!(restored.entries.len(), 0);
        assert!(!restored.is_revoked(&[0x00; 32]));
    }
}
