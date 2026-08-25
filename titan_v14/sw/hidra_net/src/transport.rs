//! COBS Transport Layer — MCU-UART Stream Framing
//!
//! Wraps `SealedEnvelope` bytes with COBS encoding for reliable
//! transmission over the MCU UART link (no 0x00 delimiter ambiguity).
//!
//! ## Wire Format
//! ```text
//! [COBS-encoded SealedEnvelope bytes][0x00 delimiter]
//! ```
//!
//! The receiver accumulates bytes until 0x00, then COBS-decodes
//! and passes to `SealedEnvelope::from_bytes()`.

use crate::cobs;
use crate::framing::{self, FramingError, MessageType, SealedEnvelope};
use thiserror::Error;

/// Transport-layer errors
#[derive(Debug, Error)]
pub enum TransportError {
    #[error("COBS decode failed: {0}")]
    CobsDecode(#[from] cobs::CobsError),

    #[error("Framing error: {0}")]
    Framing(#[from] FramingError),

    #[error("Frame too large: {0} bytes (max {MAX_FRAME_SIZE})")]
    FrameTooLarge(usize),

    #[error("Incomplete frame: received {0} bytes without delimiter")]
    IncompleteFrame(usize),
}

/// Maximum COBS frame size (2 × 512-byte envelope + overhead)
pub const MAX_FRAME_SIZE: usize = 2048;

/// COBS frame delimiter
pub const FRAME_DELIMITER: u8 = 0x00;

/// Encodes a `SealedEnvelope` into a COBS-framed wire packet.
///
/// Returns: `[COBS(envelope_bytes)][0x00]`
pub fn frame_envelope(envelope: &SealedEnvelope) -> Vec<u8> {
    let raw = envelope.to_bytes();
    let mut encoded = cobs::encode(&raw);
    encoded.push(FRAME_DELIMITER);
    encoded
}

/// Decodes a COBS-framed wire packet into a `SealedEnvelope`.
///
/// Input should NOT include the trailing 0x00 delimiter.
pub fn unframe_envelope(cobs_data: &[u8]) -> Result<SealedEnvelope, TransportError> {
    if cobs_data.len() > MAX_FRAME_SIZE {
        return Err(TransportError::FrameTooLarge(cobs_data.len()));
    }
    let raw = cobs::decode(cobs_data)?;
    let envelope = SealedEnvelope::from_bytes(&raw)?;
    Ok(envelope)
}

/// Full pipeline: plaintext message → encrypted → COBS-framed wire bytes.
///
/// This is the MCU-facing API: call this to send a message over the UART.
pub fn seal_and_frame(
    key: &[u8; 32],
    msg_type: MessageType,
    sender_id: &[u8; 32],
    payload: &[u8],
) -> Result<Vec<u8>, TransportError> {
    let envelope = framing::seal(key, msg_type, sender_id, payload)?;
    Ok(frame_envelope(&envelope))
}

/// Full pipeline: COBS wire bytes → decrypt → plaintext inner message.
///
/// Input: COBS-encoded bytes (without 0x00 delimiter).
pub fn unframe_and_open(
    key: &[u8; 32],
    cobs_data: &[u8],
) -> Result<framing::EnvelopeInner, TransportError> {
    let envelope = unframe_envelope(cobs_data)?;
    let inner = framing::open(key, &envelope)?;
    Ok(inner)
}

/// Stream accumulator: collects bytes from UART and yields complete frames.
///
/// Usage:
/// ```rust,ignore
/// use hidra_net::transport::FrameAccumulator;
///
/// let mut acc = FrameAccumulator::new();
/// // Feed bytes from UART:
/// for frame in acc.feed(&uart_bytes) {
///     // frame is a complete COBS-encoded packet (without delimiter)
///     let inner = hidra_net::transport::unframe_and_open(&key, &frame).unwrap();
/// }
/// ```
pub struct FrameAccumulator {
    buffer: Vec<u8>,
}

impl FrameAccumulator {
    pub fn new() -> Self {
        Self {
            buffer: Vec::with_capacity(MAX_FRAME_SIZE),
        }
    }

    /// Feed raw UART bytes. Returns zero or more complete frames.
    pub fn feed(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        let mut frames = Vec::new();

        for &byte in data {
            if byte == FRAME_DELIMITER {
                if !self.buffer.is_empty() {
                    frames.push(std::mem::take(&mut self.buffer));
                }
                // Empty delimiter = keepalive, ignore
            } else {
                if self.buffer.len() < MAX_FRAME_SIZE {
                    self.buffer.push(byte);
                } else {
                    // Frame too large — discard and reset
                    self.buffer.clear();
                }
            }
        }

        frames
    }

    /// Reset accumulator state (e.g., after error).
    pub fn reset(&mut self) {
        self.buffer.clear();
    }

    /// Current buffer fill level.
    pub fn buffered_bytes(&self) -> usize {
        self.buffer.len()
    }
}

impl Default for FrameAccumulator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::framing::MessageType;

    fn test_key() -> [u8; 32] {
        let mut key = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut key);
        key
    }

    fn test_sender() -> [u8; 32] {
        [0xCD; 32]
    }

    #[test]
    fn t1_frame_unframe_roundtrip() {
        let key = test_key();
        let envelope = framing::seal(&key, MessageType::Text, &test_sender(), b"test").unwrap();
        let wire = frame_envelope(&envelope);

        // Wire must end with 0x00 delimiter
        assert_eq!(*wire.last().unwrap(), FRAME_DELIMITER);

        // No internal 0x00 (except the trailing delimiter)
        assert!(!wire[..wire.len() - 1].contains(&0x00));

        // Unframe (strip delimiter)
        let restored = unframe_envelope(&wire[..wire.len() - 1]).unwrap();
        let inner = framing::open(&key, &restored).unwrap();
        assert_eq!(inner.payload, b"test");
    }

    #[test]
    fn t2_seal_and_frame_pipeline() {
        let key = test_key();
        let wire = seal_and_frame(&key, MessageType::Command, &test_sender(), b"cmd").unwrap();

        // Strip delimiter and decode
        let inner = unframe_and_open(&key, &wire[..wire.len() - 1]).unwrap();
        assert_eq!(inner.msg_type, MessageType::Command);
        assert_eq!(inner.payload, b"cmd");
    }

    #[test]
    fn t3_accumulator_single_frame() {
        let key = test_key();
        let wire = seal_and_frame(&key, MessageType::Ack, &test_sender(), b"ack").unwrap();

        let mut acc = FrameAccumulator::new();
        let frames = acc.feed(&wire);
        assert_eq!(frames.len(), 1);

        let inner = unframe_and_open(&key, &frames[0]).unwrap();
        assert_eq!(inner.payload, b"ack");
    }

    #[test]
    fn t4_accumulator_byte_by_byte() {
        let key = test_key();
        let wire = seal_and_frame(&key, MessageType::Text, &test_sender(), b"slow").unwrap();

        let mut acc = FrameAccumulator::new();
        let mut all_frames = Vec::new();

        // Feed one byte at a time
        for &byte in &wire {
            let frames = acc.feed(&[byte]);
            all_frames.extend(frames);
        }

        assert_eq!(all_frames.len(), 1);
        let inner = unframe_and_open(&key, &all_frames[0]).unwrap();
        assert_eq!(inner.payload, b"slow");
    }

    #[test]
    fn t5_accumulator_multiple_frames() {
        let key = test_key();
        let wire1 = seal_and_frame(&key, MessageType::Text, &test_sender(), b"msg1").unwrap();
        let wire2 = seal_and_frame(&key, MessageType::Text, &test_sender(), b"msg2").unwrap();

        // Concatenate two frames
        let mut combined = wire1;
        combined.extend_from_slice(&wire2);

        let mut acc = FrameAccumulator::new();
        let frames = acc.feed(&combined);
        assert_eq!(frames.len(), 2);

        let inner1 = unframe_and_open(&key, &frames[0]).unwrap();
        let inner2 = unframe_and_open(&key, &frames[1]).unwrap();
        assert_eq!(inner1.payload, b"msg1");
        assert_eq!(inner2.payload, b"msg2");
    }
}
