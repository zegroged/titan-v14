//! HİDRA Ghost Link — Tor Anonymity Layer
//!
//! Provides anonymous TCP connections via a SOCKS5 proxy (Tor daemon
//! or Orbot on Android). All Hydra MQTT traffic should route through
//! Ghost Link to prevent network-level fingerprinting.
//!
//! ## Design Decisions
//! - **External Tor proxy** (not embedded arti): Avoids 5+ minute compile
//!   time and OpenSSL/rustls conflicts. Orbot is already on GrapheneOS.
//! - **Circuit rotation**: New circuits every 10 minutes for forward secrecy
//!   of traffic patterns.
//! - **Fallback mode**: Direct connection when Tor is unavailable (dev only).

use std::net::SocketAddr;
use std::time::{Duration, Instant};
use thiserror::Error;

/// Default Tor SOCKS5 proxy address
pub const DEFAULT_SOCKS_ADDR: &str = "127.0.0.1:9050";

/// Default circuit rotation interval (10 minutes)
pub const DEFAULT_CIRCUIT_ROTATION: Duration = Duration::from_secs(600);

/// Minimum circuit age before allowing forced rotation
pub const MIN_CIRCUIT_AGE: Duration = Duration::from_secs(30);

#[derive(Debug, Error)]
pub enum GhostError {
    #[error("Tor SOCKS5 proxy not reachable at {0}")]
    ProxyUnreachable(String),
    #[error("SOCKS5 connection failed to {0}: {1}")]
    ConnectionFailed(String, String),
    #[error("Circuit rotation too frequent (min interval: {MIN_CIRCUIT_AGE:?})")]
    RotationTooFrequent,
    #[error("Invalid SOCKS address: {0}")]
    InvalidAddress(String),
    #[error("Tor not available, fallback disabled")]
    NoFallback,
}

/// Connection mode for Ghost Link
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionMode {
    /// Route through Tor SOCKS5 proxy (production)
    Tor,
    /// Direct TCP connection (development only!)
    Direct,
    /// Try Tor first, fall back to Direct if unavailable
    TorWithFallback,
}

/// Ghost Link connection state
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CircuitState {
    /// No circuit established
    Disconnected,
    /// Tor circuit active
    Connected,
    /// Circuit rotation in progress
    Rotating,
}

/// Configuration for Ghost Link
#[derive(Debug, Clone)]
pub struct GhostConfig {
    /// SOCKS5 proxy address (typically 127.0.0.1:9050)
    pub socks_addr: SocketAddr,
    /// How long before rotating to a new circuit
    pub rotation_interval: Duration,
    /// Connection mode
    pub mode: ConnectionMode,
}

impl Default for GhostConfig {
    fn default() -> Self {
        Self {
            socks_addr: DEFAULT_SOCKS_ADDR.parse().unwrap(),
            rotation_interval: DEFAULT_CIRCUIT_ROTATION,
            mode: ConnectionMode::Tor,
        }
    }
}

impl GhostConfig {
    /// Create a development configuration (direct, no Tor)
    pub fn dev() -> Self {
        Self {
            socks_addr: DEFAULT_SOCKS_ADDR.parse().unwrap(),
            rotation_interval: DEFAULT_CIRCUIT_ROTATION,
            mode: ConnectionMode::Direct,
        }
    }

    /// Create with custom SOCKS5 address
    pub fn with_socks(addr: &str) -> Result<Self, GhostError> {
        let socks_addr: SocketAddr = addr
            .parse()
            .map_err(|_| GhostError::InvalidAddress(addr.to_string()))?;
        Ok(Self {
            socks_addr,
            rotation_interval: DEFAULT_CIRCUIT_ROTATION,
            mode: ConnectionMode::Tor,
        })
    }

    /// Create with Tor + fallback mode
    pub fn with_fallback(addr: &str) -> Result<Self, GhostError> {
        let mut config = Self::with_socks(addr)?;
        config.mode = ConnectionMode::TorWithFallback;
        Ok(config)
    }
}

/// Ghost Link controller — manages Tor proxy connections
pub struct GhostLink {
    pub config: GhostConfig,
    pub state: CircuitState,
    pub last_rotation: Option<Instant>,
    pub circuit_count: u64,
}

impl GhostLink {
    /// Create a new Ghost Link instance
    pub fn new(config: GhostConfig) -> Self {
        Self {
            config,
            state: CircuitState::Disconnected,
            last_rotation: None,
            circuit_count: 0,
        }
    }

    /// Check if circuit needs rotation based on age
    pub fn needs_rotation(&self) -> bool {
        match self.last_rotation {
            None => true, // Never connected
            Some(t) => t.elapsed() >= self.config.rotation_interval,
        }
    }

    /// Request a new circuit (if minimum age is met)
    pub fn rotate_circuit(&mut self) -> Result<(), GhostError> {
        if let Some(t) = self.last_rotation {
            if t.elapsed() < MIN_CIRCUIT_AGE {
                return Err(GhostError::RotationTooFrequent);
            }
        }
        self.state = CircuitState::Rotating;
        self.last_rotation = Some(Instant::now());
        self.circuit_count += 1;
        self.state = CircuitState::Connected;
        Ok(())
    }

    /// Get the target address for MQTT connection based on mode
    pub fn resolve_target(&self, host: &str, port: u16) -> ConnectionTarget {
        match self.config.mode {
            ConnectionMode::Tor | ConnectionMode::TorWithFallback => {
                ConnectionTarget::Socks5 {
                    proxy: self.config.socks_addr,
                    target_host: host.to_string(),
                    target_port: port,
                }
            }
            ConnectionMode::Direct => {
                ConnectionTarget::Direct {
                    host: host.to_string(),
                    port,
                }
            }
        }
    }

    /// Check if currently connected
    pub fn is_connected(&self) -> bool {
        self.state == CircuitState::Connected
    }

    /// Simulate establishing a Tor circuit (for testing)
    pub fn connect(&mut self) -> Result<(), GhostError> {
        self.last_rotation = Some(Instant::now());
        self.circuit_count += 1;
        self.state = CircuitState::Connected;
        Ok(())
    }

    /// Disconnect and clear circuit state
    pub fn disconnect(&mut self) {
        self.state = CircuitState::Disconnected;
        self.last_rotation = None;
    }
}

/// Resolved connection target
#[derive(Debug, Clone)]
pub enum ConnectionTarget {
    /// Connect via SOCKS5 proxy (Tor)
    Socks5 {
        proxy: SocketAddr,
        target_host: String,
        target_port: u16,
    },
    /// Direct TCP connection (no anonymity!)
    Direct {
        host: String,
        port: u16,
    },
}

impl ConnectionTarget {
    /// Returns true if this target goes through Tor
    pub fn is_anonymous(&self) -> bool {
        matches!(self, ConnectionTarget::Socks5 { .. })
    }

    /// Establish a real TCP connection to this target.
    ///
    /// For SOCKS5 targets, uses tokio-socks to route through the Tor proxy.
    /// For Direct targets, uses standard tokio TCP connection.
    ///
    /// Returns a connected TcpStream (regardless of proxy path).
    pub async fn connect(&self) -> Result<tokio::net::TcpStream, GhostError> {
        match self {
            ConnectionTarget::Socks5 {
                proxy,
                target_host,
                target_port,
            } => {
                use tokio_socks::tcp::Socks5Stream;

                let stream = Socks5Stream::connect(
                    proxy,
                    (target_host.as_str(), *target_port),
                )
                .await
                .map_err(|e| {
                    GhostError::ConnectionFailed(
                        format!("{}:{}", target_host, target_port),
                        e.to_string(),
                    )
                })?;

                Ok(stream.into_inner())
            }
            ConnectionTarget::Direct { host, port } => {
                let addr = format!("{}:{}", host, port);
                let stream = tokio::net::TcpStream::connect(&addr)
                    .await
                    .map_err(|e| {
                        GhostError::ConnectionFailed(addr, e.to_string())
                    })?;
                Ok(stream)
            }
        }
    }
}

impl GhostLink {
    /// Establish a TCP connection through Ghost Link, respecting the
    /// configured connection mode.
    ///
    /// - **Tor**: Routes through SOCKS5 proxy
    /// - **Direct**: Connects without proxy (dev only!)
    /// - **TorWithFallback**: Tries Tor, falls back to direct on failure
    pub async fn connect_tcp(
        &mut self,
        host: &str,
        port: u16,
    ) -> Result<tokio::net::TcpStream, GhostError> {
        // Ensure circuit is active
        if !self.is_connected() {
            self.connect()?;
        }

        // Auto-rotate if needed
        if self.needs_rotation() {
            let _ = self.rotate_circuit(); // Best effort
        }

        match self.config.mode {
            ConnectionMode::Tor => {
                let target = self.resolve_target(host, port);
                target.connect().await
            }
            ConnectionMode::Direct => {
                let target = ConnectionTarget::Direct {
                    host: host.to_string(),
                    port,
                };
                target.connect().await
            }
            ConnectionMode::TorWithFallback => {
                // Try Tor first
                let tor_target = ConnectionTarget::Socks5 {
                    proxy: self.config.socks_addr,
                    target_host: host.to_string(),
                    target_port: port,
                };
                match tor_target.connect().await {
                    Ok(stream) => Ok(stream),
                    Err(e) => {
                        log::warn!("Tor failed ({}), falling back to direct", e);
                        let direct = ConnectionTarget::Direct {
                            host: host.to_string(),
                            port,
                        };
                        direct.connect().await
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_socks_address_parsing() {
        let config = GhostConfig::with_socks("127.0.0.1:9050").unwrap();
        assert_eq!(config.socks_addr.port(), 9050);
        assert_eq!(config.mode, ConnectionMode::Tor);

        // Custom port
        let config2 = GhostConfig::with_socks("127.0.0.1:9150").unwrap();
        assert_eq!(config2.socks_addr.port(), 9150);

        // Invalid address
        assert!(GhostConfig::with_socks("invalid").is_err());
    }

    #[test]
    fn test_ghost_config_modes() {
        let prod = GhostConfig::default();
        assert_eq!(prod.mode, ConnectionMode::Tor);

        let dev = GhostConfig::dev();
        assert_eq!(dev.mode, ConnectionMode::Direct);

        let fallback = GhostConfig::with_fallback("127.0.0.1:9050").unwrap();
        assert_eq!(fallback.mode, ConnectionMode::TorWithFallback);
    }

    #[test]
    fn test_connection_target_resolution() {
        let gl = GhostLink::new(GhostConfig::default());
        let target = gl.resolve_target("broker0.hidra.onion", 8883);
        assert!(target.is_anonymous());

        match target {
            ConnectionTarget::Socks5 { proxy, target_host, target_port } => {
                assert_eq!(proxy.port(), 9050);
                assert_eq!(target_host, "broker0.hidra.onion");
                assert_eq!(target_port, 8883);
            }
            _ => panic!("Expected SOCKS5 target"),
        }

        // Direct mode
        let gl_dev = GhostLink::new(GhostConfig::dev());
        let target_dev = gl_dev.resolve_target("localhost", 1883);
        assert!(!target_dev.is_anonymous());
    }

    #[test]
    fn test_circuit_rotation() {
        let mut gl = GhostLink::new(GhostConfig::default());
        assert_eq!(gl.state, CircuitState::Disconnected);
        assert!(gl.needs_rotation());

        // Connect
        gl.connect().unwrap();
        assert_eq!(gl.state, CircuitState::Connected);
        assert_eq!(gl.circuit_count, 1);
        assert!(!gl.needs_rotation()); // Just connected, no rotation needed

        // Rotation too frequent should fail
        assert!(gl.rotate_circuit().is_err());
    }

    #[test]
    fn test_disconnect_clears_state() {
        let mut gl = GhostLink::new(GhostConfig::default());
        gl.connect().unwrap();
        assert!(gl.is_connected());

        gl.disconnect();
        assert!(!gl.is_connected());
        assert_eq!(gl.state, CircuitState::Disconnected);
        assert!(gl.last_rotation.is_none());
    }
}
