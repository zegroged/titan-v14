//! Titan Dead Drop — Distributed Amnezik Relay
//!
//! RAM-only message storage with 72h TTL.
//! Envelope stored at HKDF-derived coordinates.
//! Auto-expire after TTL. Immediate delete on retrieval.

use std::collections::HashMap;
use std::time::{Duration, Instant};
use zeroize::Zeroize;

/// Dead Drop TTL: 72 hours.
pub const TTL_SECS: u64 = 72 * 3600;

/// Maximum envelope size (handshake tier).
pub const MAX_ENVELOPE_SIZE: usize = 8192;

/// A stored envelope with its expiry.
struct StoredEnvelope {
    data: Vec<u8>,
    created: Instant,
}

/// Dead Drop trait — generic relay interface.
pub trait DeadDrop {
    fn store(&mut self, addr: &[u8; 32], envelope: Vec<u8>) -> Result<(), &'static str>;
    fn retrieve(&mut self, addr: &[u8; 32]) -> Option<Vec<u8>>;
    fn expire_old(&mut self) -> usize;
}

/// In-memory Dead Drop relay (RAM only, amnezik).
pub struct MemoryDeadDrop {
    slots: HashMap<[u8; 32], StoredEnvelope>,
    ttl: Duration,
}

impl MemoryDeadDrop {
    pub fn new() -> Self {
        Self {
            slots: HashMap::new(),
            ttl: Duration::from_secs(TTL_SECS),
        }
    }

    /// Create with custom TTL (for testing).
    pub fn with_ttl_secs(secs: u64) -> Self {
        Self {
            slots: HashMap::new(),
            ttl: Duration::from_secs(secs),
        }
    }

    /// Number of stored envelopes.
    pub fn count(&self) -> usize {
        self.slots.len()
    }
}

impl Default for MemoryDeadDrop {
    fn default() -> Self {
        Self::new()
    }
}

impl DeadDrop for MemoryDeadDrop {
    /// Store an envelope at a coordinate. Rejects oversized payloads.
    fn store(&mut self, addr: &[u8; 32], envelope: Vec<u8>) -> Result<(), &'static str> {
        if envelope.len() > MAX_ENVELOPE_SIZE {
            return Err("Envelope exceeds max size (8KB)");
        }
        self.slots.insert(
            *addr,
            StoredEnvelope {
                data: envelope,
                created: Instant::now(),
            },
        );
        Ok(())
    }

    /// Retrieve and DELETE envelope from coordinate (one-time pickup).
    fn retrieve(&mut self, addr: &[u8; 32]) -> Option<Vec<u8>> {
        self.slots.remove(addr).map(|mut s| {
            let data = std::mem::take(&mut s.data);
            s.data.zeroize();
            data
        })
    }

    /// Expire all envelopes older than TTL. Returns count of expired.
    fn expire_old(&mut self) -> usize {
        let now = Instant::now();
        let ttl = self.ttl;
        let before = self.slots.len();
        self.slots.retain(|_, stored| {
            if now.duration_since(stored.created) >= ttl {
                stored.data.zeroize();
                false
            } else {
                true
            }
        });
        before - self.slots.len()
    }
}

impl Drop for MemoryDeadDrop {
    fn drop(&mut self) {
        for (_, stored) in self.slots.iter_mut() {
            stored.data.zeroize();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_store_and_retrieve() {
        let mut dd = MemoryDeadDrop::new();
        let addr = [0xAA; 32];
        let data = vec![1, 2, 3, 4];
        dd.store(&addr, data.clone()).unwrap();
        assert_eq!(dd.count(), 1);

        let retrieved = dd.retrieve(&addr).unwrap();
        assert_eq!(retrieved, data);
        assert_eq!(dd.count(), 0, "Must be deleted after retrieval");
    }

    #[test]
    fn test_retrieve_empty() {
        let mut dd = MemoryDeadDrop::new();
        assert!(dd.retrieve(&[0xBB; 32]).is_none());
    }

    #[test]
    fn test_retrieve_once_only() {
        let mut dd = MemoryDeadDrop::new();
        let addr = [0xCC; 32];
        dd.store(&addr, vec![5, 6]).unwrap();
        dd.retrieve(&addr).unwrap();
        assert!(dd.retrieve(&addr).is_none(), "Second retrieve must fail");
    }

    #[test]
    fn test_max_size_reject() {
        let mut dd = MemoryDeadDrop::new();
        let big = vec![0u8; MAX_ENVELOPE_SIZE + 1];
        assert!(dd.store(&[0xDD; 32], big).is_err());
    }

    #[test]
    fn test_max_size_accept() {
        let mut dd = MemoryDeadDrop::new();
        let exact = vec![0u8; MAX_ENVELOPE_SIZE];
        assert!(dd.store(&[0xEE; 32], exact).is_ok());
    }

    #[test]
    fn test_expire_with_short_ttl() {
        let mut dd = MemoryDeadDrop::with_ttl_secs(0); // instant expiry
        dd.store(&[0x11; 32], vec![1]).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(10));
        let expired = dd.expire_old();
        assert_eq!(expired, 1);
        assert_eq!(dd.count(), 0);
    }
}
