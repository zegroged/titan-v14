//! Navigator — Batch Sweep & Compass Checkpoint
//!
//! Handles message collection across multiple Dead Drop coordinates.
//! Checkpoints N_in/S_out to SecureKeyStore after each successful operation.

use titan_hal::SecureKeyStore;

/// Navigator state for one peer conversation.
pub struct Navigator {
    pub n_in: u32,
    pub s_out: u32,
    pub last_signal_epoch: u64,
    peer_id: String,
}

impl Navigator {
    pub fn new(peer_id: &str, n_in: u32, s_out: u32, last_epoch: u64) -> Self {
        Self {
            n_in,
            s_out,
            last_signal_epoch: last_epoch,
            peer_id: peer_id.to_string(),
        }
    }

    /// Advance receive counter after successful message pickup.
    pub fn message_received(&mut self) {
        self.n_in += 1;
    }

    /// Advance send counter after successful message send.
    pub fn message_sent(&mut self) {
        self.s_out += 1;
    }

    /// Checkpoint current counters to SecureKeyStore (Compass).
    pub fn checkpoint(&self, store: &mut dyn SecureKeyStore) -> Result<(), titan_hal::KeyStoreError> {
        let key = format!("compass:{}", self.peer_id);
        let mut data = Vec::with_capacity(16);
        data.extend_from_slice(&self.n_in.to_le_bytes());
        data.extend_from_slice(&self.s_out.to_le_bytes());
        data.extend_from_slice(&self.last_signal_epoch.to_le_bytes());
        store.store(&key, &data)
    }

    /// Restore navigator from SecureKeyStore checkpoint.
    pub fn from_checkpoint(
        peer_id: &str,
        store: &dyn SecureKeyStore,
    ) -> Result<Self, titan_hal::KeyStoreError> {
        let key = format!("compass:{}", peer_id);
        let data = store.load(&key)?;
        if data.len() < 16 {
            return Err(titan_hal::KeyStoreError::StoreFailed(
                "Corrupt checkpoint".into(),
            ));
        }
        let n_in = u32::from_le_bytes(data[0..4].try_into().unwrap());
        let s_out = u32::from_le_bytes(data[4..8].try_into().unwrap());
        let last_epoch = u64::from_le_bytes(data[8..16].try_into().unwrap());
        Ok(Self::new(peer_id, n_in, s_out, last_epoch))
    }

    /// Generate the list of addresses to sweep (Batch Sweep).
    /// Returns addresses from current N_in up to N_in + max_lookahead.
    pub fn sweep_addresses(
        &self,
        shared_secret: &[u8; 32],
        max_lookahead: u32,
    ) -> Vec<(u32, [u8; 32])> {
        (0..max_lookahead)
            .map(|offset| {
                let n = self.n_in + offset;
                let addr = crate::recv_addr(shared_secret, n);
                (n, addr)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use titan_hal::MemoryKeyStore;

    #[test]
    fn test_navigator_counters() {
        let mut nav = Navigator::new("peer1", 0, 0, 100);
        nav.message_received();
        nav.message_received();
        nav.message_sent();
        assert_eq!(nav.n_in, 2);
        assert_eq!(nav.s_out, 1);
    }

    #[test]
    fn test_checkpoint_and_restore() {
        let mut store = MemoryKeyStore::new();
        let nav = Navigator::new("peer1", 42, 17, 9999);
        nav.checkpoint(&mut store).unwrap();

        let restored = Navigator::from_checkpoint("peer1", &store).unwrap();
        assert_eq!(restored.n_in, 42);
        assert_eq!(restored.s_out, 17);
        assert_eq!(restored.last_signal_epoch, 9999);
    }

    #[test]
    fn test_checkpoint_not_found() {
        let store = MemoryKeyStore::new();
        assert!(Navigator::from_checkpoint("nobody", &store).is_err());
    }

    #[test]
    fn test_sweep_addresses() {
        let nav = Navigator::new("peer1", 5, 0, 100);
        let ss = [0xAA; 32];
        let addrs = nav.sweep_addresses(&ss, 3);
        assert_eq!(addrs.len(), 3);
        assert_eq!(addrs[0].0, 5);
        assert_eq!(addrs[1].0, 6);
        assert_eq!(addrs[2].0, 7);
        // All addresses must be unique
        assert_ne!(addrs[0].1, addrs[1].1);
        assert_ne!(addrs[1].1, addrs[2].1);
    }
}
