//! HİDRA Network Layer — Secure Mesh Communication
//!
//! Module architecture:
//! - `cobs`:             COBS byte stuffing for 0x00-free streams
//! - `transport`:        COBS-framed UART transport (MCU bridge layer)
//! - `framing`:          512-byte padded encrypted envelopes (traffic analysis resistance)
//! - `hydra`:            10-broker MQTT mesh with 3-of-10 broadcast (resilience)
//! - `ghost_link`:       Tor SOCKS5 anonymity layer (network-level privacy)
//! - `decoy`:            ★ C3: Constant-rate decoy traffic (#24/#33)
//! - `topic_rotation`:   ★ P2 #25: MQTT topic rotation (correlation resistance)
//! - `tor_jitter`:       ★ P2 #40: Tor timing jitter (circuit correlation resistance)

pub mod cobs;
pub mod transport;
pub mod framing;
pub mod hydra;
pub mod ghost_link;
pub mod shamir;
pub mod decoy;
pub mod topic_rotation;
pub mod tor_jitter;
pub mod key_exchange;   // ★ P4 #38: X25519 Key Exchange
pub mod revocation;     // ★ P4 #39: Remote Revocation
pub mod messaging;      // ★ P4 #40: End-to-End Messaging
pub mod double_ratchet; // ★ P5 #42+#43: Double Ratchet + Skipped Keys
pub mod pqc_hybrid;     // ★ P5 #46: Hybrid PQC (X25519+Kyber)
pub mod constant_time;  // ★ P5 #44: Constant-Time Operations
pub mod static_alloc;   // ★ P6 #70: 100% Static Allocation
pub mod sat_mesh;       // ★ P6 #66: Satellite/Mesh Fallback
