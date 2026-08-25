//! ★ P2 #40: Tor Timing Jitter — Circuit Correlation Resistance
//!
//! MQTT publish zamanlarına ±5s rastgele gecikme ekler.
//! Tor circuit correlation saldırısını engeller.
//!
//! Gözlemci "mesaj X giriyor, Y çıkıyor" korelasyonu yapamaz
//! çünkü çıkış zamanı öngörülemez.

use rand::RngCore;
use std::time::Duration;

/// Jitter configuration
#[derive(Debug, Clone)]
pub struct TorJitterConfig {
    /// Maximum jitter in milliseconds (default: ±5000ms)
    pub max_jitter_ms: u64,
    /// Minimum jitter (prevent zero-delay leakage)
    pub min_jitter_ms: u64,
    /// Whether jitter is enabled
    pub enabled: bool,
}

impl Default for TorJitterConfig {
    fn default() -> Self {
        Self {
            max_jitter_ms: 5000,
            min_jitter_ms: 500,
            enabled: true,
        }
    }
}

/// Compute a random delay for message transmission
pub fn compute_jitter(config: &TorJitterConfig) -> Duration {
    if !config.enabled {
        return Duration::ZERO;
    }

    let mut rng = rand::thread_rng();
    let mut bytes = [0u8; 8];
    rng.fill_bytes(&mut bytes);

    let range = config.max_jitter_ms - config.min_jitter_ms;
    let jitter = config.min_jitter_ms + (u64::from_le_bytes(bytes) % range);
    Duration::from_millis(jitter)
}

/// Schedule a message with jitter applied
pub struct JitteredSend {
    /// Original message payload
    pub payload: Vec<u8>,
    /// Computed delay before sending
    pub delay: Duration,
}

impl JitteredSend {
    pub fn new(payload: Vec<u8>, config: &TorJitterConfig) -> Self {
        Self {
            delay: compute_jitter(config),
            payload,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_jitter_within_bounds() {
        let config = TorJitterConfig::default();
        for _ in 0..100 {
            let jitter = compute_jitter(&config);
            assert!(jitter >= Duration::from_millis(config.min_jitter_ms));
            assert!(jitter < Duration::from_millis(config.max_jitter_ms));
        }
    }

    #[test]
    fn test_jitter_disabled() {
        let config = TorJitterConfig {
            enabled: false,
            ..Default::default()
        };
        let jitter = compute_jitter(&config);
        assert_eq!(jitter, Duration::ZERO);
    }

    #[test]
    fn test_jittered_send() {
        let config = TorJitterConfig::default();
        let send = JitteredSend::new(vec![1, 2, 3], &config);
        assert_eq!(send.payload, vec![1, 2, 3]);
        assert!(send.delay >= Duration::from_millis(500));
    }
}
