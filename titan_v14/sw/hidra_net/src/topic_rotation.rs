//! ★ P2 #25: MQTT Topic Rotation — Traffic Correlation Resistance
//!
//! HKDF(seed, counter) ile periyodik MQTT topic hash üretir.
//! Gözlemci aynı topic'e giden mesajları korelasyon yapamaz.
//!
//! Rotation tetikleyicileri:
//!   - Zaman: her 1 saat
//!   - Mesaj sayısı: her 100 mesaj
//!   - Manuel: operatör isteği
//!
//! Topic format: /t/{hex(hash[0..8])} (16 karakter hex)

use sha2::{Sha256, Digest};
use std::time::{Duration, Instant};

/// Topic rotation configuration
#[derive(Debug, Clone)]
pub struct TopicRotationConfig {
    /// Per-device seed (from device_provision)
    pub seed: [u8; 32],
    /// Maximum messages before rotation
    pub max_messages: u32,
    /// Maximum duration before rotation
    pub max_duration: Duration,
}

impl Default for TopicRotationConfig {
    fn default() -> Self {
        Self {
            seed: [0u8; 32],
            max_messages: 100,
            max_duration: Duration::from_secs(3600), // 1 hour
        }
    }
}

/// Topic rotation state
pub struct TopicRotator {
    config: TopicRotationConfig,
    /// Current rotation counter (monotonic)
    counter: u64,
    /// Messages sent on current topic
    msg_count: u32,
    /// When current topic was activated
    topic_start: Instant,
    /// Current topic string
    current_topic: String,
}

impl TopicRotator {
    /// Create a new topic rotator
    pub fn new(config: TopicRotationConfig) -> Self {
        let mut rotator = Self {
            config,
            counter: 0,
            msg_count: 0,
            topic_start: Instant::now(),
            current_topic: String::new(),
        };
        rotator.rotate();
        rotator
    }

    /// Derive topic hash from seed + counter
    fn derive_topic(seed: &[u8; 32], counter: u64) -> String {
        let mut hasher = Sha256::new();
        hasher.update(b"TITAN-TOPIC-V1");
        hasher.update(seed);
        hasher.update(counter.to_be_bytes());
        let hash = hasher.finalize();

        // Take first 8 bytes → 16 hex chars
        let topic_hash: String = hash[..8]
            .iter()
            .map(|b| format!("{:02x}", b))
            .collect();

        format!("/t/{}", topic_hash)
    }

    /// Force rotation to next topic
    pub fn rotate(&mut self) {
        self.counter += 1;
        self.msg_count = 0;
        self.topic_start = Instant::now();
        self.current_topic = Self::derive_topic(&self.config.seed, self.counter);
    }

    /// Check if rotation is needed and rotate if so.
    /// Returns true if topic changed.
    pub fn check_and_rotate(&mut self) -> bool {
        let should_rotate = self.msg_count >= self.config.max_messages
            || self.topic_start.elapsed() >= self.config.max_duration;

        if should_rotate {
            self.rotate();
            true
        } else {
            false
        }
    }

    /// Record a message sent on current topic
    pub fn record_message(&mut self) {
        self.msg_count += 1;
    }

    /// Get current MQTT topic
    pub fn current_topic(&self) -> &str {
        &self.current_topic
    }

    /// Get current rotation counter
    pub fn counter(&self) -> u64 {
        self.counter
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_topic_derivation_deterministic() {
        let seed = [0x42u8; 32];
        let t1 = TopicRotator::derive_topic(&seed, 1);
        let t2 = TopicRotator::derive_topic(&seed, 1);
        assert_eq!(t1, t2);
    }

    #[test]
    fn test_topic_changes_with_counter() {
        let seed = [0x42u8; 32];
        let t1 = TopicRotator::derive_topic(&seed, 1);
        let t2 = TopicRotator::derive_topic(&seed, 2);
        assert_ne!(t1, t2);
    }

    #[test]
    fn test_topic_format() {
        let seed = [0x42u8; 32];
        let topic = TopicRotator::derive_topic(&seed, 1);
        assert!(topic.starts_with("/t/"));
        assert_eq!(topic.len(), 3 + 16); // /t/ + 16 hex chars
    }

    #[test]
    fn test_message_count_rotation() {
        let config = TopicRotationConfig {
            max_messages: 3,
            ..Default::default()
        };
        let mut rotator = TopicRotator::new(config);
        let initial_topic = rotator.current_topic().to_string();

        rotator.record_message();
        rotator.record_message();
        assert!(!rotator.check_and_rotate());

        rotator.record_message();
        assert!(rotator.check_and_rotate());
        assert_ne!(rotator.current_topic(), initial_topic);
    }
}
