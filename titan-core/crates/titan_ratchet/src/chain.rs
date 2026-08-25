//! Chain Key — KDF chain for symmetric ratchet.
//!
//! Each advance() produces a unique message key and advances the chain.
//! Old chain keys are zeroized — KDF is one-way (Forward Secrecy).

use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroize;

/// A chain key that produces message keys via KDF advancement.
pub struct ChainKey {
    key: [u8; 32],
}

impl ChainKey {
    /// Create a new chain key from raw bytes.
    pub fn new(key: [u8; 32]) -> Self {
        Self { key }
    }

    /// Advance the chain: derive a message key and update chain key.
    /// Returns the one-time message key (caller must zeroize after use).
    pub fn advance(&mut self) -> [u8; 32] {
        let hk = Hkdf::<Sha256>::new(None, &self.key);

        // Derive message key
        let mut message_key = [0u8; 32];
        hk.expand(b"titan-msg-key", &mut message_key)
            .expect("HKDF expand failed");

        // Derive next chain key
        let mut next_chain_key = [0u8; 32];
        hk.expand(b"titan-chain-advance", &mut next_chain_key)
            .expect("HKDF expand failed");

        // Zeroize old chain key, install new one
        self.key.zeroize();
        self.key = next_chain_key;

        message_key
    }

    /// Explicitly zeroize the chain key.
    pub fn zeroize_key(&mut self) {
        self.key.zeroize();
    }
}

impl Drop for ChainKey {
    fn drop(&mut self) {
        self.key.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_advance_produces_key() {
        let mut ck = ChainKey::new([0xAA; 32]);
        let mk = ck.advance();
        assert_ne!(mk, [0u8; 32], "Message key must not be zero");
        assert_ne!(mk, [0xAA; 32], "Message key must differ from initial chain key");
    }

    #[test]
    fn test_advance_changes_chain() {
        let mut ck = ChainKey::new([0xBB; 32]);
        let mk1 = ck.advance();
        let mk2 = ck.advance();
        assert_ne!(mk1, mk2, "Consecutive message keys must differ");
    }

    #[test]
    fn test_10_advances_all_unique() {
        let mut ck = ChainKey::new([0xCC; 32]);
        let mut keys = Vec::new();
        for _ in 0..10 {
            keys.push(ck.advance());
        }
        // All 10 keys must be unique
        for i in 0..10 {
            for j in (i + 1)..10 {
                assert_ne!(keys[i], keys[j], "Keys {} and {} must differ", i, j);
            }
        }
    }

    #[test]
    fn test_zeroize() {
        let mut ck = ChainKey::new([0xDD; 32]);
        ck.zeroize_key();
        // After zeroize, advancing should still work (from zero key)
        // but the old key is gone
        let mk = ck.advance();
        assert_ne!(mk, [0xDD; 32]);
    }
}
