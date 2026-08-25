//! PROJECT HİDRA — Paranoid-Grade Crypto Core
//!
//! Triple-layer encryption, Hybrid PQ Key Exchange, Signal Double Ratchet.
//!
//! # Architecture
//! - Layer 1: AES-256-GCM-SIV (software, nonce-misuse resistant AEAD)
//! - Layer 2: AES-256-CTR + Omega Cloak (TITAN FPGA hardware, DPA protected)
//! - Layer 3: XChaCha20-Poly1305 (transport, 192-bit nonce, algorithmic diversity)
//!
//! # Key Exchange
//! - Hybrid: X25519 (classical ECDH) + Kyber-768 (post-quantum KEM)
//! - Combined: HKDF-SHA256(X25519_ss || Kyber_ss)
//!
//! # Forward Secrecy
//! - Signal Double Ratchet: per-message key derivation
//! - Compromising one key reveals nothing about past/future keys

pub mod crypto;
pub mod transport_crypto;
pub mod key_exchange;
pub mod ratchet;
pub mod protocol;
pub mod titan_spi;
pub mod error;
pub mod session;
pub mod audit;
pub mod canary;
pub mod constant_time;
pub mod trng_conditioning;  // ★ B-4: TRNG hash conditioning
pub mod secure_boot;          // ★ C-5: Firmware secure boot

pub use error::HidraError;
