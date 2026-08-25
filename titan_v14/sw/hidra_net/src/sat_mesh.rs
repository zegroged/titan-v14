//! ★ P6 #66: Satellite / Mesh Fallback Transport
//!
//! GSM/LTE bağlantı kesildiğinde alternatif iletişim kanalları.
//!
//! ## Desteklenen Modlar
//! - Iridium SBD (Short Burst Data): Uydu üzerinden 340-byte mesaj
//! - LoRa Mesh: P2P mesh networking (1-2km menzil)
//! - Bluetooth LE Relay: Yakın mesafe relay zinciri
//!
//! ## Failover Sırası
//! LTE → GSM → Iridium SBD → LoRa Mesh → BLE Relay

use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TransportMode {
    /// Normal cellular (LTE/GSM)
    Cellular,
    /// Iridium SBD satellite
    IridiumSbd,
    /// LoRa mesh P2P
    LoraMesh,
    /// Bluetooth LE relay chain
    BleRelay,
    /// No connectivity
    Offline,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TransportHealth {
    Connected,
    Degraded,
    Disconnected,
}

/// Maximum payload per transport mode.
pub const fn max_payload(mode: TransportMode) -> usize {
    match mode {
        TransportMode::Cellular   => 4096,
        TransportMode::IridiumSbd => 340,  // Iridium SBD limit
        TransportMode::LoraMesh   => 222,  // LoRa max payload
        TransportMode::BleRelay   => 244,  // BLE 5.0 ATT MTU
        TransportMode::Offline    => 0,
    }
}

/// Expected latency per transport mode.
pub const fn expected_latency_ms(mode: TransportMode) -> u64 {
    match mode {
        TransportMode::Cellular   => 200,
        TransportMode::IridiumSbd => 30_000,  // 30s satellite roundtrip
        TransportMode::LoraMesh   => 5_000,   // Multi-hop delay
        TransportMode::BleRelay   => 1_000,
        TransportMode::Offline    => u64::MAX,
    }
}

/// Satellite/Mesh fallback transport manager.
pub struct FallbackTransport {
    /// Current active mode
    active_mode: TransportMode,
    /// Health status per mode
    cellular_health: TransportHealth,
    iridium_health: TransportHealth,
    lora_health: TransportHealth,
    ble_health: TransportHealth,
    /// Last connectivity check
    last_check: Option<Instant>,
    /// Check interval
    check_interval: Duration,
    /// Messages queued for retry
    retry_queue: Vec<QueuedMessage>,
    /// Maximum retry queue size
    max_queue: usize,
}

/// Message waiting for transmission.
struct QueuedMessage {
    payload: Vec<u8>,
    attempts: u32,
    max_attempts: u32,
}

impl FallbackTransport {
    /// Create with default configuration.
    pub fn new() -> Self {
        Self {
            active_mode: TransportMode::Cellular,
            cellular_health: TransportHealth::Connected,
            iridium_health: TransportHealth::Disconnected,
            lora_health: TransportHealth::Disconnected,
            ble_health: TransportHealth::Disconnected,
            last_check: None,
            check_interval: Duration::from_secs(30),
            retry_queue: Vec::new(),
            max_queue: 50,
        }
    }

    /// Update health status for a transport mode.
    pub fn update_health(&mut self, mode: TransportMode, health: TransportHealth) {
        match mode {
            TransportMode::Cellular   => self.cellular_health = health,
            TransportMode::IridiumSbd => self.iridium_health = health,
            TransportMode::LoraMesh   => self.lora_health = health,
            TransportMode::BleRelay   => self.ble_health = health,
            TransportMode::Offline    => {}
        }
    }

    /// Select best available transport (failover priority).
    pub fn select_best(&mut self) -> TransportMode {
        let mode = if self.cellular_health == TransportHealth::Connected {
            TransportMode::Cellular
        } else if self.iridium_health == TransportHealth::Connected {
            TransportMode::IridiumSbd
        } else if self.lora_health == TransportHealth::Connected {
            TransportMode::LoraMesh
        } else if self.ble_health == TransportHealth::Connected {
            TransportMode::BleRelay
        } else {
            TransportMode::Offline
        };

        self.active_mode = mode;
        mode
    }

    /// Send a message through the best available transport.
    /// Returns the mode used and whether fragmentation occurred.
    pub fn send(&mut self, payload: &[u8]) -> Result<TransportMode, TransportError> {
        let mode = self.select_best();

        if mode == TransportMode::Offline {
            // Queue for later
            self.enqueue(payload)?;
            return Err(TransportError::NoConnectivity);
        }

        let max_pl = max_payload(mode);
        if payload.len() > max_pl {
            // Fragment
            let chunks = payload.chunks(max_pl);
            for _chunk in chunks {
                // TODO: actual transmit via hardware driver
            }
        } else {
            // TODO: actual transmit
        }

        Ok(mode)
    }

    /// Queue message for retry when connectivity returns.
    fn enqueue(&mut self, payload: &[u8]) -> Result<(), TransportError> {
        if self.retry_queue.len() >= self.max_queue {
            return Err(TransportError::QueueFull);
        }
        self.retry_queue.push(QueuedMessage {
            payload: payload.to_vec(),
            attempts: 0,
            max_attempts: 5,
        });
        Ok(())
    }

    /// Drain retry queue through available transport.
    pub fn flush_queue(&mut self) -> usize {
        let mode = self.select_best();
        if mode == TransportMode::Offline {
            return 0;
        }

        let mut sent = 0;
        self.retry_queue.retain_mut(|msg| {
            msg.attempts += 1;
            if msg.attempts >= msg.max_attempts {
                return false; // Drop after max attempts
            }
            // TODO: actual transmit
            sent += 1;
            false // Remove on success
        });
        sent
    }

    /// Get current active mode.
    pub fn active_mode(&self) -> TransportMode {
        self.active_mode
    }

    /// Get retry queue length.
    pub fn queue_len(&self) -> usize {
        self.retry_queue.len()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("No connectivity available")]
    NoConnectivity,

    #[error("Retry queue full")]
    QueueFull,

    #[error("Payload too large for all available transports")]
    PayloadTooLarge,

    #[error("Hardware driver error")]
    DriverError,
}

// =============================================================================
// Tests
// =============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn t1_default_cellular() {
        let ft = FallbackTransport::new();
        assert_eq!(ft.active_mode(), TransportMode::Cellular);
    }

    #[test]
    fn t2_failover_chain() {
        let mut ft = FallbackTransport::new();

        // Cellular down → should fallback
        ft.update_health(TransportMode::Cellular, TransportHealth::Disconnected);
        ft.update_health(TransportMode::IridiumSbd, TransportHealth::Connected);

        assert_eq!(ft.select_best(), TransportMode::IridiumSbd);
    }

    #[test]
    fn t3_all_down_offline() {
        let mut ft = FallbackTransport::new();
        ft.update_health(TransportMode::Cellular, TransportHealth::Disconnected);

        assert_eq!(ft.select_best(), TransportMode::Offline);
    }

    #[test]
    fn t4_max_payload_sizes() {
        assert_eq!(max_payload(TransportMode::Cellular), 4096);
        assert_eq!(max_payload(TransportMode::IridiumSbd), 340);
        assert_eq!(max_payload(TransportMode::LoraMesh), 222);
        assert_eq!(max_payload(TransportMode::BleRelay), 244);
    }

    #[test]
    fn t5_queue_on_offline() {
        let mut ft = FallbackTransport::new();
        ft.update_health(TransportMode::Cellular, TransportHealth::Disconnected);

        let result = ft.send(b"test message");
        assert!(result.is_err());
        assert_eq!(ft.queue_len(), 1);
    }

    #[test]
    fn t6_failover_recovery() {
        let mut ft = FallbackTransport::new();

        // Go offline
        ft.update_health(TransportMode::Cellular, TransportHealth::Disconnected);
        assert_eq!(ft.select_best(), TransportMode::Offline);

        // Cellular comes back
        ft.update_health(TransportMode::Cellular, TransportHealth::Connected);
        assert_eq!(ft.select_best(), TransportMode::Cellular);
    }
}
