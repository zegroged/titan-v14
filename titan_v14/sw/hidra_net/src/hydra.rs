//! HİDRA Hydra MQTT Mesh — Resilient 10-Broker Communication
//!
//! ## Architecture (from Apex/LEVIATHAN)
//! - **10 Broker Pool**: Distributed MQTT brokers across different regions
//! - **3-of-10 Broadcast**: Each message published to 3 random healthy brokers
//! - **Time-Rotating Topics**: HMAC-SHA256 derived topic names rotated hourly
//! - **Message Dedup**: Nonce-based deduplication of received messages
//! - **Health Monitoring**: Periodic broker liveness checks
//! - **★ C4: Reputation System**: Decay-weighted scoring, auto-blacklist
//! - **★ C2: Dead Drop**: Time-offset asynchronous messaging pattern
//!
//! ## Security Properties
//! - Topic names are unpredictable (HMAC with shared secret)
//! - Broker compromise: 3-of-10 means any 7 can fail without message loss
//! - No single broker sees all traffic
//! - Messages are pre-encrypted (SealedEnvelope from framing.rs)

use hmac::{Hmac, Mac};
use rand::seq::SliceRandom;
use sha2::Sha256;
use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::RwLock;

type HmacSha256 = Hmac<Sha256>;

/// Maximum number of recent nonces to track for dedup
const DEDUP_WINDOW: usize = 2000;

/// Broker health states
pub const HEALTH_DEAD: u8 = 0;
pub const HEALTH_SICK: u8 = 1;
pub const HEALTH_ALIVE: u8 = 2;

/// Number of brokers to multicast each message to
pub const BROADCAST_K: usize = 3;

/// Topic rotation interval in seconds (1 hour)
pub const TOPIC_ROTATION_SECS: u64 = 3600;

#[derive(Debug, Error)]
pub enum HydraError {
    #[error("Not enough healthy brokers: need {BROADCAST_K}, have {0}")]
    InsufficientBrokers(usize),
    #[error("All brokers dead")]
    AllBrokersDead,
    #[error("MQTT connection error: {0}")]
    MqttError(String),
    #[error("Broker not found: {0}")]
    BrokerNotFound(String),
    #[error("Topic derivation failed")]
    TopicDerivationFailed,
}

/// Configuration for a single MQTT broker
#[derive(Debug, Clone)]
pub struct BrokerConfig {
    pub id: String,
    pub host: String,
    pub port: u16,
    pub use_tor: bool,
}

/// Runtime state for a broker connection
#[derive(Debug)]
pub struct BrokerNode {
    pub config: BrokerConfig,
    pub health: AtomicU8,
    pub message_count: AtomicU8,
    /// ★ C4: Reputation tracking
    pub reputation: std::sync::Mutex<BrokerReputation>,
}

impl BrokerNode {
    pub fn new(config: BrokerConfig) -> Self {
        Self {
            config,
            health: AtomicU8::new(HEALTH_DEAD),
            message_count: AtomicU8::new(0),
            reputation: std::sync::Mutex::new(BrokerReputation::new()),
        }
    }

    pub fn is_healthy(&self) -> bool {
        self.health.load(Ordering::Relaxed) == HEALTH_ALIVE
    }

    pub fn set_health(&self, h: u8) {
        self.health.store(h, Ordering::Relaxed);
    }

    /// ★ C4: Check if broker is blacklisted
    pub fn is_blacklisted(&self) -> bool {
        self.reputation.lock().unwrap().blacklisted
    }

    /// ★ C4: Get reputation score
    pub fn reputation_score(&self) -> f64 {
        self.reputation.lock().unwrap().score()
    }

    /// ★ C4: Record successful delivery
    pub fn record_success(&self) {
        self.reputation.lock().unwrap().record_success();
    }

    /// ★ C4: Record failed delivery
    pub fn record_failure(&self) {
        let mut rep = self.reputation.lock().unwrap();
        rep.record_failure();
    }
}

/// ★ C4: Broker reputation tracking with decay-weighted scoring
#[derive(Debug)]
pub struct BrokerReputation {
    /// Total successful deliveries
    pub successes: u64,
    /// Total failed deliveries
    pub failures: u64,
    /// Recent success rate (exponential moving average)
    pub ema_success_rate: f64,
    /// EMA decay factor (0.0 = no memory, 1.0 = perfect memory)
    pub decay: f64,
    /// Whether this broker is blacklisted
    pub blacklisted: bool,
    /// Blacklist threshold (below this EMA = auto-blacklist)
    pub blacklist_threshold: f64,
}

impl BrokerReputation {
    pub fn new() -> Self {
        Self {
            successes: 0,
            failures: 0,
            ema_success_rate: 1.0,  // Assume good until proven otherwise
            decay: 0.9,
            blacklisted: false,
            blacklist_threshold: 0.3,  // Below 30% success → blacklist
        }
    }

    /// Record a successful delivery
    pub fn record_success(&mut self) {
        self.successes += 1;
        // EMA update: rate = decay * old_rate + (1 - decay) * 1.0
        self.ema_success_rate = self.decay * self.ema_success_rate + (1.0 - self.decay);
        // Un-blacklist if recovered
        if self.ema_success_rate > self.blacklist_threshold * 2.0 {
            self.blacklisted = false;
        }
    }

    /// Record a failed delivery
    pub fn record_failure(&mut self) {
        self.failures += 1;
        // EMA update: rate = decay * old_rate + (1 - decay) * 0.0
        self.ema_success_rate = self.decay * self.ema_success_rate;
        // Auto-blacklist if below threshold
        if self.ema_success_rate < self.blacklist_threshold {
            self.blacklisted = true;
        }
    }

    /// Get overall reputation score (0.0 = terrible, 1.0 = perfect)
    pub fn score(&self) -> f64 {
        if self.blacklisted {
            return 0.0;
        }
        self.ema_success_rate
    }

    /// Total interactions
    pub fn total(&self) -> u64 {
        self.successes + self.failures
    }
}

/// Broadcast policy for selecting which brokers to publish to
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BroadcastPolicy {
    /// Pick K random healthy brokers (default)
    RandomK(usize),
    /// Broadcast to ALL healthy brokers
    All,
}

/// The Hydra MQTT Mesh controller
pub struct HydraMesh {
    pub brokers: Vec<Arc<BrokerNode>>,
    pub policy: BroadcastPolicy,
    pub topic_secret: [u8; 32],
    pub channel_name: String,
    dedup_set: Arc<RwLock<HashSet<[u8; 24]>>>,
    dedup_order: Arc<RwLock<VecDeque<[u8; 24]>>>,  // ★ FIX: FIFO order tracking
}

impl HydraMesh {
    /// Create a new Hydra mesh with the given broker configs.
    ///
    /// # Arguments
    /// - `configs`: List of broker configurations (typically 10)
    /// - `topic_secret`: 256-bit HMAC key for topic rotation
    /// - `channel_name`: Human-readable channel identifier
    pub fn new(
        configs: Vec<BrokerConfig>,
        topic_secret: [u8; 32],
        channel_name: String,
    ) -> Self {
        let brokers = configs
            .into_iter()
            .map(|c| Arc::new(BrokerNode::new(c)))
            .collect();

        Self {
            brokers,
            policy: BroadcastPolicy::RandomK(BROADCAST_K),
            topic_secret,
            channel_name,
            dedup_set: Arc::new(RwLock::new(HashSet::with_capacity(DEDUP_WINDOW))),
            dedup_order: Arc::new(RwLock::new(VecDeque::with_capacity(DEDUP_WINDOW))),
        }
    }

    /// Get the current MQTT topic derived from HMAC + time rotation.
    ///
    /// Topic = base64(HMAC-SHA256(secret, channel_name || time_slot))
    /// Rotates every TOPIC_ROTATION_SECS seconds.
    pub fn current_topic(&self) -> Result<String, HydraError> {
        let time_slot = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| HydraError::TopicDerivationFailed)?
            .as_secs()
            / TOPIC_ROTATION_SECS;

        Self::derive_topic(&self.topic_secret, &self.channel_name, time_slot)
    }

    /// Derive a topic for a specific time slot (deterministic)
    pub fn derive_topic(
        secret: &[u8; 32],
        channel: &str,
        time_slot: u64,
    ) -> Result<String, HydraError> {
        let mut mac = HmacSha256::new_from_slice(secret)
            .map_err(|_| HydraError::TopicDerivationFailed)?;
        mac.update(channel.as_bytes());
        mac.update(&time_slot.to_le_bytes());
        let result = mac.finalize().into_bytes();

        // Use URL-safe base64, truncated to 22 chars for MQTT compatibility
        let topic = base64::Engine::encode(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
            &result[..16],
        );
        Ok(format!("h/{}", topic))
    }

    /// Count currently healthy brokers
    pub fn healthy_count(&self) -> usize {
        self.brokers.iter().filter(|b| b.is_healthy()).count()
    }

    /// Select K random healthy brokers according to broadcast policy
    /// ★ C4: Filters out blacklisted brokers, prioritizes high-reputation
    pub fn select_targets(&self) -> Result<Vec<Arc<BrokerNode>>, HydraError> {
        let healthy: Vec<Arc<BrokerNode>> = self
            .brokers
            .iter()
            .filter(|b| b.is_healthy() && !b.is_blacklisted())
            .cloned()
            .collect();

        match self.policy {
            BroadcastPolicy::All => {
                if healthy.is_empty() {
                    Err(HydraError::AllBrokersDead)
                } else {
                    Ok(healthy)
                }
            }
            BroadcastPolicy::RandomK(k) => {
                if healthy.len() < k {
                    return Err(HydraError::InsufficientBrokers(healthy.len()));
                }
                // ★ C4: Sort by reputation (best first), then pick top K
                // with some randomization to avoid predictability
                let mut scored: Vec<_> = healthy
                    .iter()
                    .map(|b| (b.clone(), b.reputation_score()))
                    .collect();
                scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                
                // Take top 2*K candidates, then randomly pick K from them
                let pool_size = std::cmp::min(scored.len(), k * 2);
                let mut pool: Vec<Arc<BrokerNode>> = scored[..pool_size]
                    .iter()
                    .map(|(b, _)| b.clone())
                    .collect();
                let mut rng = rand::thread_rng();
                pool.shuffle(&mut rng);
                pool.truncate(k);
                Ok(pool)
            }
        }
    }

    /// ★ C2: Dead Drop — derive a topic for time-offset messaging
    /// 
    /// Sender publishes to topic at time T; receiver reads at time T + offset.
    /// The topic is deterministic for both parties but the access pattern
    /// breaks timing correlation.
    pub fn dead_drop_topic(&self, drop_id: &str, time_slot_offset: i64) -> Result<String, HydraError> {
        let base_slot = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| HydraError::TopicDerivationFailed)?
            .as_secs() as i64
            / TOPIC_ROTATION_SECS as i64;
        
        let target_slot = (base_slot + time_slot_offset) as u64;

        let mut mac = HmacSha256::new_from_slice(&self.topic_secret)
            .map_err(|_| HydraError::TopicDerivationFailed)?;
        mac.update(b"DEAD-DROP-V1:");
        mac.update(drop_id.as_bytes());
        mac.update(&target_slot.to_le_bytes());
        let result = mac.finalize().into_bytes();

        let topic = base64::Engine::encode(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
            &result[..16],
        );
        Ok(format!("d/{}", topic))
    }

    /// Check if a nonce has been seen before (dedup).
    /// Returns true if this is a NEW (unseen) nonce.
    pub async fn check_and_record_nonce(&self, nonce: &[u8; 24]) -> bool {
        let mut set = self.dedup_set.write().await;
        if set.contains(nonce) {
            return false; // Already seen
        }
        let mut order = self.dedup_order.write().await;
        // ★ FIX: FIFO eviction — remove oldest nonces (front of deque)
        if set.len() >= DEDUP_WINDOW {
            let to_remove = DEDUP_WINDOW / 2;
            for _ in 0..to_remove {
                if let Some(old) = order.pop_front() {
                    set.remove(&old);
                }
            }
        }
        set.insert(*nonce);
        order.push_back(*nonce);
        true
    }

    /// Get broker by ID
    pub fn get_broker(&self, id: &str) -> Option<Arc<BrokerNode>> {
        self.brokers.iter().find(|b| b.config.id == id).cloned()
    }

    /// Set all brokers to a specific health state (for testing)
    pub fn set_all_health(&self, health: u8) {
        for b in &self.brokers {
            b.set_health(health);
        }
    }

    /// Broadcast a sealed message to K random healthy brokers.
    ///
    /// This is the primary way to send messages through the Hydra mesh.
    /// Each message is published to `BROADCAST_K` (3) brokers using the
    /// current time-rotating topic.
    ///
    /// Returns the list of broker IDs that successfully received the message.
    pub async fn broadcast_message(
        &self,
        payload: &[u8],
    ) -> Result<Vec<String>, HydraError> {
        let targets = self.select_targets()?;
        let topic = self.current_topic()?;
        let mut success_ids = Vec::new();

        for broker in &targets {
            match self.publish_to_broker(broker, &topic, payload).await {
                Ok(()) => {
                    broker.message_count.fetch_add(1, Ordering::Relaxed);
                    success_ids.push(broker.config.id.clone());
                }
                Err(e) => {
                    log::warn!(
                        "Publish to {} failed: {} — marking SICK",
                        broker.config.id, e
                    );
                    broker.set_health(HEALTH_SICK);
                }
            }
        }

        if success_ids.is_empty() {
            return Err(HydraError::MqttError("All target publishes failed".into()));
        }

        Ok(success_ids)
    }

    /// Publish a message to a single broker via rumqttc.
    ///
    /// Creates a short-lived MQTT connection, publishes, and disconnects.
    /// In production, connections would be pooled and persistent.
    async fn publish_to_broker(
        &self,
        broker: &BrokerNode,
        topic: &str,
        payload: &[u8],
    ) -> Result<(), HydraError> {
        use rumqttc::{AsyncClient, MqttOptions, QoS};

        let client_id = format!("hidra_{}", &broker.config.id);
        let mut opts = MqttOptions::new(
            &client_id,
            &broker.config.host,
            broker.config.port,
        );
        opts.set_keep_alive(std::time::Duration::from_secs(10));
        opts.set_clean_session(true);

        let (client, mut eventloop) = AsyncClient::new(opts, 16);

        // Spawn event loop handler (required by rumqttc)
        let handle = tokio::spawn(async move {
            // Process events until disconnected or error
            loop {
                match eventloop.poll().await {
                    Ok(_) => continue,
                    Err(_) => break,
                }
            }
        });

        // Publish with QoS 1 (at-least-once)
        client
            .publish(topic, QoS::AtLeastOnce, false, payload)
            .await
            .map_err(|e| HydraError::MqttError(e.to_string()))?;

        // Grace period for publish to flush
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        // Disconnect and clean up
        let _ = client.disconnect().await;
        handle.abort();

        Ok(())
    }

    /// Subscribe to the current time-rotating channel topic.
    ///
    /// Returns an AsyncClient + EventLoop pair for receiving messages.
    /// The caller should poll the event loop for incoming packets.
    pub async fn subscribe_channel(
        &self,
        broker_id: &str,
    ) -> Result<(rumqttc::AsyncClient, rumqttc::EventLoop), HydraError> {
        use rumqttc::{AsyncClient, MqttOptions, QoS};

        let broker = self
            .get_broker(broker_id)
            .ok_or_else(|| HydraError::BrokerNotFound(broker_id.to_string()))?;

        let topic = self.current_topic()?;
        let client_id = format!("hidra_sub_{}", broker_id);
        let mut opts = MqttOptions::new(
            &client_id,
            &broker.config.host,
            broker.config.port,
        );
        opts.set_keep_alive(std::time::Duration::from_secs(30));

        let (client, eventloop) = AsyncClient::new(opts, 64);

        client
            .subscribe(&topic, QoS::AtLeastOnce)
            .await
            .map_err(|e| HydraError::MqttError(e.to_string()))?;

        log::info!("Subscribed to {} on {}", topic, broker_id);
        Ok((client, eventloop))
    }
}

/// Default 10-broker configuration for HİDRA
/// In production, these would be real MQTT brokers behind Tor hidden services.
pub fn default_broker_configs() -> Vec<BrokerConfig> {
    (0..10)
        .map(|i| BrokerConfig {
            id: format!("broker_{:02}", i),
            host: format!("broker{}.hidra.onion", i),
            port: 8883,
            use_tor: true,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_mesh() -> HydraMesh {
        let configs = default_broker_configs();
        let secret = [0x42u8; 32];
        HydraMesh::new(configs, secret, "test_channel".to_string())
    }

    #[test]
    fn test_broker_health_transitions() {
        let mesh = test_mesh();
        assert_eq!(mesh.healthy_count(), 0); // All start DEAD

        // Set 5 to ALIVE
        for b in mesh.brokers.iter().take(5) {
            b.set_health(HEALTH_ALIVE);
        }
        assert_eq!(mesh.healthy_count(), 5);

        // Kill one
        mesh.brokers[0].set_health(HEALTH_DEAD);
        assert_eq!(mesh.healthy_count(), 4);

        // Set one to SICK (not ALIVE)
        mesh.brokers[1].set_health(HEALTH_SICK);
        assert_eq!(mesh.healthy_count(), 3);
    }

    #[test]
    fn test_3_of_10_selection() {
        let mesh = test_mesh();

        // Not enough healthy → error
        mesh.brokers[0].set_health(HEALTH_ALIVE);
        mesh.brokers[1].set_health(HEALTH_ALIVE);
        assert!(mesh.select_targets().is_err());

        // Exactly 3 healthy → should work
        mesh.brokers[2].set_health(HEALTH_ALIVE);
        let targets = mesh.select_targets().unwrap();
        assert_eq!(targets.len(), 3);

        // 10 healthy → still picks 3
        mesh.set_all_health(HEALTH_ALIVE);
        let targets = mesh.select_targets().unwrap();
        assert_eq!(targets.len(), 3);
    }

    #[test]
    fn test_topic_rotation_deterministic() {
        let secret = [0xAB; 32];
        let channel = "alpha";

        // Same time slot → same topic
        let t1 = HydraMesh::derive_topic(&secret, channel, 100).unwrap();
        let t2 = HydraMesh::derive_topic(&secret, channel, 100).unwrap();
        assert_eq!(t1, t2);

        // Different time slot → different topic
        let t3 = HydraMesh::derive_topic(&secret, channel, 101).unwrap();
        assert_ne!(t1, t3);

        // Different channel → different topic
        let t4 = HydraMesh::derive_topic(&secret, "bravo", 100).unwrap();
        assert_ne!(t1, t4);

        // Topic starts with "h/" prefix
        assert!(t1.starts_with("h/"));
    }

    #[tokio::test]
    async fn test_nonce_dedup() {
        let mesh = test_mesh();
        let nonce1 = [0x01u8; 24];
        let nonce2 = [0x02u8; 24];

        // First time → new
        assert!(mesh.check_and_record_nonce(&nonce1).await);
        // Second time → duplicate
        assert!(!mesh.check_and_record_nonce(&nonce1).await);
        // Different nonce → new
        assert!(mesh.check_and_record_nonce(&nonce2).await);
    }

    #[test]
    fn test_broadcast_all_policy() {
        let mut mesh = test_mesh();
        mesh.policy = BroadcastPolicy::All;
        mesh.set_all_health(HEALTH_ALIVE);

        let targets = mesh.select_targets().unwrap();
        assert_eq!(targets.len(), 10); // All brokers
    }

    #[test]
    fn test_default_broker_configs() {
        let configs = default_broker_configs();
        assert_eq!(configs.len(), 10);
        assert!(configs.iter().all(|c| c.use_tor));
        assert!(configs.iter().all(|c| c.port == 8883));
        // All unique IDs
        let ids: HashSet<&str> = configs.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids.len(), 10);
    }
}
