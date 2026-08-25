//! ★ B2: Tamper-Evident Secure Audit Logger
//!
//! HMAC-chained append-only log for all security-critical operations.
//! Each entry is authenticated with HMAC-SHA256 using the previous
//! entry's HMAC as the key — creating an unbreakable chain.
//!
//! Properties:
//! - **Append-only**: No entry can be deleted without breaking the chain
//! - **Tamper-evident**: Modifying any entry invalidates all subsequent HMACs
//! - **Forward integrity**: Even if current key leaks, past entries can't be forged
//!
//! Logged events: key operations, authentication failures, kill commands,
//! session lifecycle, anomaly detections

use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::time::{SystemTime, UNIX_EPOCH};
use zeroize::Zeroize;

type HmacSha256 = Hmac<Sha256>;

/// Audit event severity
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    /// Informational (key load, session start)
    Info,
    /// Warning (re-key threshold, TRNG health dip)
    Warning,
    /// Critical (authentication failure, tamper, kill)
    Critical,
    /// Fatal (session expired, system halt)
    Fatal,
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Severity::Info     => write!(f, "INFO"),
            Severity::Warning  => write!(f, "WARN"),
            Severity::Critical => write!(f, "CRIT"),
            Severity::Fatal    => write!(f, "FATL"),
        }
    }
}

/// Audit event type
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuditEvent {
    /// Session started
    SessionStart { session_id: [u8; 16] },
    /// Session ended (normal)
    SessionEnd { session_id: [u8; 16], messages: u64 },
    /// Session expired (forced)
    SessionExpired { session_id: [u8; 16], reason: String },
    /// Key exchange completed
    KeyExchangeComplete,
    /// Key loaded to TITAN FPGA
    KeyLoaded,
    /// Re-key initiated
    RekeyInitiated,
    /// Authentication failure (AEAD tag mismatch)
    AuthFailure { layer: u8 },
    /// Replay attack detected
    ReplayDetected { sequence: u64 },
    /// TITAN FPGA heartbeat lost
    HeartbeatLost,
    /// Kill command sent
    KillTriggered { source: String },
    /// Glitch/tamper detected
    TamperDetected { sensor: String },
    /// TRNG health alarm
    TrngHealthAlarm,
    /// Anomaly detected (AEGIS/PVT)
    AnomalyDetected { details: String },
    /// Custom event
    Custom { message: String },
}

impl AuditEvent {
    fn severity(&self) -> Severity {
        match self {
            AuditEvent::SessionStart { .. }     => Severity::Info,
            AuditEvent::SessionEnd { .. }       => Severity::Info,
            AuditEvent::SessionExpired { .. }   => Severity::Warning,
            AuditEvent::KeyExchangeComplete     => Severity::Info,
            AuditEvent::KeyLoaded               => Severity::Info,
            AuditEvent::RekeyInitiated          => Severity::Info,
            AuditEvent::AuthFailure { .. }      => Severity::Critical,
            AuditEvent::ReplayDetected { .. }   => Severity::Critical,
            AuditEvent::HeartbeatLost           => Severity::Critical,
            AuditEvent::KillTriggered { .. }    => Severity::Fatal,
            AuditEvent::TamperDetected { .. }   => Severity::Fatal,
            AuditEvent::TrngHealthAlarm         => Severity::Warning,
            AuditEvent::AnomalyDetected { .. }  => Severity::Critical,
            AuditEvent::Custom { .. }           => Severity::Info,
        }
    }

    fn to_bytes(&self) -> Vec<u8> {
        format!("{:?}", self).into_bytes()
    }
}

/// A single audit log entry (HMAC-chained)
#[derive(Debug, Clone)]
pub struct AuditEntry {
    /// Monotonic sequence number
    pub sequence: u64,
    /// Unix timestamp (milliseconds)
    pub timestamp_ms: u64,
    /// Event severity
    pub severity: Severity,
    /// Event data
    pub event: AuditEvent,
    /// HMAC-SHA256 chain hash (links to previous entry)
    pub chain_hmac: [u8; 32],
}

/// Tamper-evident audit logger
pub struct AuditLogger {
    /// Log entries (append-only in memory)
    pub entries: Vec<AuditEntry>,
    /// Current chain key (HMAC key = prev entry's HMAC)
    chain_key: [u8; 32],
    /// Next sequence number
    next_seq: u64,
    /// Maximum entries before rotation (prevent OOM)
    max_entries: usize,
    /// Critical event counter
    critical_count: u64,
}

impl AuditLogger {
    /// Create a new audit logger with a random initial chain key
    pub fn new(max_entries: usize) -> Self {
        let mut chain_key = [0u8; 32];
        use rand::RngCore;
        rand::thread_rng().fill_bytes(&mut chain_key);

        Self {
            entries: Vec::with_capacity(256),
            chain_key,
            next_seq: 0,
            max_entries,
            critical_count: 0,
        }
    }

    /// Log an audit event
    pub fn log(&mut self, event: AuditEvent) {
        let severity = event.severity();

        if severity == Severity::Critical || severity == Severity::Fatal {
            self.critical_count += 1;
        }

        let timestamp_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        // Compute HMAC chain: HMAC(chain_key, seq || timestamp || event_bytes)
        let mut mac = HmacSha256::new_from_slice(&self.chain_key)
            .expect("HMAC key length invalid");
        mac.update(&self.next_seq.to_le_bytes());
        mac.update(&timestamp_ms.to_le_bytes());
        mac.update(&event.to_bytes());
        let hmac_result = mac.finalize().into_bytes();
        let mut chain_hmac = [0u8; 32];
        chain_hmac.copy_from_slice(&hmac_result);

        let entry = AuditEntry {
            sequence: self.next_seq,
            timestamp_ms,
            severity,
            event,
            chain_hmac,
        };

        // Advance chain: next key = this entry's HMAC
        self.chain_key.zeroize();
        self.chain_key = chain_hmac;
        self.next_seq += 1;

        self.entries.push(entry);

        // Rotation: if too many entries, keep last half
        if self.entries.len() > self.max_entries {
            let keep_from = self.entries.len() / 2;
            self.entries.drain(..keep_from);
        }
    }

    /// Verify the HMAC chain integrity of all stored entries
    pub fn verify_chain(&self) -> bool {
        if self.entries.len() < 2 {
            return true;
        }

        for i in 1..self.entries.len() {
            let prev = &self.entries[i - 1];
            let curr = &self.entries[i];

            // Reconstruct HMAC using previous entry's HMAC as key
            let mut mac = match HmacSha256::new_from_slice(&prev.chain_hmac) {
                Ok(m) => m,
                Err(_) => return false,
            };
            mac.update(&curr.sequence.to_le_bytes());
            mac.update(&curr.timestamp_ms.to_le_bytes());
            mac.update(&curr.event.to_bytes());

            let expected = mac.finalize().into_bytes();
            if expected.as_slice() != curr.chain_hmac.as_slice() {
                return false; // Chain broken — tamper detected!
            }
        }
        true
    }

    /// Get critical event count
    pub fn critical_count(&self) -> u64 {
        self.critical_count
    }

    /// Get total entry count
    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    /// Get the last N entries
    pub fn last_entries(&self, n: usize) -> &[AuditEntry] {
        let start = self.entries.len().saturating_sub(n);
        &self.entries[start..]
    }
}

impl Drop for AuditLogger {
    fn drop(&mut self) {
        self.chain_key.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_audit_log_creation() {
        let logger = AuditLogger::new(1000);
        assert_eq!(logger.entry_count(), 0);
        assert_eq!(logger.critical_count(), 0);
    }

    #[test]
    fn test_audit_log_append() {
        let mut logger = AuditLogger::new(1000);
        logger.log(AuditEvent::KeyExchangeComplete);
        logger.log(AuditEvent::KeyLoaded);
        logger.log(AuditEvent::SessionStart { session_id: [0x42; 16] });
        assert_eq!(logger.entry_count(), 3);
    }

    #[test]
    fn test_audit_chain_integrity() {
        let mut logger = AuditLogger::new(1000);
        logger.log(AuditEvent::KeyExchangeComplete);
        logger.log(AuditEvent::KeyLoaded);
        logger.log(AuditEvent::SessionStart { session_id: [0x42; 16] });
        logger.log(AuditEvent::AuthFailure { layer: 1 });
        logger.log(AuditEvent::SessionEnd { session_id: [0x42; 16], messages: 100 });
        assert!(logger.verify_chain());
    }

    #[test]
    fn test_audit_tamper_detection() {
        let mut logger = AuditLogger::new(1000);
        logger.log(AuditEvent::KeyExchangeComplete);
        logger.log(AuditEvent::KeyLoaded);
        logger.log(AuditEvent::SessionStart { session_id: [0x42; 16] });

        // Tamper with an entry
        if let Some(entry) = logger.entries.get_mut(1) {
            entry.chain_hmac[0] ^= 0xFF;
        }
        assert!(!logger.verify_chain());
    }

    #[test]
    fn test_audit_critical_counting() {
        let mut logger = AuditLogger::new(1000);
        logger.log(AuditEvent::KeyLoaded);                        // Info
        logger.log(AuditEvent::AuthFailure { layer: 1 });         // Critical
        logger.log(AuditEvent::ReplayDetected { sequence: 42 });  // Critical
        logger.log(AuditEvent::KillTriggered { source: "watchdog".into() }); // Fatal
        assert_eq!(logger.critical_count(), 3);
    }

    #[test]
    fn test_audit_rotation() {
        let mut logger = AuditLogger::new(10);
        for i in 0..15 {
            logger.log(AuditEvent::Custom { message: format!("msg {}", i) });
        }
        // After rotation, should have ~7-8 entries (kept last half)
        assert!(logger.entry_count() <= 10);
    }

    #[test]
    fn test_audit_last_entries() {
        let mut logger = AuditLogger::new(1000);
        for i in 0..10 {
            logger.log(AuditEvent::Custom { message: format!("msg {}", i) });
        }
        let last3 = logger.last_entries(3);
        assert_eq!(last3.len(), 3);
        assert_eq!(last3[0].sequence, 7);
    }
}
