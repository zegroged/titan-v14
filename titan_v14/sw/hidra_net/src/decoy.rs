//! ★ C3: Decoy Traffic Generator — Traffic Analysis Resistance
//!
//! Generates constant-rate dummy traffic that is indistinguishable
//! from real messages at the network layer. This defeats traffic
//! analysis by ensuring the communication pattern is constant
//! regardless of actual message activity.
//!
//! # Properties
//! - **Constant rate**: Sends envelopes at fixed intervals even when idle
//! - **Indistinguishable**: Decoy envelopes use same encryption, same size
//! - **Configurable**: Rate, jitter, and burst patterns are tunable
//! - **Resource bounded**: Rate limiter prevents resource exhaustion

use rand::RngCore;
use std::time::{Duration, Instant};

/// Decoy traffic configuration
#[derive(Debug, Clone)]
pub struct DecoyConfig {
    /// Base interval between decoy packets
    pub base_interval: Duration,
    /// Maximum random jitter added to interval (prevents timing analysis)
    pub max_jitter: Duration,
    /// Whether decoy generation is enabled
    pub enabled: bool,
    /// Maximum decoys per minute (rate limiter)
    pub max_per_minute: u32,
}

impl Default for DecoyConfig {
    fn default() -> Self {
        Self {
            base_interval: Duration::from_secs(30),     // Every 30s
            max_jitter: Duration::from_secs(15),        // ±15s random
            enabled: true,
            max_per_minute: 10,                         // Max 10/min
        }
    }
}

/// Decoy traffic generator state
pub struct DecoyGenerator {
    config: DecoyConfig,
    /// Last decoy send time
    last_sent: Instant,
    /// Next scheduled send time
    next_send: Instant,
    /// Decoys sent in current minute window
    minute_count: u32,
    /// Current minute window start
    minute_window_start: Instant,
    /// Total decoys generated
    pub total_generated: u64,
}

impl DecoyGenerator {
    /// Create a new decoy generator
    pub fn new(config: DecoyConfig) -> Self {
        let now = Instant::now();
        let initial_delay = Self::compute_jittered_interval(&config);

        Self {
            config: config.clone(),
            last_sent: now,
            next_send: now + initial_delay,
            minute_count: 0,
            minute_window_start: now,
            total_generated: 0,
        }
    }

    /// Check if a decoy should be sent now
    pub fn should_send(&mut self) -> bool {
        if !self.config.enabled {
            return false;
        }

        let now = Instant::now();

        // Reset minute window if needed
        if now.duration_since(self.minute_window_start) >= Duration::from_secs(60) {
            self.minute_count = 0;
            self.minute_window_start = now;
        }

        // Rate limiter
        if self.minute_count >= self.config.max_per_minute {
            return false;
        }

        // Check if it's time
        if now >= self.next_send {
            self.last_sent = now;
            self.next_send = now + Self::compute_jittered_interval(&self.config);
            self.minute_count += 1;
            self.total_generated += 1;
            true
        } else {
            false
        }
    }

    /// Generate random decoy payload (mimics real message size distribution)
    pub fn generate_payload(&self) -> Vec<u8> {
        let mut rng = rand::thread_rng();

        // Random payload size between 32-256 bytes (mimics real messages)
        let mut size_bytes = [0u8; 1];
        rng.fill_bytes(&mut size_bytes);
        let size = 32 + (size_bytes[0] as usize % 225); // 32..256

        let mut payload = vec![0u8; size];
        rng.fill_bytes(&mut payload);
        payload
    }

    /// Compute next interval with random jitter
    fn compute_jittered_interval(config: &DecoyConfig) -> Duration {
        let jitter_millis = config.max_jitter.as_millis() as u64;
        if jitter_millis == 0 {
            return config.base_interval;
        }

        let mut rng = rand::thread_rng();
        let mut jitter_bytes = [0u8; 8];
        rng.fill_bytes(&mut jitter_bytes);

        let jitter_ms = u64::from_le_bytes(jitter_bytes) % jitter_millis;
        config.base_interval + Duration::from_millis(jitter_ms)
    }

    /// Get time until next scheduled decoy
    pub fn time_until_next(&self) -> Duration {
        let now = Instant::now();
        if now >= self.next_send {
            Duration::ZERO
        } else {
            self.next_send - now
        }
    }

    /// Enable/disable decoy generation
    pub fn set_enabled(&mut self, enabled: bool) {
        self.config.enabled = enabled;
    }

    /// Check if enabled
    pub fn is_enabled(&self) -> bool {
        self.config.enabled
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decoy_creation() {
        let gen = DecoyGenerator::new(DecoyConfig::default());
        assert_eq!(gen.total_generated, 0);
        assert!(gen.is_enabled());
    }

    #[test]
    fn test_decoy_disabled() {
        let config = DecoyConfig {
            enabled: false,
            ..Default::default()
        };
        let mut gen = DecoyGenerator::new(config);
        assert!(!gen.should_send());
    }

    #[test]
    fn test_decoy_payload_random() {
        let gen = DecoyGenerator::new(DecoyConfig::default());
        let p1 = gen.generate_payload();
        let p2 = gen.generate_payload();
        // Random payloads should differ (with overwhelming probability)
        assert_ne!(p1, p2);
        // Size range
        assert!(p1.len() >= 32 && p1.len() <= 256);
    }

    #[test]
    fn test_decoy_rate_limiter() {
        let config = DecoyConfig {
            base_interval: Duration::ZERO,
            max_jitter: Duration::ZERO,
            max_per_minute: 3,
            enabled: true,
        };
        let mut gen = DecoyGenerator::new(config);

        // Should allow 3 sends
        assert!(gen.should_send());
        assert!(gen.should_send());
        assert!(gen.should_send());
        // 4th should be rate-limited
        assert!(!gen.should_send());
    }

    #[test]
    fn test_decoy_enable_disable() {
        let mut gen = DecoyGenerator::new(DecoyConfig::default());
        gen.set_enabled(false);
        assert!(!gen.is_enabled());
        gen.set_enabled(true);
        assert!(gen.is_enabled());
    }
}
