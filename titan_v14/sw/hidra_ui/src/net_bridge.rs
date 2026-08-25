//! Network Bridge — Connects TUI to Hydra mesh + Ghost Link + Framing
//!
//! This module provides the integration layer between the terminal UI
//! and the network subsystem. It handles:
//! - Sealing messages into encrypted envelopes (framing)
//! - Broadcasting via the Hydra MQTT mesh
//! - Ghost Link Tor circuit management
//! - Incoming message reception (via channel)

use anyhow::Result;
use hidra_net::framing::{self, MessageType};
use hidra_net::ghost_link::{CircuitState, GhostConfig, GhostLink};
use hidra_net::hydra::{default_broker_configs, HydraMesh, HEALTH_ALIVE};
use tokio::sync::mpsc;

/// A received plaintext message from the network
#[derive(Debug, Clone)]
#[allow(dead_code)] // Fields used when async receive loop is wired
pub struct IncomingMessage {
    pub sender_id: [u8; 32],
    pub payload: Vec<u8>,
    pub timestamp_ms: u64,
}

/// Network bridge state
#[allow(dead_code)] // Fields consumed when async dispatch is wired
pub struct NetworkBridge {
    /// Encryption key for sealing envelopes
    pub(crate) envelope_key: [u8; 32],
    /// Our sender identity
    pub(crate) sender_id: [u8; 32],
    /// The Hydra MQTT mesh controller
    mesh: HydraMesh,
    /// Ghost Link Tor controller
    ghost: GhostLink,
    /// Channel for incoming messages
    incoming_tx: mpsc::Sender<IncomingMessage>,
    incoming_rx: mpsc::Receiver<IncomingMessage>,
    /// Statistics
    pub messages_sent: u64,
    pub messages_received: u64,
    pub last_error: Option<String>,
}

#[allow(dead_code)] // Methods consumed when async dispatch is wired
impl NetworkBridge {
    /// Create a new network bridge with default configuration.
    ///
    /// In SIM mode, uses development Ghost Link config (no Tor needed).
    /// The envelope key and sender ID should come from the key exchange
    /// module in production.
    pub fn new(envelope_key: [u8; 32], sender_id: [u8; 32]) -> Self {
        let configs = default_broker_configs();
        let topic_secret = {
            // ★ B4 FIX: Proper HKDF-SHA256 derivation (was weak XOR with 0x5C)
            use hkdf::Hkdf;
            use sha2::Sha256;
            let hk = Hkdf::<Sha256>::new(None, &envelope_key);
            let mut ts = [0u8; 32];
            hk.expand(b"HIDRA-TOPIC-SECRET-V1", &mut ts)
                .expect("HKDF expand failed");
            ts
        };
        let mesh = HydraMesh::new(configs, topic_secret, "hidra_main".to_string());

        // In SIM mode, set first 7 brokers as ALIVE (simulating real network)
        for (i, broker) in mesh.brokers.iter().enumerate() {
            if i < 7 {
                broker.set_health(HEALTH_ALIVE);
            }
        }

        let ghost = GhostLink::new(GhostConfig::dev()); // SIM mode: direct

        let (incoming_tx, incoming_rx) = mpsc::channel(256);

        Self {
            envelope_key,
            sender_id,
            mesh,
            ghost,
            incoming_tx,
            incoming_rx,
            messages_sent: 0,
            messages_received: 0,
            last_error: None,
        }
    }

    /// Send a text message through the encrypted network.
    ///
    /// Pipeline: plaintext → SealedEnvelope → wire bytes → Hydra broadcast
    pub async fn send_message(&mut self, plaintext: &[u8]) -> Result<Vec<String>> {
        // Step 1: Seal into encrypted envelope
        let envelope = framing::seal(
            &self.envelope_key,
            MessageType::Text,
            &self.sender_id,
            plaintext,
        )
        .map_err(|e| anyhow::anyhow!("Framing seal failed: {}", e))?;

        // Step 2: Serialize to wire format
        let wire_bytes = envelope.to_bytes();

        // Step 3: Broadcast via Hydra mesh
        let broker_ids = self
            .mesh
            .broadcast_message(&wire_bytes)
            .await
            .map_err(|e| anyhow::anyhow!("Hydra broadcast failed: {}", e))?;

        self.messages_sent += 1;
        Ok(broker_ids)
    }

    /// Get network status for TUI display
    pub fn status_summary(&self) -> NetworkStatusReport {
        let healthy = self.mesh.healthy_count();
        let total = self.mesh.brokers.len();
        let tor_connected = self.ghost.is_connected();
        let circuit_count = self.ghost.circuit_count;

        NetworkStatusReport {
            healthy_brokers: healthy,
            total_brokers: total,
            tor_connected,
            circuit_count,
            ghost_state: self.ghost.state,
            messages_sent: self.messages_sent,
            messages_received: self.messages_received,
            last_error: self.last_error.clone(),
        }
    }

    /// Process any incoming messages from the receive channel
    pub fn try_recv(&mut self) -> Option<IncomingMessage> {
        match self.incoming_rx.try_recv() {
            Ok(msg) => {
                self.messages_received += 1;
                Some(msg)
            }
            Err(_) => None,
        }
    }

    /// Get the current MQTT topic for display
    pub fn current_topic(&self) -> Option<String> {
        self.mesh.current_topic().ok()
    }

    /// Get a clone of the incoming message sender (for background tasks)
    pub fn incoming_sender(&self) -> mpsc::Sender<IncomingMessage> {
        self.incoming_tx.clone()
    }
}

/// Status report for the TUI
#[derive(Debug, Clone)]
#[allow(dead_code)] // Fields read by TUI rendering code
pub struct NetworkStatusReport {
    pub healthy_brokers: usize,
    pub total_brokers: usize,
    pub tor_connected: bool,
    pub circuit_count: u64,
    pub ghost_state: CircuitState,
    pub messages_sent: u64,
    pub messages_received: u64,
    pub last_error: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_bridge() -> NetworkBridge {
        let key = [0x42u8; 32];
        let sender = [0x01u8; 32];
        NetworkBridge::new(key, sender)
    }

    #[test]
    fn test_bridge_creation() {
        let bridge = test_bridge();
        assert_eq!(bridge.messages_sent, 0);
        assert_eq!(bridge.messages_received, 0);
        assert!(bridge.last_error.is_none());
    }

    #[test]
    fn test_status_report() {
        let bridge = test_bridge();
        let status = bridge.status_summary();
        assert_eq!(status.healthy_brokers, 7); // SIM mode default
        assert_eq!(status.total_brokers, 10);
        assert!(!status.tor_connected); // Dev mode starts disconnected
    }

    #[test]
    fn test_current_topic() {
        let bridge = test_bridge();
        let topic = bridge.current_topic();
        assert!(topic.is_some());
        assert!(topic.unwrap().starts_with("h/"));
    }

    #[test]
    fn test_try_recv_empty() {
        let mut bridge = test_bridge();
        assert!(bridge.try_recv().is_none());
    }
}
