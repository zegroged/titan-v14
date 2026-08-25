//! HİDRA Error Types
//!
//! ★ D1 ENHANCEMENT: Comprehensive error variants covering all
//! security-critical failure modes across the entire stack.

use thiserror::Error;

#[derive(Error, Debug)]
pub enum HidraError {
    // ═══ Layer 1: AES-256-GCM-SIV ═══
    #[error("Layer 1 (AES-256-GCM-SIV) encryption failed")]
    Layer1EncryptFailed,

    #[error("Layer 1 (AES-256-GCM-SIV) decryption failed — authentication tag mismatch")]
    Layer1DecryptFailed,

    // ═══ Layer 2: TITAN FPGA ═══
    #[error("TITAN SPI communication failed: {0}")]
    TitanSpiError(String),

    // ═══ Layer 3: XChaCha20-Poly1305 ═══
    #[error("Layer 3 (XChaCha20-Poly1305) encryption failed")]
    Layer3EncryptFailed,

    #[error("Layer 3 (XChaCha20-Poly1305) decryption failed — authentication tag mismatch")]
    Layer3DecryptFailed,

    // ═══ Key Exchange ═══
    #[error("Key exchange failed: {0}")]
    KeyExchangeFailed(String),

    // ═══ Ratchet ═══
    #[error("Ratchet state corrupted: {0}")]
    RatchetError(String),

    // ═══ Protocol ═══
    #[error("Protocol error: {0}")]
    ProtocolError(String),

    #[error("Message too large: {size} > {max}")]
    MessageTooLarge { size: usize, max: usize },

    #[error("Replay attack detected: sequence {seq} already seen")]
    ReplayDetected { seq: u64 },

    // ═══ Key Material ═══
    #[error("Key material zeroization failed")]
    ZeroizeFailed,

    // ═══ ★ B1: Session Management ═══
    #[error("Session expired: {reason}")]
    SessionExpired { reason: String },

    // ═══ ★ B2: Audit ═══
    #[error("Audit log chain integrity violated — tamper detected")]
    AuditLogCorrupted,

    // ═══ ★ A3: Glitch Detection ═══
    #[error("Voltage/clock glitch detected by hardware sensor: {sensor}")]
    GlitchDetected { sensor: String },

    // ═══ ★ A2: Firmware Integrity ═══
    #[error("FPGA bitstream integrity check failed — hash mismatch")]
    BitstreamTampered,

    // ═══ ★ C4: Broker Reputation ═══
    #[error("Broker {broker_id} blacklisted: {reason}")]
    BrokerBlacklisted { broker_id: String, reason: String },

    // ═══ ★ C3: Decoy Traffic ═══
    #[error("Decoy traffic generator overflow — rate limiter triggered")]
    DecoyOverflow,

    // ═══ ★ B5: Canary ═══
    #[error("Canary watermark verification failed — possible leak")]
    CanaryMismatch,

    // ═══ ★ B3: Ephemeral Messages ═══
    #[error("Ephemeral message TTL expired: {ttl_seconds}s")]
    EphemeralExpired { ttl_seconds: u32 },

    // ═══ Network ═══
    #[error("Framing error: {0}")]
    FramingError(String),

    #[error("Hydra mesh error: {0}")]
    MeshError(String),

    #[error("Ghost Link Tor error: {0}")]
    GhostLinkError(String),

    // ═══ Hardware ═══
    #[error("TRNG health check failed — insufficient entropy")]
    TrngHealthFailed,

    #[error("PVT anomaly: {details}")]
    PvtAnomaly { details: String },

    #[error("Kill chain activated: {trigger_source}")]
    KillChainActivated { trigger_source: String },

    #[error("POST self-test failed: {component}")]
    PostTestFailed { component: String },

    // ═══ Generic ═══
    #[error("Internal error: {0}")]
    Internal(String),
}
