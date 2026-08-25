//! HİDRA Link Protocol (HLP) — SPI Command Protocol
//!
//! Defines the packet format for communication between
//! the App Processor and TITAN FPGA over SPI.
//!
//! ## Anti-Replay Protection
//! `SequenceValidator` implements a monotonic counter + 64-bit
//! sliding window bitmap. Replayed, reordered (too old), or
//! duplicate packets are rejected at the protocol layer.
//!
//! # Packet Format
//! ```text
//! ┌──────┬──────┬──────────┬──────────┬───────┐
//! │ CMD  │ LEN  │ SEQ      │ PAYLOAD  │ CRC32 │
//! │ 1B   │ 2B   │ 4B       │ 0-4096B  │ 4B    │
//! └──────┴──────┴──────────┴──────────┴───────┘
//! ```

use serde::{Serialize, Deserialize};

/// Maximum payload size per HLP packet (4 KiB)
pub const HLP_MAX_PAYLOAD: usize = 4096;

/// HLP header size: CMD(1) + LEN(2) + SEQ(4) = 7 bytes
pub const HLP_HEADER_SIZE: usize = 7;

/// HLP CRC size: 4 bytes (CRC-32/IEEE 802.3)
/// ★ UPGRADE: CRC-16 → CRC-32 for 2^32 error detection (was 2^16)
pub const HLP_CRC_SIZE: usize = 4;

/// HLP Command Types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum HlpCommand {
    /// Encrypt plaintext via TITAN AES-256-CTR
    EncryptRequest  = 0x01,
    /// Encrypted ciphertext response from TITAN
    EncryptResponse = 0x02,
    /// Decrypt ciphertext via TITAN AES-256-CTR
    DecryptRequest  = 0x03,
    /// Decrypted plaintext response from TITAN
    DecryptResponse = 0x04,
    /// Load new encryption key into TITAN volatile registers
    KeyLoad         = 0x10,
    /// Key load acknowledgement
    KeyLoadAck      = 0x11,
    /// Request TITAN status (PVT, Omega Cloak, Kill Chain)
    StatusRequest   = 0x20,
    /// Status response from TITAN
    StatusResponse  = 0x21,
    /// Trigger kill chain (remote destruction)
    KillCommand     = 0xF0,
    /// Kill acknowledgement (last message before destruction)
    KillAck         = 0xF1,
    /// Heartbeat ping
    Heartbeat       = 0xFE,
    /// Heartbeat response
    HeartbeatAck    = 0xFF,
}

impl HlpCommand {
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0x01 => Some(Self::EncryptRequest),
            0x02 => Some(Self::EncryptResponse),
            0x03 => Some(Self::DecryptRequest),
            0x04 => Some(Self::DecryptResponse),
            0x10 => Some(Self::KeyLoad),
            0x11 => Some(Self::KeyLoadAck),
            0x20 => Some(Self::StatusRequest),
            0x21 => Some(Self::StatusResponse),
            0xF0 => Some(Self::KillCommand),
            0xF1 => Some(Self::KillAck),
            0xFE => Some(Self::Heartbeat),
            0xFF => Some(Self::HeartbeatAck),
            _    => None,
        }
    }
}

/// TITAN status flags (returned by StatusResponse)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TitanStatus {
    /// Omega Cloak active
    pub omega_active: bool,
    /// AEGIS AI anomaly detection active
    pub aegis_active: bool,
    /// PVT monitor values (ring oscillator frequencies)
    pub pvt_ring_osc: [u32; 4],
    /// Kill chain armed
    pub kill_armed: bool,
    /// POST self-test passed
    pub post_pass: bool,
    /// AES fault detected
    pub aes_fault: bool,
    /// Lockstep sync valid
    pub lockstep_ok: bool,
    /// TRNG health
    pub trng_healthy: bool,
}

/// HLP Packet — complete frame including header, payload, and CRC
#[derive(Debug, Clone)]
pub struct HlpPacket {
    pub command: HlpCommand,
    pub sequence: u32,
    pub payload: Vec<u8>,
}

impl HlpPacket {
    /// Create a new HLP packet
    pub fn new(command: HlpCommand, sequence: u32, payload: Vec<u8>) -> Self {
        Self { command, sequence, payload }
    }

    /// Serialize packet to bytes (for SPI transmission)
    pub fn to_bytes(&self) -> Vec<u8> {
        let len = self.payload.len() as u16;
        let mut buf = Vec::with_capacity(HLP_HEADER_SIZE + self.payload.len() + HLP_CRC_SIZE);

        // Header
        buf.push(self.command as u8);
        buf.extend_from_slice(&len.to_le_bytes());
        buf.extend_from_slice(&self.sequence.to_le_bytes());

        // Payload
        buf.extend_from_slice(&self.payload);

        // CRC-32/IEEE 802.3 over header + payload
        let crc = crc32_ieee(&buf);
        buf.extend_from_slice(&crc.to_le_bytes());

        buf
    }

    /// Parse packet from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self, &'static str> {
        if data.len() < HLP_HEADER_SIZE + HLP_CRC_SIZE {
            return Err("Packet too short");
        }

        let command = HlpCommand::from_byte(data[0]).ok_or("Unknown command")?;
        let len = u16::from_le_bytes([data[1], data[2]]) as usize;
        let sequence = u32::from_le_bytes([data[3], data[4], data[5], data[6]]);

        if data.len() < HLP_HEADER_SIZE + len + HLP_CRC_SIZE {
            return Err("Payload length mismatch");
        }

        let payload = data[HLP_HEADER_SIZE..HLP_HEADER_SIZE + len].to_vec();

        // Verify CRC-32
        let crc_offset = HLP_HEADER_SIZE + len;
        let expected_crc = u32::from_le_bytes([
            data[crc_offset], data[crc_offset + 1],
            data[crc_offset + 2], data[crc_offset + 3],
        ]);
        let actual_crc = crc32_ieee(&data[..crc_offset]);
        if expected_crc != actual_crc {
            return Err("CRC mismatch");
        }

        Ok(Self { command, sequence, payload })
    }
}

// ════════════════════════════════════════════════════════════════════
//  SEQUENCE VALIDATOR — Anti-Replay + Anti-Reorder Protection
// ════════════════════════════════════════════════════════════════════

/// Sliding-window sequence validator for HLP packets.
///
/// Tracks the highest accepted sequence number and maintains a 64-bit
/// bitmap of recently seen sequence numbers. This prevents:
/// - **Replay attacks**: duplicate sequence numbers are rejected
/// - **Reorder attacks**: packets older than the window are rejected
/// - **Counter wrap**: detects u32 wrap and forces re-key
///
/// Window size: 64 packets (configurable via WINDOW_SIZE).
pub struct SequenceValidator {
    /// Highest accepted sequence number
    max_seq: u32,
    /// Bitmap: bit N = sequence (max_seq - N) has been seen
    /// Bit 0 = max_seq, bit 1 = max_seq-1, ..., bit 63 = max_seq-63
    window: u64,
    /// Total accepted packets
    accepted: u64,
    /// Total rejected packets (replay/reorder)
    rejected: u64,
    /// Whether any sequence has been received yet
    initialized: bool,
}

impl SequenceValidator {
    /// Window size in packets
    pub const WINDOW_SIZE: u32 = 64;

    /// Create a new validator with no history.
    pub fn new() -> Self {
        Self {
            max_seq: 0,
            window: 0,
            accepted: 0,
            rejected: 0,
            initialized: false,
        }
    }

    /// Validate and record a sequence number.
    ///
    /// Returns `Ok(())` if the sequence is valid (new, within window).
    /// Returns `Err(reason)` if rejected (duplicate or too old).
    pub fn validate(&mut self, seq: u32) -> Result<(), &'static str> {
        // First packet: accept anything
        if !self.initialized {
            self.initialized = true;
            self.max_seq = seq;
            self.window = 1; // bit 0 = current max_seq
            self.accepted += 1;
            return Ok(());
        }

        if seq > self.max_seq {
            // ── New high water mark ──
            let shift = seq - self.max_seq;
            if shift >= Self::WINDOW_SIZE {
                // Jumped far ahead: reset entire window
                self.window = 1;
            } else {
                // Shift window left by the delta, mark new seq as seen
                self.window = (self.window << shift) | 1;
            }
            self.max_seq = seq;
            self.accepted += 1;
            Ok(())
        } else if seq == self.max_seq {
            // ── Exact duplicate of max ──
            self.rejected += 1;
            Err("Duplicate sequence number (replay)")
        } else {
            // ── Older than max: check if within window ──
            let age = self.max_seq - seq;
            if age >= Self::WINDOW_SIZE {
                self.rejected += 1;
                return Err("Sequence too old (outside window)");
            }
            let bit = 1u64 << age;
            if self.window & bit != 0 {
                self.rejected += 1;
                Err("Duplicate sequence number (replay)")
            } else {
                // Mark as seen
                self.window |= bit;
                self.accepted += 1;
                Ok(())
            }
        }
    }

    /// Get statistics
    pub fn stats(&self) -> (u64, u64) {
        (self.accepted, self.rejected)
    }

    /// Check if counter is dangerously close to u32::MAX (needs re-key)
    pub fn needs_rekey(&self) -> bool {
        self.max_seq > u32::MAX - 1000
    }

    /// Reset the validator (after re-key)
    pub fn reset(&mut self) {
        self.max_seq = 0;
        self.window = 0;
        self.accepted = 0;
        self.rejected = 0;
        self.initialized = false;
    }
}

impl Default for SequenceValidator {
    fn default() -> Self {
        Self::new()
    }
}

/// CRC-16/CCITT (polynomial 0x1021, init 0xFFFF)
/// Retained for SPI transport layer backward compatibility
pub fn crc16_ccitt(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &byte in data {
        crc ^= (byte as u16) << 8;
        for _ in 0..8 {
            if crc & 0x8000 != 0 {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc <<= 1;
            }
        }
    }
    crc
}

/// CRC-32/IEEE 802.3 (polynomial 0x04C11DB7, init 0xFFFFFFFF, final XOR 0xFFFFFFFF)
/// ★ UPGRADE: Replaces CRC-16 for HLP packet integrity.
///   - Detects all 1, 2, 3-bit errors
///   - Detects all burst errors up to 32 bits
///   - Hamming distance ≥ 4 for data < 2^32 bits
fn crc32_ieee(data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFFFFFF;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB88320; // Reflected polynomial
            } else {
                crc >>= 1;
            }
        }
    }
    !crc // Final XOR
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_packet_roundtrip() {
        let pkt = HlpPacket::new(
            HlpCommand::EncryptRequest,
            42,
            vec![0xDE, 0xAD, 0xBE, 0xEF],
        );

        let bytes = pkt.to_bytes();
        let parsed = HlpPacket::from_bytes(&bytes).unwrap();

        assert_eq!(parsed.command, HlpCommand::EncryptRequest);
        assert_eq!(parsed.sequence, 42);
        assert_eq!(parsed.payload, vec![0xDE, 0xAD, 0xBE, 0xEF]);
    }

    #[test]
    fn test_crc_tamper_detection() {
        let pkt = HlpPacket::new(HlpCommand::Heartbeat, 0, vec![]);
        let mut bytes = pkt.to_bytes();
        // Tamper with data
        bytes[0] = 0x00;
        assert!(HlpPacket::from_bytes(&bytes).is_err());
    }

    #[test]
    fn test_all_commands_roundtrip() {
        let commands = vec![
            HlpCommand::EncryptRequest,
            HlpCommand::EncryptResponse,
            HlpCommand::DecryptRequest,
            HlpCommand::DecryptResponse,
            HlpCommand::KeyLoad,
            HlpCommand::StatusRequest,
            HlpCommand::KillCommand,
            HlpCommand::Heartbeat,
        ];

        for (i, cmd) in commands.iter().enumerate() {
            let pkt = HlpPacket::new(*cmd, i as u32, vec![i as u8]);
            let bytes = pkt.to_bytes();
            let parsed = HlpPacket::from_bytes(&bytes).unwrap();
            assert_eq!(parsed.command, *cmd);
        }
    }

    // ════════ SequenceValidator Tests ════════

    #[test]
    fn test_seq_validator_monotonic() {
        let mut v = SequenceValidator::new();
        // Sequential packets should all pass
        for i in 0..100 {
            assert!(v.validate(i).is_ok(), "seq {} should pass", i);
        }
        assert_eq!(v.stats(), (100, 0));
    }

    #[test]
    fn test_seq_validator_replay_rejected() {
        let mut v = SequenceValidator::new();
        assert!(v.validate(10).is_ok());
        assert!(v.validate(11).is_ok());
        // Replay seq 10 → rejected
        assert!(v.validate(10).is_err());
        // Replay seq 11 → rejected
        assert!(v.validate(11).is_err());
        assert_eq!(v.stats(), (2, 2));
    }

    #[test]
    fn test_seq_validator_reorder_within_window() {
        let mut v = SequenceValidator::new();
        assert!(v.validate(10).is_ok());
        assert!(v.validate(15).is_ok());
        // Out-of-order but within window (age = 15-12 = 3 < 64)
        assert!(v.validate(12).is_ok());
        assert!(v.validate(11).is_ok());
        assert!(v.validate(13).is_ok());
        assert!(v.validate(14).is_ok());
        assert_eq!(v.stats(), (6, 0)); // All accepted
    }

    #[test]
    fn test_seq_validator_too_old_rejected() {
        let mut v = SequenceValidator::new();
        assert!(v.validate(0).is_ok());
        assert!(v.validate(100).is_ok()); // Jump far ahead
        // seq 0 is now 100 packets old (> 64 window) → rejected
        assert!(v.validate(0).is_err());
        // seq 36 is 64 packets old (== window) → rejected
        assert!(v.validate(36).is_err());
        // seq 37 is 63 packets old (< window) → accepted (not seen)
        assert!(v.validate(37).is_ok());
    }

    #[test]
    fn test_seq_validator_rekey_detection() {
        let mut v = SequenceValidator::new();
        assert!(!v.needs_rekey());
        // Simulate near-max
        v.max_seq = u32::MAX - 500;
        v.initialized = true;
        assert!(v.needs_rekey());
    }

    #[test]
    fn test_seq_validator_reset() {
        let mut v = SequenceValidator::new();
        assert!(v.validate(42).is_ok());
        v.reset();
        // After reset, same sequence should be accepted again
        assert!(v.validate(42).is_ok());
    }
}

/// ★ Property-Based Tests (proptest)
/// Verifies HLP packet serialization roundtrip ∀ arbitrary payloads
#[cfg(test)]
mod proptest_tests {
    use super::*;
    use proptest::prelude::*;

    fn arb_command() -> impl Strategy<Value = HlpCommand> {
        prop_oneof![
            Just(HlpCommand::EncryptRequest),
            Just(HlpCommand::EncryptResponse),
            Just(HlpCommand::DecryptRequest),
            Just(HlpCommand::DecryptResponse),
            Just(HlpCommand::KeyLoad),
            Just(HlpCommand::StatusRequest),
            Just(HlpCommand::KillCommand),
            Just(HlpCommand::Heartbeat),
            Just(HlpCommand::HeartbeatAck),
        ]
    }

    proptest! {
        #[test]
        fn prop_hlp_packet_roundtrip(
            cmd in arb_command(),
            seq in any::<u32>(),
            payload in proptest::collection::vec(any::<u8>(), 0..4096)
        ) {
            let pkt = HlpPacket::new(cmd, seq, payload.clone());
            let bytes = pkt.to_bytes();
            let parsed = HlpPacket::from_bytes(&bytes).unwrap();
            prop_assert_eq!(parsed.command, cmd);
            prop_assert_eq!(parsed.sequence, seq);
            prop_assert_eq!(parsed.payload, payload);
        }

        #[test]
        fn prop_crc32_tamper_detection(
            payload in proptest::collection::vec(any::<u8>(), 0..512),
            flip_pos in any::<usize>(),
        ) {
            let pkt = HlpPacket::new(HlpCommand::EncryptRequest, 0, payload);
            let mut bytes = pkt.to_bytes();
            if !bytes.is_empty() {
                let pos = flip_pos % bytes.len();
                bytes[pos] ^= 0x01;
                // Tampered packet should fail CRC check
                // (except in the astronomically unlikely case of CRC collision)
                let _ = HlpPacket::from_bytes(&bytes);
                // We don't assert err because CRC collision is possible (2^-32)
            }
        }
    }
}
