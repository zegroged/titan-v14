/// Real MQTT Broker Integration Test
///
/// Connects to test.mosquitto.org:1883 (public, free)
/// Tests: publish, subscribe, roundtrip message delivery
use hidra_net::hydra::{BrokerConfig, HydraMesh};
use rumqttc::{AsyncClient, MqttOptions, QoS, Event, Packet};
use std::time::Duration;
use rand::Rng;

#[tokio::main]
async fn main() {
    println!("╔══════════════════════════════════════════════════════════════╗");
    println!("║  HİDRA — Real MQTT Broker Integration Test                 ║");
    println!("║  Broker: test.mosquitto.org:1883 (public)                  ║");
    println!("╚══════════════════════════════════════════════════════════════╝");
    println!();

    let mut pass = 0u32;
    let mut fail = 0u32;

    // Unique topic to avoid collision with other users
    let unique_id: u32 = rand::thread_rng().gen();
    let topic = format!("hidra/test/{:08X}", unique_id);

    // ═══════ TEST 1: Basic MQTT Pub/Sub Roundtrip ═══════
    print!("[TEST 1/4] MQTT Pub/Sub Roundtrip...");
    match mqtt_roundtrip(&topic, b"Merhaba MQTT from HIDRA!").await {
        Ok(received) => {
            if received == b"Merhaba MQTT from HIDRA!" {
                println!(" ✅ PASS");
                println!("         Published + Received {} bytes via test.mosquitto.org", received.len());
                pass += 1;
            } else {
                println!(" ❌ FAIL (data mismatch)");
                fail += 1;
            }
        }
        Err(e) => {
            println!(" ❌ FAIL ({})", e);
            fail += 1;
        }
    }

    // ═══════ TEST 2: Hydra Topic Derivation (deterministic) ═══════
    print!("[TEST 2/4] HMAC-SHA256 Topic Derivation...");
    let secret = [0x42u8; 32];
    let t1 = HydraMesh::derive_topic(&secret, "test", 1000).unwrap();
    let t2 = HydraMesh::derive_topic(&secret, "test", 1000).unwrap();
    let t3 = HydraMesh::derive_topic(&secret, "test", 1001).unwrap();
    if t1 == t2 && t1 != t3 && t1.starts_with("h/") {
        println!(" ✅ PASS");
        println!("         Deterministic: ✅ | Time-rotating: ✅ | Prefix: h/");
        pass += 1;
    } else {
        println!(" ❌ FAIL");
        fail += 1;
    }

    // ═══════ TEST 3: Binary Payload via MQTT ═══════
    print!("[TEST 3/4] Binary Payload (256 random bytes)...");
    let mut payload = vec![0u8; 256];
    rand::thread_rng().fill(&mut payload[..]);
    let topic2 = format!("hidra/test/bin/{:08X}", unique_id);
    match mqtt_roundtrip(&topic2, &payload).await {
        Ok(received) => {
            if received == payload {
                println!(" ✅ PASS");
                println!("         256 random bytes: sent == received (bit-perfect)");
                pass += 1;
            } else {
                println!(" ❌ FAIL (data corruption)");
                fail += 1;
            }
        }
        Err(e) => {
            println!(" ❌ FAIL ({})", e);
            fail += 1;
        }
    }

    // ═══════ TEST 4: Hydra Mesh Broker Selection ═══════
    print!("[TEST 4/4] Hydra Mesh 3-of-10 Selection...");
    let configs: Vec<BrokerConfig> = (0..10).map(|i| BrokerConfig {
        id: format!("broker_{:02}", i),
        host: "test.mosquitto.org".to_string(),
        port: 1883,
        use_tor: false,
    }).collect();
    let mesh = HydraMesh::new(configs, [0xAB; 32], "test_chan".to_string());
    mesh.set_all_health(2); // HEALTH_ALIVE

    let targets = mesh.select_targets().unwrap();
    if targets.len() == 3 {
        let ids: Vec<String> = targets.iter().map(|b| b.config.id.clone()).collect();
        println!(" ✅ PASS");
        println!("         Selected 3/10: {:?}", ids);
        pass += 1;
    } else {
        println!(" ❌ FAIL (got {} targets)", targets.len());
        fail += 1;
    }

    // ═══════ SUMMARY ═══════
    println!();
    println!("════════════════════════════════════════════════════════");
    println!("  MQTT INTEGRATION: {}/{} PASSED", pass, pass + fail);
    if pass == pass + fail {
        println!("  🌐 Real network MQTT communication VERIFIED");
    }
    println!("════════════════════════════════════════════════════════");

    if fail > 0 { std::process::exit(1); }
}

/// Publish a message and subscribe to receive it back (roundtrip test)
async fn mqtt_roundtrip(topic: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
    let unique: u32 = rand::thread_rng().gen();
    let topic_owned = topic.to_string();
    let payload_owned = payload.to_vec();

    // --- Subscriber setup ---
    let sub_id = format!("hidra_sub_{:08X}", unique);
    let mut sub_opts = MqttOptions::new(&sub_id, "test.mosquitto.org", 1883);
    sub_opts.set_keep_alive(Duration::from_secs(30));
    sub_opts.set_clean_session(true);

    let (sub_client, mut sub_eventloop) = AsyncClient::new(sub_opts, 64);

    // Channels: data (received payload) + ready (SubAck confirmation)
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(8);
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel::<()>();
    let sub_topic = topic_owned.clone();

    let sub_handle = tokio::spawn(async move {
        let mut ready_tx = Some(ready_tx);
        loop {
            match sub_eventloop.poll().await {
                Ok(Event::Incoming(Packet::ConnAck(_))) => {
                    // Connected — subscribe now
                    if let Err(e) = sub_client.subscribe(&sub_topic, QoS::AtLeastOnce).await {
                        eprintln!("Sub error: {}", e);
                        break;
                    }
                }
                Ok(Event::Incoming(Packet::SubAck(_))) => {
                    // Signal that subscriber is ready
                    if let Some(tx) = ready_tx.take() {
                        let _ = tx.send(());
                    }
                }
                Ok(Event::Incoming(Packet::Publish(p))) => {
                    let _ = tx.send(p.payload.to_vec()).await;
                    break;
                }
                Ok(_) => continue,
                Err(e) => {
                    eprintln!("EventLoop error: {}", e);
                    break;
                }
            }
        }
    });

    // Wait for subscriber to be ready (SubAck), with timeout
    match tokio::time::timeout(Duration::from_secs(10), ready_rx).await {
        Ok(Ok(())) => {} // Subscriber ready
        Ok(Err(_)) => return Err("Subscriber channel dropped before SubAck".to_string()),
        Err(_) => {
            sub_handle.abort();
            return Err("Timeout waiting for subscriber SubAck (10s)".to_string());
        }
    }

    // Small delay to ensure broker has propagated subscription
    tokio::time::sleep(Duration::from_millis(200)).await;

    // --- Publisher ---
    let pub_id = format!("hidra_pub_{:08X}", unique);
    let mut pub_opts = MqttOptions::new(&pub_id, "test.mosquitto.org", 1883);
    pub_opts.set_keep_alive(Duration::from_secs(10));
    pub_opts.set_clean_session(true);

    let (pub_client, mut pub_eventloop) = AsyncClient::new(pub_opts, 16);

    let pub_handle = tokio::spawn(async move {
        loop {
            match pub_eventloop.poll().await {
                Ok(_) => continue,
                Err(_) => break,
            }
        }
    });

    // Give publisher event loop time to connect
    tokio::time::sleep(Duration::from_millis(500)).await;

    pub_client.publish(&topic_owned, QoS::AtLeastOnce, false, payload_owned)
        .await
        .map_err(|e| format!("Publish error: {}", e))?;

    // --- Wait for message (15s timeout) ---
    let result = tokio::time::timeout(Duration::from_secs(15), rx.recv()).await;

    let _ = pub_client.disconnect().await;
    pub_handle.abort();
    sub_handle.abort();

    match result {
        Ok(Some(data)) => Ok(data),
        Ok(None) => Err("Channel closed without message".to_string()),
        Err(_) => Err("Timeout: no message received in 15s".to_string()),
    }
}
