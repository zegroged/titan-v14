//! Titan Hopping — Address Hopping Protocol
//!
//! Implements Yasa I (Navigation), Yasa II (Independence), Yasa III (Scalability).
//!
//! .onion is stable per-contact — address hopping happens at the HKDF coordinate
//! level INSIDE the Dead Drop, not by creating new Tor services.

pub mod navigator;

use hkdf::Hkdf;
use sha2::Sha256;
use std::time::{SystemTime, UNIX_EPOCH};

/// Epoch duration in seconds (10 minutes).
pub const EPOCH_DURATION: u64 = 600;

/// Deadlock timeout thresholds.
pub const DEADLOCK_WIDEN_SECS: u64 = 30 * 60;      // 30 min
pub const DEADLOCK_TELEPORT_SECS: u64 = 60 * 60;    // 60 min
pub const DEADLOCK_OFFLINE_SECS: u64 = 72 * 3600;   // 72 hours

/// Calculate the current epoch from unix time.
pub fn current_epoch() -> u64 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Time went backwards");
    now.as_secs() / EPOCH_DURATION
}

/// Calculate epoch from a specific unix timestamp.
pub fn epoch_from_time(unix_secs: u64) -> u64 {
    unix_secs / EPOCH_DURATION
}

/// Yasa I: Derive active address (message pickup) from shared_secret and N_in.
/// Each message gets a unique, one-time coordinate.
pub fn active_addr(shared_secret: &[u8; 32], n_in: u32, direction: &str) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, shared_secret);
    let mut addr = [0u8; 32];
    let info = format!("{}\x00{}", direction, n_in);
    hk.expand(info.as_bytes(), &mut addr)
        .expect("HKDF expand failed");
    addr
}

/// Yasa I: Derive rendezvous address (idle waiting) from shared_secret and epoch.
/// Used when no message traffic — both parties converge here.
pub fn rendezvous_addr(shared_secret: &[u8; 32], epoch: u64) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, shared_secret);
    let mut addr = [0u8; 32];
    let info = format!("rendezvous\x00{}", epoch);
    hk.expand(info.as_bytes(), &mut addr)
        .expect("HKDF expand failed");
    addr
}

/// Yasa II: Derive send address (A→B channel).
pub fn send_addr(shared_secret: &[u8; 32], s_out: u32) -> [u8; 32] {
    active_addr(shared_secret, s_out, "a-to-b")
}

/// Yasa II: Derive receive address (B→A channel).
pub fn recv_addr(shared_secret: &[u8; 32], n_in: u32) -> [u8; 32] {
    active_addr(shared_secret, n_in, "b-to-a")
}

/// Yasa III: Derive DHT notification key for a peer at a given epoch.
pub fn notify_key(shared_secret: &[u8; 32], epoch: u64) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, shared_secret);
    let mut key = [0u8; 32];
    let info = format!("notify\x00{}", epoch);
    hk.expand(info.as_bytes(), &mut key)
        .expect("HKDF expand failed");
    key
}

/// Deadlock state based on time without signal.
#[derive(Debug, PartialEq)]
pub enum DeadlockState {
    /// Normal operation.
    Normal,
    /// 30min no signal — widen search window (N±5, Epoch±1).
    Widen,
    /// 60min no signal — teleport to current rendezvous.
    Teleport,
    /// 72h no signal — peer offline, sleep circuit.
    Offline,
}

/// Determine deadlock state from seconds since last signal.
pub fn deadlock_state(secs_no_signal: u64) -> DeadlockState {
    if secs_no_signal >= DEADLOCK_OFFLINE_SECS {
        DeadlockState::Offline
    } else if secs_no_signal >= DEADLOCK_TELEPORT_SECS {
        DeadlockState::Teleport
    } else if secs_no_signal >= DEADLOCK_WIDEN_SECS {
        DeadlockState::Widen
    } else {
        DeadlockState::Normal
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_epoch_calculation() {
        assert_eq!(epoch_from_time(0), 0);
        assert_eq!(epoch_from_time(599), 0);
        assert_eq!(epoch_from_time(600), 1);
        assert_eq!(epoch_from_time(1200), 2);
    }

    #[test]
    fn test_current_epoch_nonzero() {
        assert!(current_epoch() > 0);
    }

    #[test]
    fn test_active_addr_deterministic() {
        let ss = [0xAA; 32];
        let a1 = active_addr(&ss, 5, "a→b");
        let a2 = active_addr(&ss, 5, "a→b");
        assert_eq!(a1, a2);
    }

    #[test]
    fn test_different_n_different_addr() {
        let ss = [0xBB; 32];
        let a1 = active_addr(&ss, 0, "a→b");
        let a2 = active_addr(&ss, 1, "a→b");
        assert_ne!(a1, a2);
    }

    #[test]
    fn test_send_recv_different() {
        let ss = [0xCC; 32];
        let s = send_addr(&ss, 0);
        let r = recv_addr(&ss, 0);
        assert_ne!(s, r, "Send and recv channels must be independent");
    }

    #[test]
    fn test_rendezvous_deterministic() {
        let ss = [0xDD; 32];
        let r1 = rendezvous_addr(&ss, 100);
        let r2 = rendezvous_addr(&ss, 100);
        assert_eq!(r1, r2);
    }

    #[test]
    fn test_rendezvous_different_epochs() {
        let ss = [0xEE; 32];
        let r1 = rendezvous_addr(&ss, 100);
        let r2 = rendezvous_addr(&ss, 101);
        assert_ne!(r1, r2);
    }

    #[test]
    fn test_notify_key_deterministic() {
        let ss = [0xFF; 32];
        let k1 = notify_key(&ss, 50);
        let k2 = notify_key(&ss, 50);
        assert_eq!(k1, k2);
    }

    #[test]
    fn test_deadlock_states() {
        assert_eq!(deadlock_state(0), DeadlockState::Normal);
        assert_eq!(deadlock_state(60), DeadlockState::Normal);
        assert_eq!(deadlock_state(DEADLOCK_WIDEN_SECS), DeadlockState::Widen);
        assert_eq!(deadlock_state(DEADLOCK_TELEPORT_SECS), DeadlockState::Teleport);
        assert_eq!(deadlock_state(DEADLOCK_OFFLINE_SECS), DeadlockState::Offline);
    }
}
