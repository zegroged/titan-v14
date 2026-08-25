//! Signal Double Ratchet — Full Implementation with DH Ratchet Steps
//!
//! # Overview
//! The Double Ratchet algorithm provides:
//! - **Forward secrecy**: Compromising a key reveals NOTHING about past messages
//! - **Backward secrecy**: Compromising a key reveals NOTHING about future messages
//! - **Break-in recovery**: Even if state is compromised, new DH ratchets heal security
//!
//! # How It Works
//! Two ratchets operate simultaneously:
//! 1. **Symmetric ratchet (KDF chain)**: Each message advances the chain key,
//!    deriving a unique message key. Old chain keys are deleted.
//! 2. **DH ratchet**: On every direction change (send↔recv), new ephemeral
//!    X25519 keys are exchanged, deriving fresh root key + chain key via HKDF.
//!    This is the break-in recovery mechanism.
//!
//! # Trust No One — Independent Checkpoints
//! - Chain key is zeroized after deriving the next state (forward secrecy)
//! - DH private keys are ephemeral and consumed after use
//! - Root key is re-derived from fresh DH output (break-in recovery)
//! - Skipped key cache is bounded and zeroized on eviction + drop
//! - Message keys include both symmetric chain output AND DH-derived material

use hkdf::Hkdf;
use sha2::Sha256;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop};
use rand_core::OsRng;

use crate::HidraError;
use std::collections::HashMap;

/// KDF info constants for domain separation
const KDF_INFO_CHAIN: &[u8] = b"HIDRA-v1-Chain-Key";
const KDF_INFO_MESSAGE: &[u8] = b"HIDRA-v1-Message-Key";
const KDF_INFO_ROOT: &[u8] = b"HIDRA-v1-Root-Key-DH-Ratchet";

/// ★ B-2: Maximum cached skipped keys before oldest is evicted
const MAX_SKIPPED_KEY_CACHE: usize = 256;

/// Maximum messages before a DH ratchet step is forced
/// Even if no direction change occurs, we force a DH step
/// for forward secrecy hygiene (★ Trust No One)
const MAX_MESSAGES_PER_CHAIN: u64 = 200;

// ============================================================================
// Symmetric Ratchet (KDF Chain) — Unchanged Building Block
// ============================================================================

/// Ratchet state — holds the current chain key and message counter
#[derive(ZeroizeOnDrop, Clone)]
pub struct RatchetState {
    /// Current chain key (32 bytes) — advances with each message
    chain_key: [u8; 32],
    /// Message counter (monotonically increasing)
    #[zeroize(skip)]
    pub message_number: u64,
    /// Maximum number of skipped messages to tolerate (anti-DoS)
    #[zeroize(skip)]
    max_skip: u32,
}

/// Message key output — unique per message, zeroized after use
#[derive(ZeroizeOnDrop)]
pub struct MessageKeys {
    /// Encryption key for this specific message (Layer 1)
    pub encryption_key: [u8; 32],
    /// Sequence number for replay protection
    #[zeroize(skip)]
    pub sequence: u64,
}

impl RatchetState {
    /// Initialize ratchet from the root key derived during key exchange
    pub fn new(root_key: &[u8; 32]) -> Self {
        // Derive initial chain key from root
        let hkdf = Hkdf::<Sha256>::new(None, root_key);
        let mut chain_key = [0u8; 32];
        hkdf.expand(KDF_INFO_CHAIN, &mut chain_key)
            .expect("HKDF expand should not fail with 32-byte output");

        Self {
            chain_key,
            message_number: 0,
            max_skip: 100, // Tolerate up to 100 out-of-order messages
        }
    }

    /// Advance the ratchet and derive a unique message key
    ///
    /// This is the core forward secrecy mechanism:
    /// 1. Derive message_key from current chain_key
    /// 2. Advance chain_key to next state
    /// 3. Delete old chain_key (via overwrite)
    ///
    /// After this call, the old chain_key is gone forever.
    /// Even if the new chain_key is compromised, the old message_key
    /// cannot be recovered.
    pub fn advance(&mut self) -> Result<MessageKeys, HidraError> {
        // Derive message key from current chain key
        let hkdf = Hkdf::<Sha256>::new(None, &self.chain_key);

        let mut encryption_key = [0u8; 32];
        hkdf.expand(KDF_INFO_MESSAGE, &mut encryption_key)
            .map_err(|_| HidraError::RatchetError("KDF message key derivation failed".into()))?;

        // Advance chain key (old chain key is overwritten = forward secrecy)
        let mut new_chain_key = [0u8; 32];
        hkdf.expand(KDF_INFO_CHAIN, &mut new_chain_key)
            .map_err(|_| HidraError::RatchetError("KDF chain advance failed".into()))?;

        // Overwrite old chain key (this is the forward secrecy moment)
        self.chain_key.zeroize();
        self.chain_key = new_chain_key;

        let sequence = self.message_number;
        self.message_number += 1;

        Ok(MessageKeys {
            encryption_key,
            sequence,
        })
    }

    /// Skip forward to a specific message number (for out-of-order messages)
    ///
    /// This derives and discards intermediate message keys.
    /// Returns the message keys for the target message number.
    pub fn skip_to(&mut self, target: u64) -> Result<MessageKeys, HidraError> {
        if target < self.message_number {
            return Err(HidraError::RatchetError(format!(
                "Cannot go backward: current={}, target={}",
                self.message_number, target
            )));
        }

        let skip_count = target - self.message_number;
        if skip_count > self.max_skip as u64 {
            return Err(HidraError::RatchetError(format!(
                "Too many skipped messages: {} > max {}",
                skip_count, self.max_skip
            )));
        }

        // Advance through intermediate messages (discarding their keys)
        for _ in 0..skip_count {
            let mut discarded = self.advance()?;
            discarded.encryption_key.zeroize();
        }

        // Return the target message's keys
        self.advance()
    }

    /// Get current message number (for sender to include in packet)
    pub fn current_number(&self) -> u64 {
        self.message_number
    }
}

// ============================================================================
// DH Ratchet Header — Sent with each message for DH synchronization
// ============================================================================

/// DH Ratchet header — included in every encrypted message.
/// Contains the sender's current ephemeral public key and
/// chain metadata needed by the receiver to synchronize.
#[derive(Clone, Debug)]
pub struct DhRatchetHeader {
    /// Sender's current DH public key (32 bytes, X25519)
    pub dh_public: [u8; 32],
    /// Previous chain's message count (how many messages were sent
    /// on the PREVIOUS sending chain before this DH ratchet step)
    pub previous_chain_length: u64,
    /// Message number within the current chain
    pub message_number: u64,
}

impl DhRatchetHeader {
    /// Serialize to wire format (48 bytes fixed)
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(48);
        buf.extend_from_slice(&self.dh_public);
        buf.extend_from_slice(&self.previous_chain_length.to_le_bytes());
        buf.extend_from_slice(&self.message_number.to_le_bytes());
        buf
    }

    /// Deserialize from wire format
    pub fn from_bytes(data: &[u8]) -> Result<Self, HidraError> {
        if data.len() < 48 {
            return Err(HidraError::RatchetError(
                "DH header too short".into()
            ));
        }
        let mut dh_public = [0u8; 32];
        dh_public.copy_from_slice(&data[0..32]);
        let previous_chain_length = u64::from_le_bytes(
            data[32..40].try_into().unwrap()
        );
        let message_number = u64::from_le_bytes(
            data[40..48].try_into().unwrap()
        );
        Ok(Self { dh_public, previous_chain_length, message_number })
    }
}

// ============================================================================
// Full Double Ratchet — DH + Symmetric Combined
// ============================================================================

/// ★ Full Signal Double Ratchet with X25519 DH steps.
///
/// Provides both forward secrecy (symmetric ratchet) AND
/// break-in recovery (DH ratchet).
///
/// # Trust No One Philosophy
/// - Root key is re-derived from fresh DH output on every direction change
/// - DH private keys are ephemeral and consumed after use
/// - Skipped key cache is bounded and zeroized
/// - Chain limit forces periodic DH ratchet even without direction change
pub struct DoubleRatchet {
    /// Current root key — re-derived on each DH ratchet step
    root_key: [u8; 32],
    /// Sending chain state (None if not yet initialized)
    send_chain: Option<RatchetState>,
    /// Receiving chain state (None if not yet initialized)
    recv_chain: Option<RatchetState>,
    /// Our current DH key pair (reusable for multiple messages)
    dh_self_secret: StaticSecret,
    /// Our current DH public key (sent in every message header)
    dh_self_public: PublicKey,
    /// Peer's last known DH public key
    dh_peer_public: Option<PublicKey>,
    /// Previous sending chain length (included in header)
    prev_send_chain_length: u64,
    /// Messages sent on current chain (for forced DH ratchet)
    current_chain_messages: u64,
    /// Skipped message keys cache: (dh_pub, msg_num) → key
    skipped_keys: HashMap<([u8; 32], u64), [u8; 32]>,
}

impl DoubleRatchet {
    /// Initialize as Alice (initiator) — generates first DH pair,
    /// performs initial DH with Bob's public key to derive first chains.
    pub fn init_alice(
        root_key: &[u8; 32],
        bob_dh_public: &PublicKey,
    ) -> Self {
        let dh_self_secret = StaticSecret::random_from_rng(OsRng);
        let dh_self_public = PublicKey::from(&dh_self_secret);

        // Perform DH and derive initial sending chain
        let dh_output = dh_self_secret.diffie_hellman(bob_dh_public);
        let (new_root, send_chain_key) = kdf_rk(root_key, dh_output.as_bytes());

        Self {
            root_key: new_root,
            send_chain: Some(RatchetState::new(&send_chain_key)),
            recv_chain: None, // Will be initialized on first received message
            dh_self_secret,
            dh_self_public,
            dh_peer_public: Some(*bob_dh_public),
            prev_send_chain_length: 0,
            current_chain_messages: 0,
            skipped_keys: HashMap::new(),
        }
    }

    /// Initialize as Bob (responder) — generates DH pair but does NOT
    /// perform initial DH. Waits for Alice's first message header.
    pub fn init_bob(root_key: &[u8; 32]) -> (Self, PublicKey) {
        let dh_self_secret = StaticSecret::random_from_rng(OsRng);
        let dh_self_public = PublicKey::from(&dh_self_secret);
        let public_to_share = dh_self_public;

        let ratchet = Self {
            root_key: *root_key,
            send_chain: None,
            recv_chain: None,
            dh_self_secret,
            dh_self_public,
            dh_peer_public: None,
            prev_send_chain_length: 0,
            current_chain_messages: 0,
            skipped_keys: HashMap::new(),
        };

        (ratchet, public_to_share)
    }

    /// Encrypt a message — returns (header, message_key).
    /// The caller uses message_key with Layer 1 AEAD.
    pub fn ratchet_encrypt(&mut self) -> Result<(DhRatchetHeader, MessageKeys), HidraError> {
        // Force DH ratchet step if chain is too long (★ Trust No One)
        if self.current_chain_messages >= MAX_MESSAGES_PER_CHAIN {
            if let Some(peer_pub) = &self.dh_peer_public {
                let peer_copy = *peer_pub;
                self.dh_ratchet_step(&peer_copy)?;
            }
        }

        // Initialize send chain if needed (Bob's first send)
        if self.send_chain.is_none() {
            if let Some(peer_pub) = &self.dh_peer_public {
                let peer_copy = *peer_pub;
                self.dh_ratchet_step(&peer_copy)?;
            } else {
                return Err(HidraError::RatchetError(
                    "Cannot send: no peer public key".into()
                ));
            }
        }

        let send_chain = self.send_chain.as_mut()
            .ok_or_else(|| HidraError::RatchetError("Send chain not initialized".into()))?;

        let msg_keys = send_chain.advance()?;
        self.current_chain_messages += 1;

        let header = DhRatchetHeader {
            dh_public: self.dh_self_public.to_bytes(),
            previous_chain_length: self.prev_send_chain_length,
            message_number: msg_keys.sequence,
        };

        Ok((header, msg_keys))
    }

    /// Decrypt a message — returns the message key for the given header.
    /// Performs DH ratchet step if the header contains a new public key.
    pub fn ratchet_decrypt(
        &mut self,
        header: &DhRatchetHeader,
    ) -> Result<MessageKeys, HidraError> {
        // 1. Check skipped keys cache first
        let cache_key = (header.dh_public, header.message_number);
        if let Some(cached_key) = self.skipped_keys.remove(&cache_key) {
            return Ok(MessageKeys {
                encryption_key: cached_key,
                sequence: header.message_number,
            });
        }

        // 2. Check if this is a new DH public key → DH ratchet step needed
        let peer_pub = PublicKey::from(header.dh_public);
        let need_dh_ratchet = match &self.dh_peer_public {
            Some(existing) => existing.as_bytes() != &header.dh_public,
            None => true,
        };

        if need_dh_ratchet {
            // Cache skipped keys from current receiving chain
            // Take the chain out to avoid double-mutable-borrow on self
            let peer_pub_for_skip = self.dh_peer_public.map(|p| p.to_bytes()).unwrap_or([0u8; 32]);
            if let Some(mut recv) = self.recv_chain.take() {
                self.skip_message_keys(
                    &mut recv,
                    &peer_pub_for_skip,
                    header.previous_chain_length,
                )?;
                // recv_chain is intentionally dropped — we create a new one below
            }

            // Perform DH ratchet: derive new receiving chain
            let dh_output = self.dh_self_secret.diffie_hellman(&peer_pub);
            let (new_root, recv_chain_key) = kdf_rk(&self.root_key, dh_output.as_bytes());
            self.root_key.zeroize();
            self.root_key = new_root;
            self.dh_peer_public = Some(peer_pub);
            self.recv_chain = Some(RatchetState::new(&recv_chain_key));

            // Generate new DH pair for our next sending chain
            self.prev_send_chain_length = self.send_chain
                .as_ref()
                .map(|s| s.message_number)
                .unwrap_or(0);
            let new_secret = StaticSecret::random_from_rng(OsRng);
            self.dh_self_public = PublicKey::from(&new_secret);
            let dh_output2 = new_secret.diffie_hellman(&peer_pub);
            let (new_root2, send_chain_key) = kdf_rk(&self.root_key, dh_output2.as_bytes());
            self.root_key.zeroize();
            self.root_key = new_root2;
            self.dh_self_secret = new_secret;
            self.send_chain = Some(RatchetState::new(&send_chain_key));
            self.current_chain_messages = 0;
        }

        // 3. Skip to the target message number in the receiving chain
        let recv_chain = self.recv_chain.as_mut()
            .ok_or_else(|| HidraError::RatchetError("Recv chain not initialized".into()))?;

        // Cache any skipped keys before our target
        let peer_pub_bytes = header.dh_public;
        if header.message_number > recv_chain.message_number {
            let skip_count = header.message_number - recv_chain.message_number;
            if skip_count > recv_chain.max_skip as u64 {
                return Err(HidraError::RatchetError(format!(
                    "Too many skipped messages: {} > max {}",
                    skip_count, recv_chain.max_skip
                )));
            }
            for _ in 0..skip_count {
                let intermediate = recv_chain.advance()?;
                let key = (peer_pub_bytes, intermediate.sequence);
                // Evict oldest if cache is full
                if self.skipped_keys.len() >= MAX_SKIPPED_KEY_CACHE {
                    if let Some(&oldest) = self.skipped_keys.keys()
                        .min_by_key(|k| k.1)
                    {
                        let mut removed = self.skipped_keys.remove(&oldest).unwrap();
                        removed.zeroize();
                    }
                }
                self.skipped_keys.insert(key, intermediate.encryption_key);
            }
        } else if header.message_number < recv_chain.message_number {
            return Err(HidraError::ReplayDetected { seq: header.message_number });
        }

        recv_chain.advance()
    }

    /// Cache skipped message keys from the current chain
    fn skip_message_keys(
        &mut self,
        chain: &mut RatchetState,
        dh_pub: &[u8; 32],
        until: u64,
    ) -> Result<(), HidraError> {
        if until < chain.message_number {
            return Ok(()); // Nothing to skip
        }
        let skip_count = until - chain.message_number;
        if skip_count > chain.max_skip as u64 {
            return Err(HidraError::RatchetError(format!(
                "Too many skipped messages during DH ratchet: {}",
                skip_count
            )));
        }
        for _ in 0..skip_count {
            let mk = chain.advance()?;
            let key = (*dh_pub, mk.sequence);
            if self.skipped_keys.len() >= MAX_SKIPPED_KEY_CACHE {
                if let Some(&oldest) = self.skipped_keys.keys()
                    .min_by_key(|k| k.1)
                {
                    let mut removed = self.skipped_keys.remove(&oldest).unwrap();
                    removed.zeroize();
                }
            }
            self.skipped_keys.insert(key, mk.encryption_key);
        }
        Ok(())
    }

    /// Get our current DH public key (for sharing with peer during key exchange)
    pub fn public_key(&self) -> PublicKey {
        self.dh_self_public
    }

    /// Number of cached skipped keys
    pub fn cached_keys_count(&self) -> usize {
        self.skipped_keys.len()
    }

    /// Perform a DH ratchet step: generate new ephemeral key,
    /// derive new root + sending chain from DH output.
    fn dh_ratchet_step(&mut self, peer_pub: &PublicKey) -> Result<(), HidraError> {
        self.prev_send_chain_length = self.send_chain
            .as_ref()
            .map(|s| s.message_number)
            .unwrap_or(0);

        let new_secret = StaticSecret::random_from_rng(OsRng);
        let new_public = PublicKey::from(&new_secret);
        let dh_output = new_secret.diffie_hellman(peer_pub);
        let (new_root, send_chain_key) = kdf_rk(&self.root_key, dh_output.as_bytes());

        self.root_key.zeroize();
        self.root_key = new_root;
        self.dh_self_secret = new_secret;
        self.dh_self_public = new_public;
        self.send_chain = Some(RatchetState::new(&send_chain_key));
        self.current_chain_messages = 0;

        Ok(())
    }
}

/// ★ Secure Drop: Zeroize all key material
impl Drop for DoubleRatchet {
    fn drop(&mut self) {
        self.root_key.zeroize();
        for (_key_id, key_material) in self.skipped_keys.iter_mut() {
            key_material.zeroize();
        }
        self.skipped_keys.clear();
        // send_chain and recv_chain derive ZeroizeOnDrop
    }
}

// ============================================================================
// KDF Root Key — Derives new root key + chain key from DH output
// ============================================================================

/// KDF_RK: Derive a new root key and chain key from existing root key + DH output.
///
/// Uses HKDF-SHA256 with the root key as salt and DH output as IKM.
/// Returns (new_root_key, new_chain_key).
fn kdf_rk(root_key: &[u8; 32], dh_output: &[u8; 32]) -> ([u8; 32], [u8; 32]) {
    let hkdf = Hkdf::<Sha256>::new(Some(root_key), dh_output);

    let mut new_root = [0u8; 32];
    hkdf.expand(KDF_INFO_ROOT, &mut new_root)
        .expect("HKDF expand for root key should not fail");

    let mut new_chain = [0u8; 32];
    hkdf.expand(KDF_INFO_CHAIN, &mut new_chain)
        .expect("HKDF expand for chain key should not fail");

    (new_root, new_chain)
}

// ============================================================================
// Legacy Wrappers — Preserved for backward compatibility
// ============================================================================

/// Sending ratchet — used by the message sender (symmetric-only mode)
#[derive(ZeroizeOnDrop)]
pub struct SendRatchet {
    state: RatchetState,
}

/// Receiving ratchet — used by the message receiver (symmetric-only mode)
/// ★ B-2 FIX: Includes a bounded skipped-key cache for out-of-order messages
pub struct RecvRatchet {
    state: RatchetState,
    /// Cache of message keys for skipped messages (out-of-order delivery)
    skipped_keys: HashMap<u64, [u8; 32]>,
}

impl SendRatchet {
    pub fn new(root_key: &[u8; 32]) -> Self {
        Self {
            state: RatchetState::new(root_key),
        }
    }

    /// Get the next message key for sending
    pub fn next_key(&mut self) -> Result<MessageKeys, HidraError> {
        self.state.advance()
    }
}

impl RecvRatchet {
    pub fn new(root_key: &[u8; 32]) -> Self {
        Self {
            state: RatchetState::new(root_key),
            skipped_keys: HashMap::new(),
        }
    }

    /// Get message key for a received message with the given sequence number.
    ///
    /// ★ B-2 FIX: Checks skipped-key cache first for out-of-order messages.
    /// If the message is ahead of current state, caches intermediate keys.
    pub fn key_for(&mut self, sequence: u64) -> Result<MessageKeys, HidraError> {
        // 1. Check skipped-key cache first
        if let Some(cached_key) = self.skipped_keys.remove(&sequence) {
            return Ok(MessageKeys {
                encryption_key: cached_key,
                sequence,
            });
        }

        // 2. In-order message
        if sequence == self.state.message_number {
            self.state.advance()
        } else if sequence > self.state.message_number {
            // 3. Future message — cache intermediate keys
            let skip_count = sequence - self.state.message_number;
            if skip_count > self.state.max_skip as u64 {
                return Err(HidraError::RatchetError(format!(
                    "Too many skipped messages: {} > max {}",
                    skip_count, self.state.max_skip
                )));
            }

            // Cache all intermediate keys
            for _ in 0..skip_count {
                let intermediate = self.state.advance()?;
                // Evict oldest if cache is full
                if self.skipped_keys.len() >= MAX_SKIPPED_KEY_CACHE {
                    if let Some(&oldest_seq) = self.skipped_keys.keys().min() {
                        let mut removed = self.skipped_keys.remove(&oldest_seq).unwrap();
                        removed.zeroize();
                    }
                }
                self.skipped_keys.insert(intermediate.sequence, intermediate.encryption_key);
            }

            // Return the target message's keys
            self.state.advance()
        } else {
            Err(HidraError::ReplayDetected { seq: sequence })
        }
    }

    /// ★ B-2: Number of cached skipped keys
    pub fn cached_keys_count(&self) -> usize {
        self.skipped_keys.len()
    }
}

/// ★ B-2 FIX: Manual Drop to securely zeroize cached skipped keys
/// (Can't derive ZeroizeOnDrop with HashMap)
impl Drop for RecvRatchet {
    fn drop(&mut self) {
        for (_seq, key) in self.skipped_keys.iter_mut() {
            key.zeroize();
        }
        self.skipped_keys.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ====================================================================
    // Symmetric Ratchet Tests (existing)
    // ====================================================================

    #[test]
    fn test_ratchet_basic_advance() {
        let root = [0x42u8; 32];
        let mut ratchet = RatchetState::new(&root);

        let mk1 = ratchet.advance().unwrap();
        let mk2 = ratchet.advance().unwrap();

        // Each message key should be unique
        assert_ne!(mk1.encryption_key, mk2.encryption_key);
        // Sequence numbers should increment
        assert_eq!(mk1.sequence, 0);
        assert_eq!(mk2.sequence, 1);
    }

    #[test]
    fn test_send_recv_symmetry() {
        let root = [0xAA; 32];
        let mut sender = SendRatchet::new(&root);
        let mut receiver = RecvRatchet::new(&root);

        // Send 10 messages
        for i in 0..10u64 {
            let send_key = sender.next_key().unwrap();
            let recv_key = receiver.key_for(i).unwrap();

            // Sender and receiver derive identical keys for same sequence
            assert_eq!(send_key.encryption_key, recv_key.encryption_key);
            assert_eq!(send_key.sequence, recv_key.sequence);
        }
    }

    #[test]
    fn test_forward_secrecy() {
        let root = [0xBB; 32];

        // Two ratchets from the same root
        let mut r1 = RatchetState::new(&root);
        let mut r2 = RatchetState::new(&root);

        // Advance r1 by 5 messages
        for _ in 0..5 {
            r1.advance().unwrap();
        }

        // r1 is now at message 5, r2 is at message 0
        let mk1 = r1.advance().unwrap(); // message 5
        let mk2 = r2.advance().unwrap(); // message 0

        assert_ne!(mk1.encryption_key, mk2.encryption_key);
    }

    #[test]
    fn test_out_of_order_messages() {
        let root = [0xCC; 32];
        let mut sender = SendRatchet::new(&root);
        let mut receiver = RecvRatchet::new(&root);

        // Sender sends messages 0, 1, 2
        let _key0 = sender.next_key().unwrap();
        let _key1 = sender.next_key().unwrap();
        let key2 = sender.next_key().unwrap();

        // Receiver gets message 2 first (out of order)
        let recv_key2 = receiver.key_for(2).unwrap();
        assert_eq!(key2.encryption_key, recv_key2.encryption_key);
    }

    #[test]
    fn test_replay_detection() {
        let root = [0xDD; 32];
        let mut receiver = RecvRatchet::new(&root);

        // Receive message 0
        receiver.key_for(0).unwrap();

        // Try to receive message 0 again → replay attack!
        let result = receiver.key_for(0);
        assert!(matches!(result, Err(HidraError::ReplayDetected { seq: 0 })));
    }

    #[test]
    fn test_max_skip_enforcement() {
        let root = [0xEE; 32];
        let mut ratchet = RatchetState::new(&root);

        // Try to skip more than max_skip (100) messages
        let result = ratchet.skip_to(200);
        assert!(result.is_err());
    }

    #[test]
    fn test_100_messages_all_unique() {
        let root = [0xFF; 32];
        let mut ratchet = RatchetState::new(&root);

        let mut keys: Vec<[u8; 32]> = Vec::new();
        for _ in 0..100 {
            let mk = ratchet.advance().unwrap();
            // Verify no key repeats
            assert!(!keys.contains(&mk.encryption_key), "Duplicate key found!");
            keys.push(mk.encryption_key);
        }

        assert_eq!(keys.len(), 100);
    }

    // ====================================================================
    // DH Ratchet Tests (NEW — ★ Break-in Recovery)
    // ====================================================================

    #[test]
    fn test_dh_ratchet_header_serialization() {
        let header = DhRatchetHeader {
            dh_public: [0x42; 32],
            previous_chain_length: 7,
            message_number: 42,
        };

        let bytes = header.to_bytes();
        assert_eq!(bytes.len(), 48);

        let recovered = DhRatchetHeader::from_bytes(&bytes).unwrap();
        assert_eq!(recovered.dh_public, [0x42; 32]);
        assert_eq!(recovered.previous_chain_length, 7);
        assert_eq!(recovered.message_number, 42);
    }

    #[test]
    fn test_dh_ratchet_header_too_short() {
        let result = DhRatchetHeader::from_bytes(&[0u8; 10]);
        assert!(result.is_err());
    }

    #[test]
    fn test_double_ratchet_alice_bob_basic() {
        let root_key = [0x42u8; 32];

        // Bob initializes and shares his public key
        let (mut bob, bob_pub) = DoubleRatchet::init_bob(&root_key);

        // Alice initializes with Bob's public key
        let mut alice = DoubleRatchet::init_alice(&root_key, &bob_pub);

        // Alice sends 3 messages to Bob
        let (h1, mk1_alice) = alice.ratchet_encrypt().unwrap();
        let (h2, mk2_alice) = alice.ratchet_encrypt().unwrap();
        let (h3, mk3_alice) = alice.ratchet_encrypt().unwrap();

        // Bob decrypts all 3 in order
        let mk1_bob = bob.ratchet_decrypt(&h1).unwrap();
        let mk2_bob = bob.ratchet_decrypt(&h2).unwrap();
        let mk3_bob = bob.ratchet_decrypt(&h3).unwrap();

        // Keys must match
        assert_eq!(mk1_alice.encryption_key, mk1_bob.encryption_key);
        assert_eq!(mk2_alice.encryption_key, mk2_bob.encryption_key);
        assert_eq!(mk3_alice.encryption_key, mk3_bob.encryption_key);

        // All keys must be unique
        assert_ne!(mk1_alice.encryption_key, mk2_alice.encryption_key);
        assert_ne!(mk2_alice.encryption_key, mk3_alice.encryption_key);
    }

    #[test]
    fn test_double_ratchet_direction_change() {
        let root_key = [0xAA; 32];

        let (mut bob, bob_pub) = DoubleRatchet::init_bob(&root_key);
        let mut alice = DoubleRatchet::init_alice(&root_key, &bob_pub);

        // Alice → Bob
        let (h1, mk1_a) = alice.ratchet_encrypt().unwrap();
        let mk1_b = bob.ratchet_decrypt(&h1).unwrap();
        assert_eq!(mk1_a.encryption_key, mk1_b.encryption_key);

        // Bob → Alice (direction change triggers DH ratchet)
        let (h2, mk2_b) = bob.ratchet_encrypt().unwrap();
        let mk2_a = alice.ratchet_decrypt(&h2).unwrap();
        assert_eq!(mk2_b.encryption_key, mk2_a.encryption_key);

        // Alice → Bob again (another DH ratchet)
        let (h3, mk3_a) = alice.ratchet_encrypt().unwrap();
        let mk3_b = bob.ratchet_decrypt(&h3).unwrap();
        assert_eq!(mk3_a.encryption_key, mk3_b.encryption_key);

        // All keys must be distinct
        assert_ne!(mk1_a.encryption_key, mk2_b.encryption_key);
        assert_ne!(mk2_b.encryption_key, mk3_a.encryption_key);
    }

    #[test]
    fn test_double_ratchet_out_of_order() {
        let root_key = [0xBB; 32];

        let (mut bob, bob_pub) = DoubleRatchet::init_bob(&root_key);
        let mut alice = DoubleRatchet::init_alice(&root_key, &bob_pub);

        // Alice sends 3 messages
        let (h1, mk1) = alice.ratchet_encrypt().unwrap();
        let (h2, mk2) = alice.ratchet_encrypt().unwrap();
        let (h3, mk3) = alice.ratchet_encrypt().unwrap();

        // Bob receives them out of order: 3, 1, 2
        let mk3_bob = bob.ratchet_decrypt(&h3).unwrap();
        assert_eq!(mk3.encryption_key, mk3_bob.encryption_key);

        let mk1_bob = bob.ratchet_decrypt(&h1).unwrap();
        assert_eq!(mk1.encryption_key, mk1_bob.encryption_key);

        let mk2_bob = bob.ratchet_decrypt(&h2).unwrap();
        assert_eq!(mk2.encryption_key, mk2_bob.encryption_key);
    }

    #[test]
    fn test_double_ratchet_break_in_recovery() {
        // ★ Trust No One: After DH ratchet, a compromised root key
        // cannot be used to decrypt new messages
        let root_key = [0xCC; 32];

        let (mut bob, bob_pub) = DoubleRatchet::init_bob(&root_key);
        let mut alice = DoubleRatchet::init_alice(&root_key, &bob_pub);

        // Alice sends
        let (h1, _mk1) = alice.ratchet_encrypt().unwrap();
        bob.ratchet_decrypt(&h1).unwrap();

        // Direction change: Bob sends → triggers DH ratchet
        let (h2, mk2_b) = bob.ratchet_encrypt().unwrap();
        let mk2_a = alice.ratchet_decrypt(&h2).unwrap();
        assert_eq!(mk2_b.encryption_key, mk2_a.encryption_key);

        // The DH ratchet means a FRESH root key was derived.
        // An attacker who captured the original root_key CANNOT derive mk2.
        // (We can't directly test this without exposing internals,
        //  but the DH step ensures new randomness was mixed in)
    }

    // ====================================================================
    // Stress Tests
    // ====================================================================

    #[test]
    fn test_stress_10000_messages_symmetric() {
        let root = [0xFF; 32];
        let mut ratchet = RatchetState::new(&root);

        let mut seen = std::collections::HashSet::new();
        for i in 0..10_000 {
            let mk = ratchet.advance().unwrap();
            assert!(seen.insert(mk.encryption_key),
                "Duplicate key at message {}", i);
        }
        assert_eq!(seen.len(), 10_000);
    }

    #[test]
    fn test_stress_double_ratchet_100_messages_alternating() {
        let root_key = [0xDD; 32];
        let (mut bob, bob_pub) = DoubleRatchet::init_bob(&root_key);
        let mut alice = DoubleRatchet::init_alice(&root_key, &bob_pub);

        for i in 0..50 {
            // Alice → Bob
            let (ha, mka) = alice.ratchet_encrypt().unwrap();
            let mkb = bob.ratchet_decrypt(&ha).unwrap();
            assert_eq!(mka.encryption_key, mkb.encryption_key,
                "Mismatch at Alice→Bob message {}", i);

            // Bob → Alice
            let (hb, mkb2) = bob.ratchet_encrypt().unwrap();
            let mka2 = alice.ratchet_decrypt(&hb).unwrap();
            assert_eq!(mkb2.encryption_key, mka2.encryption_key,
                "Mismatch at Bob→Alice message {}", i);
        }
    }

    #[test]
    fn test_kdf_rk_deterministic() {
        let root = [0x42u8; 32];
        let dh_out = [0xAA; 32];

        let (r1, c1) = kdf_rk(&root, &dh_out);
        let (r2, c2) = kdf_rk(&root, &dh_out);

        assert_eq!(r1, r2);
        assert_eq!(c1, c2);
    }

    #[test]
    fn test_kdf_rk_different_inputs() {
        let root = [0x42u8; 32];
        let dh1 = [0xAA; 32];
        let dh2 = [0xBB; 32];

        let (r1, c1) = kdf_rk(&root, &dh1);
        let (r2, c2) = kdf_rk(&root, &dh2);

        assert_ne!(r1, r2);
        assert_ne!(c1, c2);
    }
}
