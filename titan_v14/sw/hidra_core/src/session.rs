//! ★ B1: Session Expiration + Automatic Re-Key Guard
//!
//! Security property: No session lives forever.
//! - Max message count per session (prevents u32 counter wrap in ratchet)
//! - Max session duration (prevents long-lived key compromise)
//! - Automatic re-key trigger (forces new key exchange)
//!
//! NIST SP 800-57 Rev.5 §5.3: Cryptoperiod enforcement

use std::time::{Duration, Instant};
use crate::HidraError;
use zeroize::ZeroizeOnDrop;

/// Session configuration
#[derive(Debug, Clone)]
pub struct SessionConfig {
    /// Maximum messages before forced re-key
    pub max_messages: u64,
    /// Maximum session duration before forced re-key
    pub max_duration: Duration,
    /// Warning threshold (% of max before triggering soft re-key)
    pub warning_threshold: f64,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            max_messages: 100_000,           // 100K messages max
            max_duration: Duration::from_secs(86_400), // 24 hours
            warning_threshold: 0.8,          // Warn at 80%
        }
    }
}

/// Session state — tracks usage and enforces cryptoperiod
#[derive(ZeroizeOnDrop)]
pub struct SessionGuard {
    /// Session start time (not zeroizable, but safe)
    #[zeroize(skip)]
    started_at: Instant,
    /// Messages sent in this session
    #[zeroize(skip)]
    messages_sent: u64,
    /// Messages received in this session
    #[zeroize(skip)]
    messages_received: u64,
    /// Session ID (random, for audit logging)
    session_id: [u8; 16],
    /// Configuration
    #[zeroize(skip)]
    config: SessionConfig,
    /// Whether re-key has been requested
    #[zeroize(skip)]
    rekey_requested: bool,
    /// Whether session is still valid
    #[zeroize(skip)]
    valid: bool,
}

impl SessionGuard {
    /// Create a new session guard
    pub fn new(config: SessionConfig) -> Self {
        let mut session_id = [0u8; 16];
        use rand::RngCore;
        rand::thread_rng().fill_bytes(&mut session_id);

        Self {
            started_at: Instant::now(),
            messages_sent: 0,
            messages_received: 0,
            session_id,
            config,
            rekey_requested: false,
            valid: true,
        }
    }

    /// Check if session is still valid. Returns error if expired.
    pub fn validate(&self) -> Result<SessionStatus, HidraError> {
        if !self.valid {
            return Err(HidraError::SessionExpired {
                reason: "Session invalidated".to_string(),
            });
        }

        let elapsed = self.started_at.elapsed();
        let total_messages = self.messages_sent + self.messages_received;

        // Hard limit: session expired
        if total_messages >= self.config.max_messages {
            return Err(HidraError::SessionExpired {
                reason: format!(
                    "Message limit reached: {}/{}",
                    total_messages, self.config.max_messages
                ),
            });
        }

        if elapsed >= self.config.max_duration {
            return Err(HidraError::SessionExpired {
                reason: format!(
                    "Duration limit reached: {:?}/{:?}",
                    elapsed, self.config.max_duration
                ),
            });
        }

        // Soft limit: approaching threshold — suggest re-key
        let msg_ratio = total_messages as f64 / self.config.max_messages as f64;
        let time_ratio = elapsed.as_secs_f64() / self.config.max_duration.as_secs_f64();

        if msg_ratio >= self.config.warning_threshold
            || time_ratio >= self.config.warning_threshold
        {
            return Ok(SessionStatus::RekeyRecommended {
                messages_remaining: self.config.max_messages - total_messages,
                time_remaining: self.config.max_duration.saturating_sub(elapsed),
            });
        }

        Ok(SessionStatus::Active {
            messages_total: total_messages,
            elapsed,
        })
    }

    /// Record a sent message. Returns error if session expired.
    pub fn record_send(&mut self) -> Result<(), HidraError> {
        self.validate()?;
        self.messages_sent += 1;
        Ok(())
    }

    /// Record a received message. Returns error if session expired.
    pub fn record_receive(&mut self) -> Result<(), HidraError> {
        self.validate()?;
        self.messages_received += 1;
        Ok(())
    }

    /// Explicitly invalidate the session (e.g., on re-key)
    pub fn invalidate(&mut self) {
        self.valid = false;
    }

    /// Get session ID for audit logging
    pub fn session_id(&self) -> &[u8; 16] {
        &self.session_id
    }

    /// Get total message count
    pub fn total_messages(&self) -> u64 {
        self.messages_sent + self.messages_received
    }

    /// Get session age
    pub fn age(&self) -> Duration {
        self.started_at.elapsed()
    }
}

/// Session status
#[derive(Debug)]
pub enum SessionStatus {
    /// Session is active and healthy
    Active {
        messages_total: u64,
        elapsed: Duration,
    },
    /// Session is approaching limits — re-key recommended
    RekeyRecommended {
        messages_remaining: u64,
        time_remaining: Duration,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_creation() {
        let guard = SessionGuard::new(SessionConfig::default());
        assert!(guard.valid);
        assert_eq!(guard.total_messages(), 0);
    }

    #[test]
    fn test_session_message_tracking() {
        let mut guard = SessionGuard::new(SessionConfig::default());
        guard.record_send().unwrap();
        guard.record_send().unwrap();
        guard.record_receive().unwrap();
        assert_eq!(guard.total_messages(), 3);
    }

    #[test]
    fn test_session_message_limit() {
        let config = SessionConfig {
            max_messages: 5,
            ..Default::default()
        };
        let mut guard = SessionGuard::new(config);
        for _ in 0..5 {
            guard.record_send().unwrap();
        }
        // 6th message should fail
        assert!(guard.record_send().is_err());
    }

    #[test]
    fn test_session_invalidation() {
        let mut guard = SessionGuard::new(SessionConfig::default());
        guard.invalidate();
        assert!(guard.record_send().is_err());
    }

    #[test]
    fn test_session_rekey_warning() {
        let config = SessionConfig {
            max_messages: 10,
            warning_threshold: 0.8,
            ..Default::default()
        };
        let mut guard = SessionGuard::new(config);
        for _ in 0..8 {
            guard.record_send().unwrap();
        }
        match guard.validate().unwrap() {
            SessionStatus::RekeyRecommended { .. } => {},
            _ => panic!("Expected RekeyRecommended"),
        }
    }

    #[test]
    fn test_session_id_unique() {
        let g1 = SessionGuard::new(SessionConfig::default());
        let g2 = SessionGuard::new(SessionConfig::default());
        assert_ne!(g1.session_id(), g2.session_id());
    }
}
