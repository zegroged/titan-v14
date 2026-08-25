//! Titan DHT — BitMap Notifications + Decoy Scan
//!
//! Yasa III: Each epoch, scan 100 real keys + 10 fake keys.
//! Queries should run in parallel (async) for ~200ms total.
//! Jitter: random delay within epoch to prevent fingerprinting.

use hkdf::Hkdf;
use rand::Rng;
use sha2::Sha256;
use std::collections::HashMap;

/// Number of real peer keys to scan per epoch.
pub const REAL_KEY_COUNT: usize = 100;
/// Number of fake (decoy) keys per scan.
pub const FAKE_KEY_COUNT: usize = 10;
/// Total queries per epoch scan.
pub const TOTAL_SCAN_COUNT: usize = REAL_KEY_COUNT + FAKE_KEY_COUNT;

/// 1-bit DHT signal: peer is online and has messages.
#[derive(Debug, Clone, PartialEq)]
pub enum DhtSignal {
    Silent,
    Active,
}

/// DHT storage trait.
pub trait DhtStore {
    fn put(&mut self, key: &[u8; 32], signal: DhtSignal);
    fn get(&self, key: &[u8; 32]) -> DhtSignal;
}

/// In-memory DHT for testing.
pub struct MemoryDht {
    store: HashMap<[u8; 32], DhtSignal>,
}

impl MemoryDht {
    pub fn new() -> Self {
        Self {
            store: HashMap::new(),
        }
    }
}

impl Default for MemoryDht {
    fn default() -> Self {
        Self::new()
    }
}

impl DhtStore for MemoryDht {
    fn put(&mut self, key: &[u8; 32], signal: DhtSignal) {
        self.store.insert(*key, signal);
    }

    fn get(&self, key: &[u8; 32]) -> DhtSignal {
        self.store.get(key).cloned().unwrap_or(DhtSignal::Silent)
    }
}

/// Derive a notification key for a peer at a given epoch.
pub fn derive_notify_key(shared_secret: &[u8; 32], epoch: u64) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, shared_secret);
    let mut key = [0u8; 32];
    let info = format!("notify\x00{}", epoch);
    hk.expand(info.as_bytes(), &mut key)
        .expect("HKDF expand failed");
    key
}

/// Generate fake (decoy) keys for traffic analysis protection.
pub fn generate_fake_keys(count: usize) -> Vec<[u8; 32]> {
    (0..count)
        .map(|_| titan_entropy::generate_seed())
        .collect()
}

/// Calculate jitter delay within an epoch (random 0..epoch_secs).
pub fn jitter_delay_secs(epoch_duration_secs: u64) -> u64 {
    let mut rng = rand::thread_rng();
    rng.gen_range(0..epoch_duration_secs)
}

/// Perform a full epoch scan: query real + fake keys, return active peers.
pub fn epoch_scan(
    dht: &dyn DhtStore,
    peer_secrets: &[[u8; 32]],
    epoch: u64,
) -> Vec<usize> {
    let mut active_peers = Vec::new();

    // Real key queries
    for (i, secret) in peer_secrets.iter().enumerate() {
        let key = derive_notify_key(secret, epoch);
        if dht.get(&key) == DhtSignal::Active {
            active_peers.push(i);
        }
    }

    // Fake key queries (decoy — results ignored)
    let fakes = generate_fake_keys(FAKE_KEY_COUNT);
    for fake in &fakes {
        let _ = dht.get(fake); // query executed, result discarded
    }

    active_peers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_notify_key_deterministic() {
        let ss = [0xAA; 32];
        let k1 = derive_notify_key(&ss, 100);
        let k2 = derive_notify_key(&ss, 100);
        assert_eq!(k1, k2);
    }

    #[test]
    fn test_notify_key_different_epochs() {
        let ss = [0xBB; 32];
        let k1 = derive_notify_key(&ss, 100);
        let k2 = derive_notify_key(&ss, 101);
        assert_ne!(k1, k2);
    }

    #[test]
    fn test_fake_keys_unique() {
        let fakes = generate_fake_keys(10);
        let unique: std::collections::HashSet<[u8; 32]> = fakes.iter().cloned().collect();
        assert_eq!(unique.len(), 10, "All fake keys must be unique");
    }

    #[test]
    fn test_jitter_within_bounds() {
        for _ in 0..100 {
            let j = jitter_delay_secs(600);
            assert!(j < 600, "Jitter must be within epoch duration");
        }
    }

    #[test]
    fn test_epoch_scan_finds_active() {
        let mut dht = MemoryDht::new();
        let peers = vec![[0x11; 32], [0x22; 32], [0x33; 32]];
        let epoch = 50;

        // Only peer 1 is active
        let key1 = derive_notify_key(&peers[1], epoch);
        dht.put(&key1, DhtSignal::Active);

        let active = epoch_scan(&dht, &peers, epoch);
        assert_eq!(active, vec![1]);
    }

    #[test]
    fn test_epoch_scan_none_active() {
        let dht = MemoryDht::new();
        let peers = vec![[0x44; 32], [0x55; 32]];
        let active = epoch_scan(&dht, &peers, 99);
        assert!(active.is_empty());
    }

    #[test]
    fn test_epoch_scan_all_active() {
        let mut dht = MemoryDht::new();
        let peers = vec![[0x66; 32], [0x77; 32]];
        let epoch = 42;
        for p in &peers {
            let key = derive_notify_key(p, epoch);
            dht.put(&key, DhtSignal::Active);
        }
        let active = epoch_scan(&dht, &peers, epoch);
        assert_eq!(active, vec![0, 1]);
    }
}
