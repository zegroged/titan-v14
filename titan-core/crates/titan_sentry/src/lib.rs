//! Titan Sentry — Adaptive Polling + Null Packet Injection
//!
//! FCM-free background notification engine.
//! Three modes: Foreground (60s), Background (10min), Doze (DHT only).
//! Null packets maintain constant traffic flow to defeat ISP analysis.

use std::time::Duration;

/// Polling modes with their intervals.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PollingMode {
    /// Active use — 60 second heartbeat.
    Foreground,
    /// App in background — epoch-based (10 minutes).
    Background,
    /// Device in Doze — minimal DHT check only.
    Doze,
}

impl PollingMode {
    /// Get the polling interval for this mode.
    pub fn interval(&self) -> Duration {
        match self {
            PollingMode::Foreground => Duration::from_secs(60),
            PollingMode::Background => Duration::from_secs(600),
            PollingMode::Doze => Duration::from_secs(600),
        }
    }

    /// Whether Tor circuit should be awake in this mode.
    pub fn tor_awake(&self) -> bool {
        match self {
            PollingMode::Foreground => true,
            PollingMode::Background => false, // wake only on signal
            PollingMode::Doze => false,
        }
    }
}

/// Sentry service state.
pub struct SentryState {
    pub mode: PollingMode,
    pub null_packet_enabled: bool,
    pub time_drift_warned: bool,
}

impl SentryState {
    pub fn new() -> Self {
        Self {
            mode: PollingMode::Foreground,
            null_packet_enabled: true,
            time_drift_warned: false,
        }
    }

    /// Switch polling mode.
    pub fn set_mode(&mut self, mode: PollingMode) {
        self.mode = mode;
    }

    /// Check if Tor should wake up based on current mode and signal.
    pub fn should_wake_tor(&self, dht_signal_positive: bool) -> bool {
        match self.mode {
            PollingMode::Foreground => true,
            PollingMode::Background | PollingMode::Doze => dht_signal_positive,
        }
    }

    /// Check for time drift between device time and consensus time.
    /// Returns true if drift is acceptable.
    pub fn check_time_drift(&mut self, device_epoch: u64, consensus_epoch: u64) -> bool {
        let drift_epochs = if device_epoch > consensus_epoch {
            device_epoch - consensus_epoch
        } else {
            consensus_epoch - device_epoch
        };

        // 1 hour = 6 epochs (each 10 min)
        if drift_epochs > 6 {
            self.time_drift_warned = true;
            false // drift too large, warn user
        } else {
            self.time_drift_warned = false;
            true
        }
    }
}

impl Default for SentryState {
    fn default() -> Self {
        Self::new()
    }
}

/// Generate a null packet (decoy) of a given size using random bytes.
pub fn generate_null_packet(size: usize) -> Vec<u8> {
    titan_entropy::random_padding(size)
}

/// Determine the size of the next null packet (randomized to match
/// real traffic pattern: mostly 512B text, sometimes 4KB/8KB).
pub fn random_null_packet_size() -> usize {
    let mut rng = rand::thread_rng();
    let roll: u8 = rand::Rng::gen_range(&mut rng, 0..100);
    match roll {
        0..=79 => 512,   // 80% text-sized
        80..=94 => 4096, // 15% ratchet-sized
        _ => 8192,       // 5% handshake-sized
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_foreground_interval() {
        assert_eq!(PollingMode::Foreground.interval(), Duration::from_secs(60));
    }

    #[test]
    fn test_background_interval() {
        assert_eq!(PollingMode::Background.interval(), Duration::from_secs(600));
    }

    #[test]
    fn test_tor_awake_foreground() {
        assert!(PollingMode::Foreground.tor_awake());
    }

    #[test]
    fn test_tor_sleep_background() {
        assert!(!PollingMode::Background.tor_awake());
    }

    #[test]
    fn test_wake_on_signal() {
        let state = SentryState::new();
        // Background mode, signal positive → wake
        let mut bg_state = SentryState::new();
        bg_state.set_mode(PollingMode::Background);
        assert!(bg_state.should_wake_tor(true));
        assert!(!bg_state.should_wake_tor(false));
    }

    #[test]
    fn test_time_drift_ok() {
        let mut state = SentryState::new();
        assert!(state.check_time_drift(100, 103)); // 3 epochs = 30 min = OK
        assert!(!state.time_drift_warned);
    }

    #[test]
    fn test_time_drift_too_large() {
        let mut state = SentryState::new();
        assert!(!state.check_time_drift(100, 110)); // 10 epochs = 100 min > 1 hour
        assert!(state.time_drift_warned);
    }

    #[test]
    fn test_null_packet_size_distribution() {
        // Run many times and check all sizes appear
        let mut seen_512 = false;
        let mut seen_4096 = false;
        let mut seen_8192 = false;
        for _ in 0..1000 {
            match random_null_packet_size() {
                512 => seen_512 = true,
                4096 => seen_4096 = true,
                8192 => seen_8192 = true,
                _ => panic!("Unexpected null packet size"),
            }
        }
        assert!(seen_512 && seen_4096 && seen_8192);
    }

    #[test]
    fn test_null_packet_content() {
        let pkt = generate_null_packet(512);
        assert_eq!(pkt.len(), 512);
        assert!(pkt.iter().any(|&b| b != 0), "Null packet must be random, not zeros");
    }
}
