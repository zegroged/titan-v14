//! ★ P4 #40: Mesaj Yazma ve Gönderme Akışı — End-to-End Messaging
//!
//! Yüksek seviye mesaj API'si: compose → encrypt → frame → send → ACK

use crate::framing::{self, MessageType};
use crate::transport;
use sha2::{Sha256, Digest};
use zeroize::Zeroize;

pub const MAX_PAYLOAD_SIZE: usize = 400;
pub const MAX_RETRIES: u8 = 3;

#[derive(Debug, thiserror::Error)]
pub enum MessagingError {
    #[error("Payload too large: {0} bytes (max {MAX_PAYLOAD_SIZE})")]
    PayloadTooLarge(usize),

    #[error("Sequence number replay: expected > {expected}, got {received}")]
    SequenceReplay { expected: u64, received: u64 },

    #[error("Session not established")]
    NoSession,

    #[error("Transport error: {0}")]
    Transport(#[from] transport::TransportError),

    #[error("Framing error: {0}")]
    Framing(#[from] framing::FramingError),
}

pub struct Session {
    session_key: [u8; 32],
    our_sender_id: [u8; 32],
    peer_sender_id: [u8; 32],
    tx_seq: u64,
    rx_seq_last: u64,
    tx_count: u64,
    rx_count: u64,
}

#[derive(Debug, Clone)]
pub struct IncomingMessage {
    pub from: [u8; 32],
    pub msg_type: MessageType,
    pub payload: Vec<u8>,
    pub timestamp: u64,
    pub envelope_hash: [u8; 32],
}

const ACK_SIZE: usize = 33;

impl Session {
    pub fn new(
        session_key: [u8; 32],
        our_sender_id: [u8; 32],
        peer_sender_id: [u8; 32],
    ) -> Self {
        Self {
            session_key,
            our_sender_id,
            peer_sender_id,
            tx_seq: 0,
            rx_seq_last: 0,
            tx_count: 0,
            rx_count: 0,
        }
    }

    pub fn send_text(&mut self, text: &str) -> Result<Vec<u8>, MessagingError> {
        self.send_payload(MessageType::Text, text.as_bytes())
    }

    pub fn send_file(&mut self, data: &[u8]) -> Result<Vec<u8>, MessagingError> {
        self.send_payload(MessageType::File, data)
    }

    pub fn send_command(&mut self, cmd: &[u8]) -> Result<Vec<u8>, MessagingError> {
        self.send_payload(MessageType::Command, cmd)
    }

    fn send_payload(
        &mut self,
        msg_type: MessageType,
        payload: &[u8],
    ) -> Result<Vec<u8>, MessagingError> {
        if payload.len() > MAX_PAYLOAD_SIZE {
            return Err(MessagingError::PayloadTooLarge(payload.len()));
        }

        self.tx_seq += 1;

        let mut full_payload = Vec::with_capacity(8 + payload.len());
        full_payload.extend_from_slice(&self.tx_seq.to_be_bytes());
        full_payload.extend_from_slice(payload);

        let wire = transport::seal_and_frame(
            &self.session_key,
            msg_type,
            &self.our_sender_id,
            &full_payload,
        )?;

        self.tx_count += 1;
        Ok(wire)
    }

    pub fn receive(&mut self, cobs_data: &[u8]) -> Result<IncomingMessage, MessagingError> {
        let envelope_hash = {
            let mut hasher = Sha256::new();
            hasher.update(cobs_data);
            let result = hasher.finalize();
            let mut hash = [0u8; 32];
            hash.copy_from_slice(&result);
            hash
        };

        let inner = transport::unframe_and_open(&self.session_key, cobs_data)?;

        if inner.payload.len() < 8 {
            return Err(MessagingError::PayloadTooLarge(0));
        }
        let seq = u64::from_be_bytes([
            inner.payload[0], inner.payload[1], inner.payload[2], inner.payload[3],
            inner.payload[4], inner.payload[5], inner.payload[6], inner.payload[7],
        ]);

        if seq <= self.rx_seq_last {
            return Err(MessagingError::SequenceReplay {
                expected: self.rx_seq_last + 1,
                received: seq,
            });
        }
        self.rx_seq_last = seq;
        self.rx_count += 1;

        let actual_payload = inner.payload[8..].to_vec();

        Ok(IncomingMessage {
            from: inner.sender_id,
            msg_type: inner.msg_type,
            payload: actual_payload,
            timestamp: inner.timestamp_ms,
            envelope_hash,
        })
    }

    pub fn send_ack(&mut self, msg_hash: &[u8; 32]) -> Result<Vec<u8>, MessagingError> {
        let mut ack_payload = [0u8; ACK_SIZE];
        ack_payload[0..32].copy_from_slice(msg_hash);
        ack_payload[32] = 0x01;

        self.send_payload(MessageType::Ack, &ack_payload)
    }

    pub fn stats(&self) -> (u64, u64) {
        (self.tx_count, self.rx_count)
    }

    pub fn peer_id(&self) -> &[u8; 32] {
        &self.peer_sender_id
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.session_key.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> [u8; 32] {
        let mut key = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut key);
        key
    }

    fn alice_id() -> [u8; 32] { [0xAA; 32] }
    fn bob_id() -> [u8; 32] { [0xBB; 32] }

    #[test]
    fn t1_send_receive_roundtrip() {
        let key = test_key();
        let mut alice = Session::new(key, alice_id(), bob_id());
        let mut bob = Session::new(key, bob_id(), alice_id());

        let wire = alice.send_text("merhaba").unwrap();
        let cobs_data = &wire[..wire.len() - 1];
        let msg = bob.receive(cobs_data).unwrap();

        assert_eq!(msg.msg_type, MessageType::Text);
        assert_eq!(msg.payload, b"merhaba");
        assert_eq!(msg.from, alice_id());
    }

    #[test]
    fn t2_sequence_replay_rejected() {
        let key = test_key();
        let mut alice = Session::new(key, alice_id(), bob_id());
        let mut bob = Session::new(key, bob_id(), alice_id());

        let wire1 = alice.send_text("msg1").unwrap();
        let wire2 = alice.send_text("msg2").unwrap();

        let cobs2 = &wire2[..wire2.len() - 1];
        bob.receive(cobs2).unwrap();

        let cobs1 = &wire1[..wire1.len() - 1];
        let result = bob.receive(cobs1);
        assert!(result.is_err());
    }

    #[test]
    fn t3_ack_flow() {
        let key = test_key();
        let mut alice = Session::new(key, alice_id(), bob_id());
        let mut bob = Session::new(key, bob_id(), alice_id());

        let wire = alice.send_text("need ack").unwrap();
        let cobs_data = &wire[..wire.len() - 1];
        let msg = bob.receive(cobs_data).unwrap();

        let ack_wire = bob.send_ack(&msg.envelope_hash).unwrap();
        let ack_cobs = &ack_wire[..ack_wire.len() - 1];
        let ack_msg = alice.receive(ack_cobs).unwrap();

        assert_eq!(ack_msg.msg_type, MessageType::Ack);
        assert_eq!(&ack_msg.payload[..32], &msg.envelope_hash);
        assert_eq!(ack_msg.payload[32], 0x01);
    }

    #[test]
    fn t4_payload_size_limit() {
        let key = test_key();
        let mut session = Session::new(key, alice_id(), bob_id());

        let too_big = vec![0xAA; MAX_PAYLOAD_SIZE + 1];
        let result = session.send_payload(MessageType::Text, &too_big);
        assert!(result.is_err());
    }

    #[test]
    fn t5_session_stats() {
        let key = test_key();
        let mut alice = Session::new(key, alice_id(), bob_id());

        alice.send_text("msg1").unwrap();
        alice.send_text("msg2").unwrap();

        assert_eq!(alice.stats(), (2, 0));
    }

    #[test]
    fn t6_file_transfer() {
        let key = test_key();
        let mut alice = Session::new(key, alice_id(), bob_id());
        let mut bob = Session::new(key, bob_id(), alice_id());

        let file_data = vec![0xDE, 0xAD, 0xBE, 0xEF];
        let wire = alice.send_file(&file_data).unwrap();

        let cobs_data = &wire[..wire.len() - 1];
        let msg = bob.receive(cobs_data).unwrap();

        assert_eq!(msg.msg_type, MessageType::File);
        assert_eq!(msg.payload, file_data);
    }
}
