//! ★ Integration Tests — Full Pipeline End-to-End Verification
//!
//! These tests exercise the COMPLETE encryption pipeline across all layers,
//! including key exchange → ratchet → encrypt → decrypt.
//!
//! # Trust No One Philosophy:
//! - Each test independently verifies the full stack
//! - Tests run in simulation mode (TITAN_SIM=1)
//! - Cross-instance tests verify key symmetry

use hidra_core::crypto::{Layer1Cipher, Layer1Envelope};
use hidra_core::transport_crypto::{TransportCipher, TransportEnvelope};
use hidra_core::titan_spi::{TitanBridge, TitanSpiConfig};
use hidra_core::ratchet::{DoubleRatchet, SendRatchet, RecvRatchet};
use hidra_core::key_exchange::{AliceKeyExchange, BobKeyExchange};
use hidra_core::protocol::{HlpPacket, HlpCommand, SequenceValidator};
use hidra_core::constant_time;

// ============================================================================
// Full Pipeline Tests
// ============================================================================

#[test]
fn test_full_pipeline_layer1_layer2_layer3() {
    // ★ Complete triple-layer encryption roundtrip
    std::env::set_var("TITAN_SIM", "1");

    let plaintext = b"Kimseye Guvenme - Trust No One - Full Pipeline Test";

    // Layer 1: AES-256-GCM-SIV
    let l1_cipher = Layer1Cipher::generate();
    let l1_envelope = l1_cipher.encrypt(plaintext).unwrap();
    let l1_bytes = l1_envelope.to_bytes();

    // Layer 2: TITAN FPGA (AES-256-CTR in sim mode)
    let mut bridge = TitanBridge::new(TitanSpiConfig::default());
    bridge.connect().unwrap();
    let l2_ciphertext = bridge.encrypt(&l1_bytes).unwrap();

    // Layer 3: XChaCha20-Poly1305
    let l3_cipher = TransportCipher::generate();
    let l3_envelope = l3_cipher.encrypt(&l2_ciphertext).unwrap();
    let l3_bytes = l3_envelope.to_bytes();

    // ═══ REVERSE: Decrypt all layers ═══

    // Layer 3 decrypt
    let l3_recovered = TransportEnvelope::from_bytes(&l3_bytes).unwrap();
    let l2_recovered = l3_cipher.decrypt(&l3_recovered).unwrap();

    // Layer 2 decrypt
    let l1_recovered = bridge.decrypt(&l2_recovered).unwrap();

    // Layer 1 decrypt
    let l1_env_recovered = Layer1Envelope::from_bytes(&l1_recovered).unwrap();
    let recovered_plaintext = l1_cipher.decrypt(&l1_env_recovered).unwrap();

    assert_eq!(plaintext.as_slice(), recovered_plaintext.as_slice(),
        "Full pipeline roundtrip FAILED — data corruption detected!");

    std::env::remove_var("TITAN_SIM");
}

#[test]
fn test_key_exchange_to_ratchet_pipeline() {
    // ★ Full key exchange → derive session keys → ratchet → encrypt
    let alice_ke = AliceKeyExchange::new();
    let init_msg = alice_ke.get_init_message();
    let (bob_response, bob_keys) = BobKeyExchange::respond(&init_msg).unwrap();
    let alice_keys = alice_ke.complete(&bob_response).unwrap();

    // Verify both sides derive identical keys
    assert_eq!(alice_keys.layer1_key, bob_keys.layer1_key);
    assert_eq!(alice_keys.layer3_key, bob_keys.layer3_key);
    assert_eq!(alice_keys.ratchet_root, bob_keys.ratchet_root);

    // Use ratchet root key for symmetric ratcheting
    let mut sender = SendRatchet::new(&alice_keys.ratchet_root);
    let mut receiver = RecvRatchet::new(&alice_keys.ratchet_root);

    // Send 10 messages through ratchet → encrypt with Layer1
    for i in 0..10u64 {
        let mk = sender.next_key().unwrap();
        let recv_mk = receiver.key_for(i).unwrap();
        assert_eq!(mk.encryption_key, recv_mk.encryption_key,
            "Ratchet symmetry broken at message {}", i);

        // Encrypt a message using the derived key
        let msg = format!("Message {} from key exchange pipeline", i);
        let cipher = Layer1Cipher::new(&mk.encryption_key);
        let envelope = cipher.encrypt(msg.as_bytes()).unwrap();
        let decrypted = cipher.decrypt(&envelope).unwrap();
        assert_eq!(msg.as_bytes(), decrypted.as_slice());
    }
}

#[test]
fn test_double_ratchet_full_conversation() {
    // ★ Full DH ratchet conversation: Alice and Bob exchange 20 messages
    // with direction changes triggering DH ratchet steps
    let root_key = [0x42u8; 32];
    let (mut bob, bob_pub) = DoubleRatchet::init_bob(&root_key);
    let mut alice = DoubleRatchet::init_alice(&root_key, &bob_pub);

    // Simulate a real conversation
    for round in 0..10 {
        // Alice sends
        let (header_a, mk_a) = alice.ratchet_encrypt().unwrap();
        let msg_a = format!("Alice round {}", round);
        let cipher_a = Layer1Cipher::new(&mk_a.encryption_key);
        let envelope_a = cipher_a.encrypt(msg_a.as_bytes()).unwrap();

        // Bob decrypts
        let mk_b = bob.ratchet_decrypt(&header_a).unwrap();
        let cipher_b = Layer1Cipher::new(&mk_b.encryption_key);
        let decrypted_a = cipher_b.decrypt(&envelope_a).unwrap();
        assert_eq!(msg_a.as_bytes(), decrypted_a.as_slice());

        // Bob sends
        let (header_b, mk_b2) = bob.ratchet_encrypt().unwrap();
        let msg_b = format!("Bob round {}", round);
        let cipher_b2 = Layer1Cipher::new(&mk_b2.encryption_key);
        let envelope_b = cipher_b2.encrypt(msg_b.as_bytes()).unwrap();

        // Alice decrypts
        let mk_a2 = alice.ratchet_decrypt(&header_b).unwrap();
        let cipher_a2 = Layer1Cipher::new(&mk_a2.encryption_key);
        let decrypted_b = cipher_a2.decrypt(&envelope_b).unwrap();
        assert_eq!(msg_b.as_bytes(), decrypted_b.as_slice());
    }
}

// ============================================================================
// HLP Protocol Robustness Tests
// ============================================================================

#[test]
fn test_hlp_packet_truncated_header() {
    // ★ Negative: packet shorter than minimum header
    let too_short = vec![0x01, 0x00]; // Only 2 bytes, need 9 minimum
    let result = HlpPacket::from_bytes(&too_short);
    assert!(result.is_err());
}

#[test]
fn test_hlp_packet_zero_length() {
    // ★ Zero-length payload is valid
    let packet = HlpPacket::new(HlpCommand::StatusRequest, 0, vec![]);
    let bytes = packet.to_bytes();
    let recovered = HlpPacket::from_bytes(&bytes).unwrap();
    assert_eq!(recovered.payload.len(), 0);
    assert_eq!(recovered.command, HlpCommand::StatusRequest);
}

#[test]
fn test_hlp_packet_max_size_payload() {
    // ★ Maximum payload size
    let max_payload = vec![0xAA; 4096];
    let packet = HlpPacket::new(HlpCommand::EncryptRequest, 1, max_payload.clone());
    let bytes = packet.to_bytes();
    let recovered = HlpPacket::from_bytes(&bytes).unwrap();
    assert_eq!(recovered.payload, max_payload);
}

#[test]
fn test_sequence_validator_stress_100k() {
    // ★ Stress: 100K sequential packets (fast enough for CI)
    let mut v = SequenceValidator::new();
    for i in 0..100_000u32 {
        assert!(v.validate(i).is_ok(), "Failed at sequence {}", i);
    }
    let (accepted, rejected) = v.stats();
    assert_eq!(accepted, 100_000);
    assert_eq!(rejected, 0);
}

#[test]
fn test_sequence_validator_window_boundary() {
    // ★ Edge case: packets exactly at window boundary
    let mut v = SequenceValidator::new();
    v.validate(0).unwrap();
    v.validate(64).unwrap(); // Jump exactly window size

    // seq 0 is now exactly 64 old → should be rejected (window is exclusive)
    assert!(v.validate(0).is_err());
    // seq 1 is 63 old → should be accepted (within window)
    assert!(v.validate(1).is_ok());
}

// ============================================================================
// Constant-Time Verification
// ============================================================================

#[test]
fn test_ct_eq_large_buffer() {
    // ★ Stress: Large buffer comparison
    let a = vec![0x42u8; 65536];
    let b = vec![0x42u8; 65536];
    assert!(constant_time::ct_eq(&a, &b));

    let mut c = b.clone();
    c[65535] ^= 1; // Last byte different
    assert!(!constant_time::ct_eq(&a, &c));
}

#[test]
fn test_ct_u32_edge_cases() {
    // ★ Edge cases for u32 comparison
    assert!(constant_time::ct_u32_eq(u32::MAX, u32::MAX));
    assert!(constant_time::ct_u32_eq(u32::MIN, u32::MIN));
    assert!(!constant_time::ct_u32_eq(u32::MAX, u32::MIN));
    assert!(!constant_time::ct_u32_eq(0x80000000, 0x7FFFFFFF)); // Sign boundary
}

// ============================================================================
// Crypto Layer Negative Tests
// ============================================================================

#[test]
fn test_layer1_empty_plaintext() {
    // ★ Empty plaintext should still encrypt/decrypt correctly
    let cipher = Layer1Cipher::generate();
    let envelope = cipher.encrypt(b"").unwrap();
    let decrypted = cipher.decrypt(&envelope).unwrap();
    assert_eq!(decrypted, b"");
}

#[test]
fn test_layer1_truncated_envelope() {
    // ★ Negative: truncated envelope should fail
    let cipher = Layer1Cipher::generate();
    let envelope = cipher.encrypt(b"test").unwrap();
    let bytes = envelope.to_bytes();

    // Truncate to just the nonce
    let result = Layer1Envelope::from_bytes(&bytes[..12]);
    assert!(result.is_err());
}

#[test]
fn test_layer3_tampered_ciphertext() {
    // ★ Negative: tampered Layer 3 ciphertext
    let cipher = TransportCipher::generate();
    let mut envelope = cipher.encrypt(b"tamper test L3").unwrap();
    envelope.ciphertext[0] ^= 0xFF;
    let result = cipher.decrypt(&envelope);
    assert!(result.is_err());
}

// ============================================================================
// TITAN SPI Edge Cases
// ============================================================================

#[test]
fn test_titan_bridge_not_connected() {
    // ★ Negative: operations before connect() should fail
    std::env::set_var("TITAN_SIM", "1");
    let mut bridge = TitanBridge::new(TitanSpiConfig::default());
    // Don't call connect()
    let result = bridge.encrypt(b"test");
    assert!(result.is_err());
    std::env::remove_var("TITAN_SIM");
}

#[test]
fn test_titan_sim_multiple_operations() {
    // ★ Stress: Sequential encrypt/decrypt operations
    std::env::set_var("TITAN_SIM", "1");
    let mut bridge = TitanBridge::new(TitanSpiConfig::default());
    bridge.connect().unwrap();

    for i in 0..100 {
        let data = format!("Message {}", i);
        let encrypted = bridge.encrypt(data.as_bytes()).unwrap();
        let decrypted = bridge.decrypt(&encrypted).unwrap();
        assert_eq!(data.as_bytes(), decrypted.as_slice());
    }
    std::env::remove_var("TITAN_SIM");
}

// ============================================================================
// ★ Item 9: Concurrency Tests — Thread Safety
// ============================================================================

#[test]
fn test_concurrent_layer1_encryption() {
    // ★ Verify Layer1Cipher is safe to use across threads (Send + Sync)
    // Each thread gets its own cipher and encrypts 50 messages
    use std::sync::Arc;
    use std::thread;

    let plaintext = Arc::new(b"Trust No One - Concurrent Test".to_vec());
    let mut handles = vec![];

    for t in 0..8 {
        let pt = Arc::clone(&plaintext);
        handles.push(thread::spawn(move || {
            let cipher = Layer1Cipher::generate();
            for i in 0..50 {
                let msg = format!("Thread {} Message {}", t, i);
                let envelope = cipher.encrypt(msg.as_bytes())
                    .expect("Encryption failed in thread");
                let decrypted = cipher.decrypt(&envelope)
                    .expect("Decryption failed in thread");
                assert_eq!(msg.as_bytes(), decrypted.as_slice(),
                    "Roundtrip failure in thread {} msg {}", t, i);
            }
            // Also test with shared plaintext
            let envelope = cipher.encrypt(&pt)
                .expect("Shared plaintext encryption failed");
            let decrypted = cipher.decrypt(&envelope)
                .expect("Shared plaintext decryption failed");
            assert_eq!(pt.as_slice(), decrypted.as_slice());
        }));
    }

    for h in handles {
        h.join().expect("Thread panicked!");
    }
}

#[test]
fn test_concurrent_nonce_uniqueness() {
    // ★ Verify that nonces are unique even across concurrent threads
    use std::sync::{Arc, Mutex};
    use std::thread;

    let all_nonces: Arc<Mutex<Vec<Vec<u8>>>> = Arc::new(Mutex::new(Vec::new()));
    let mut handles = vec![];

    for _ in 0..8 {
        let nonces = Arc::clone(&all_nonces);
        handles.push(thread::spawn(move || {
            let cipher = Layer1Cipher::generate();
            let mut local_nonces = Vec::new();
            for _ in 0..100 {
                let envelope = cipher.encrypt(b"nonce test").unwrap();
                local_nonces.push(envelope.nonce.to_vec());
            }
            nonces.lock().unwrap().extend(local_nonces);
        }));
    }

    for h in handles {
        h.join().expect("Thread panicked!");
    }

    // Verify all 800 nonces are unique
    let nonces = all_nonces.lock().unwrap();
    assert_eq!(nonces.len(), 800);
    let mut sorted = nonces.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(sorted.len(), 800, "Nonce collision detected across threads!");
}

#[test]
fn test_concurrent_transport_crypto() {
    // ★ Verify TransportCipher is thread-safe
    use std::thread;

    let mut handles = vec![];
    for t in 0..4 {
        handles.push(thread::spawn(move || {
            let cipher = TransportCipher::generate();
            for i in 0..50 {
                let msg = format!("Transport thread {} msg {}", t, i);
                let envelope = cipher.encrypt(msg.as_bytes())
                    .expect("L3 encryption failed");
                let decrypted = cipher.decrypt(&envelope)
                    .expect("L3 decryption failed");
                assert_eq!(msg.as_bytes(), decrypted.as_slice());
            }
        }));
    }

    for h in handles {
        h.join().expect("Thread panicked!");
    }
}

// ============================================================================
// ★ Item 7: Fuzz-like Parsing Hardening Tests
// (Full cargo-fuzz requires nightly; these exercise the same code paths)
// ============================================================================

#[test]
fn test_fuzz_hlp_packet_random_bytes() {
    // ★ Feed pseudorandom garbage to HlpPacket::from_bytes()
    // Must never panic, only return Err
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    for seed in 0..10_000u64 {
        let mut hasher = DefaultHasher::new();
        seed.hash(&mut hasher);
        let h = hasher.finish();
        let len = (h % 256) as usize;
        let bytes: Vec<u8> = (0..len).map(|i| {
            let mut h2 = DefaultHasher::new();
            (seed, i).hash(&mut h2);
            h2.finish() as u8
        }).collect();
        // Must not panic
        let _ = HlpPacket::from_bytes(&bytes);
    }
}

#[test]
fn test_fuzz_layer1_envelope_random_bytes() {
    // ★ Feed garbage to Layer1Envelope::from_bytes()
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    for seed in 0..5_000u64 {
        let mut hasher = DefaultHasher::new();
        seed.hash(&mut hasher);
        let h = hasher.finish();
        let len = (h % 512) as usize;
        let bytes: Vec<u8> = (0..len).map(|i| {
            let mut h2 = DefaultHasher::new();
            (seed, i).hash(&mut h2);
            h2.finish() as u8
        }).collect();
        let _ = Layer1Envelope::from_bytes(&bytes);
    }
}

#[test]
fn test_fuzz_transport_envelope_random_bytes() {
    // ★ Feed garbage to TransportEnvelope::from_bytes()
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    for seed in 0..5_000u64 {
        let mut hasher = DefaultHasher::new();
        seed.hash(&mut hasher);
        let h = hasher.finish();
        let len = (h % 512) as usize;
        let bytes: Vec<u8> = (0..len).map(|i| {
            let mut h2 = DefaultHasher::new();
            (seed, i).hash(&mut h2);
            h2.finish() as u8
        }).collect();
        let _ = TransportEnvelope::from_bytes(&bytes);
    }
}
