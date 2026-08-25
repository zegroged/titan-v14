//! Titan Ratchet — Double Ratchet Protocol
//!
//! Implements KDF chain (HKDF-SHA256) for symmetric ratchet
//! and Kyber-1024 for DH ratchet turns.
//!
//! Forward Secrecy: message keys are DELETED after use (zeroize).
//! Post-Compromise: Root Key rotation via Kyber re-exchange.

pub mod chain;

use crate::chain::ChainKey;
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroize;

/// Root key derivation from shared_secret.
pub fn derive_root_key(shared_secret: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, shared_secret);
    let mut root_key = [0u8; 32];
    hk.expand(b"titan-root-key", &mut root_key)
        .expect("HKDF expand failed");
    root_key
}

/// Derive send and receive chain keys from root key.
pub fn derive_chain_keys(root_key: &[u8; 32]) -> (ChainKey, ChainKey) {
    let hk = Hkdf::<Sha256>::new(None, root_key);

    let mut send_ck = [0u8; 32];
    hk.expand(b"titan-send-chain", &mut send_ck)
        .expect("HKDF expand failed");

    let mut recv_ck = [0u8; 32];
    hk.expand(b"titan-recv-chain", &mut recv_ck)
        .expect("HKDF expand failed");

    (ChainKey::new(send_ck), ChainKey::new(recv_ck))
}

/// Ratchet state for one conversation.
pub struct RatchetState {
    root_key: [u8; 32],
    pub send_chain: ChainKey,
    pub recv_chain: ChainKey,
    pub send_count: u64,
    pub recv_count: u64,
}

impl RatchetState {
    /// Initialize ratchet from a shared secret (post-handshake).
    pub fn init(shared_secret: &[u8]) -> Self {
        let root_key = derive_root_key(shared_secret);
        let (send_chain, recv_chain) = derive_chain_keys(&root_key);
        Self {
            root_key,
            send_chain,
            recv_chain,
            send_count: 0,
            recv_count: 0,
        }
    }

    /// Get next message key for sending (advances send chain).
    /// The message key is one-time-use — caller must zeroize after encryption.
    pub fn next_send_key(&mut self) -> [u8; 32] {
        self.send_count += 1;
        self.send_chain.advance()
    }

    /// Get next message key for receiving (advances recv chain).
    pub fn next_recv_key(&mut self) -> [u8; 32] {
        self.recv_count += 1;
        self.recv_chain.advance()
    }

    /// Perform a DH ratchet step with a new shared secret
    /// (from Kyber re-exchange). Replaces root key and both chains.
    pub fn dh_ratchet(&mut self, new_shared_secret: &[u8]) {
        // Derive new root key from old + new shared secret
        let hk = Hkdf::<Sha256>::new(Some(&self.root_key), new_shared_secret);
        let mut new_root = [0u8; 32];
        hk.expand(b"titan-dh-ratchet", &mut new_root)
            .expect("HKDF expand failed");

        // Zeroize old keys
        self.root_key.zeroize();
        self.send_chain.zeroize_key();
        self.recv_chain.zeroize_key();

        // Install new keys
        self.root_key = new_root;
        let (send, recv) = derive_chain_keys(&self.root_key);
        self.send_chain = send;
        self.recv_chain = recv;
    }
}

impl Drop for RatchetState {
    fn drop(&mut self) {
        self.root_key.zeroize();
        self.send_chain.zeroize_key();
        self.recv_chain.zeroize_key();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_init_ratchet() {
        let shared = [0xAA; 32];
        let state = RatchetState::init(&shared);
        assert_eq!(state.send_count, 0);
        assert_eq!(state.recv_count, 0);
    }

    #[test]
    fn test_send_keys_advance() {
        let mut state = RatchetState::init(&[0xBB; 32]);
        let k1 = state.next_send_key();
        let k2 = state.next_send_key();
        assert_ne!(k1, k2, "Consecutive send keys must differ");
        assert_eq!(state.send_count, 2);
    }

    #[test]
    fn test_recv_keys_advance() {
        let mut state = RatchetState::init(&[0xCC; 32]);
        let k1 = state.next_recv_key();
        let k2 = state.next_recv_key();
        assert_ne!(k1, k2, "Consecutive recv keys must differ");
        assert_eq!(state.recv_count, 2);
    }

    #[test]
    fn test_send_recv_independent() {
        let mut state = RatchetState::init(&[0xDD; 32]);
        let sk = state.next_send_key();
        let rk = state.next_recv_key();
        assert_ne!(sk, rk, "Send and recv chains must be independent");
    }

    #[test]
    fn test_dh_ratchet_changes_keys() {
        let mut state = RatchetState::init(&[0xEE; 32]);
        let old_send = state.next_send_key();

        state.dh_ratchet(&[0xFF; 32]);
        let new_send = state.next_send_key();

        assert_ne!(old_send, new_send, "DH ratchet must change chain keys");
    }

    #[test]
    fn test_same_shared_secret_same_state() {
        let s1 = RatchetState::init(&[0x11; 32]);
        let s2 = RatchetState::init(&[0x11; 32]);
        // Same shared secret → same initial keys
        assert_eq!(s1.root_key, s2.root_key);
    }
}
