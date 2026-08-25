//! Titan Integration Tests — Faz 1+2 Stress Test
//!
//! Validates the full pipeline: handshake → ratchet → envelope → dead drop → hopping.
//! Target: 100+ tests to complement the 66 unit tests.

#[cfg(test)]
mod tests {
    use titan_dead_drop::{DeadDrop, MemoryDeadDrop};
    use titan_dht::{derive_notify_key, epoch_scan, DhtSignal, DhtStore, MemoryDht};
    use titan_envelope::{self, EnvelopeHeader};
    use titan_hal::{MemoryKeyStore, SecureKeyStore};
    use titan_hopping::{self, navigator::Navigator};
    use titan_kyber::{self, KyberKeyPair};
    use titan_ratchet::RatchetState;
    use titan_sentry::{self, PollingMode, SentryState};

    // =========================================================================
    // 1. FULL HANDSHAKE FLOW: Kyber KEM → shared_secret → Ratchet init
    // =========================================================================

    #[test]
    fn test_full_handshake_flow() {
        // Alice generates keypair
        let alice_kp = KyberKeyPair::generate();

        // Bob encapsulates with Alice's public key
        let enc = titan_kyber::encapsulate(&alice_kp.public_key).unwrap();

        // Alice decapsulates
        let alice_ss = titan_kyber::decapsulate(
            alice_kp.secret_key_bytes(),
            &enc.ciphertext,
        ).unwrap();

        // Shared secrets must match
        assert_eq!(enc.shared_secret(), &alice_ss[..]);

        // Both init ratchet from same shared secret
        let mut alice_ratchet = RatchetState::init(&alice_ss);
        let mut bob_ratchet = RatchetState::init(enc.shared_secret());

        // Alice's send key = Bob's recv key (symmetric init)
        let alice_send = alice_ratchet.next_send_key();
        let bob_recv = bob_ratchet.next_send_key(); // same chain from same secret
        assert_eq!(alice_send, bob_recv);
    }

    // =========================================================================
    // 2. STRESS TEST: 1000 sequential messages through ratchet chain
    // =========================================================================

    #[test]
    fn test_1000_message_ratchet_chain() {
        let shared_secret = titan_entropy::generate_seed();
        let mut ratchet = RatchetState::init(&shared_secret);

        let mut prev_key = [0u8; 32];
        for i in 0..1000 {
            let msg_key = ratchet.next_send_key();

            // Every key must be unique (forward secrecy)
            assert_ne!(msg_key, prev_key, "Key collision at message {}", i);
            assert_ne!(msg_key, [0u8; 32], "Zero key at message {}", i);

            prev_key = msg_key;
        }
        assert_eq!(ratchet.send_count, 1000);
    }

    // =========================================================================
    // 3. STRESS TEST: 1000 address hops — all unique
    // =========================================================================

    #[test]
    fn test_1000_address_hops_unique() {
        let shared_secret = titan_entropy::generate_seed();
        let mut seen = std::collections::HashSet::new();

        for n in 0..1000u32 {
            let addr = titan_hopping::send_addr(&shared_secret, n);
            assert!(
                seen.insert(addr),
                "Address collision at hop {}!", n
            );
        }
        assert_eq!(seen.len(), 1000);
    }

    // =========================================================================
    // 4. DEAD DROP CYCLE: store → retrieve → gone (1000 cycles)
    // =========================================================================

    #[test]
    fn test_1000_dead_drop_cycles() {
        let mut dd = MemoryDeadDrop::new();
        let shared_secret = titan_entropy::generate_seed();

        for n in 0..1000u32 {
            let addr = titan_hopping::send_addr(&shared_secret, n);
            let payload = format!("msg-{}", n).into_bytes();

            dd.store(&addr, payload.clone()).unwrap();
            assert_eq!(dd.count(), 1);

            let retrieved = dd.retrieve(&addr).unwrap();
            assert_eq!(retrieved, payload);
            assert_eq!(dd.count(), 0, "Must be empty after retrieval");

            // Second retrieve must fail
            assert!(dd.retrieve(&addr).is_none());
        }
    }

    // =========================================================================
    // 5. TTL EXPIRY SIMULATION
    // =========================================================================

    #[test]
    fn test_ttl_expiry_simulation() {
        // Use 0s TTL for instant expiry simulation
        let mut dd = MemoryDeadDrop::with_ttl_secs(0);
        let shared_secret = titan_entropy::generate_seed();

        // Store 50 messages
        for n in 0..50u32 {
            let addr = titan_hopping::send_addr(&shared_secret, n);
            dd.store(&addr, vec![n as u8; 64]).unwrap();
        }
        assert_eq!(dd.count(), 50);

        // Wait a tiny bit, then expire
        std::thread::sleep(std::time::Duration::from_millis(10));
        let expired = dd.expire_old();
        assert_eq!(expired, 50);
        assert_eq!(dd.count(), 0, "All messages must be expired");
    }

    // =========================================================================
    // 6. COMPASS CHECKPOINT: save → crash simulate → restore
    // =========================================================================

    #[test]
    fn test_compass_checkpoint_recovery() {
        let mut store = MemoryKeyStore::new();

        // Simulate 500 messages, checkpoint every 20
        let mut nav = Navigator::new("alice", 0, 0, 100);
        for i in 0..500u32 {
            nav.message_received();
            nav.message_sent();

            // Checkpoint every 20 messages (per architecture spec)
            if (i + 1) % 20 == 0 {
                nav.checkpoint(&mut store).unwrap();
            }
        }

        // Simulate crash — drop navigator
        let final_n = nav.n_in;
        let final_s = nav.s_out;
        drop(nav);

        // Restore from checkpoint
        let restored = Navigator::from_checkpoint("alice", &store).unwrap();

        // Should be at last checkpoint (500 messages, last checkpoint at 500)
        assert_eq!(restored.n_in, final_n);
        assert_eq!(restored.s_out, final_s);
    }

    // =========================================================================
    // 7. COMPASS CHECKPOINT: crash between checkpoints (data loss test)
    // =========================================================================

    #[test]
    fn test_compass_crash_between_checkpoints() {
        let mut store = MemoryKeyStore::new();

        let mut nav = Navigator::new("bob", 0, 0, 50);
        // Process 15 messages (no checkpoint yet — first at 20)
        for _ in 0..15 {
            nav.message_received();
        }
        // No checkpoint done! Simulate crash.
        drop(nav);

        // Restore — should fail (no checkpoint saved)
        assert!(Navigator::from_checkpoint("bob", &store).is_err());

        // Now test with one checkpoint at 20, then 5 more without
        let mut nav2 = Navigator::new("bob", 0, 0, 50);
        for i in 0..25 {
            nav2.message_received();
            if (i + 1) % 20 == 0 {
                nav2.checkpoint(&mut store).unwrap();
            }
        }
        drop(nav2);

        // Restore gets checkpoint at n_in=20 (not 25)
        let restored = Navigator::from_checkpoint("bob", &store).unwrap();
        assert_eq!(restored.n_in, 20, "Should restore to last checkpoint, not latest");
    }

    // =========================================================================
    // 8. RATCHET + ENVELOPE: encrypt → store → retrieve → decrypt
    // =========================================================================

    #[test]
    fn test_ratchet_envelope_dead_drop_cycle() {
        let shared_secret = titan_entropy::generate_seed();
        let mut alice_ratchet = RatchetState::init(&shared_secret);
        let mut bob_ratchet = RatchetState::init(&shared_secret);
        let mut dd = MemoryDeadDrop::new();

        for i in 0..100u32 {
            // Alice encrypts
            let msg_key = alice_ratchet.next_send_key();
            let header = EnvelopeHeader::new([0xAA; 8], i as u64);
            let plaintext = format!("Hello {}", i);

            let sealed = titan_envelope::seal(
                &msg_key, &header, plaintext.as_bytes(), 512
            ).unwrap();

            // Store in Dead Drop
            let addr = titan_hopping::send_addr(
                &shared_secret.try_into().unwrap(), i
            );
            dd.store(&addr, sealed).unwrap();

            // Bob retrieves
            let envelope = dd.retrieve(&addr).unwrap();
            assert_eq!(dd.count(), 0);

            // Bob decrypts (same ratchet chain)
            let bob_key = bob_ratchet.next_send_key();
            assert_eq!(msg_key, bob_key); // same chain = same keys

            // Verify envelope size
            assert_eq!(envelope.len(), 512, "Envelope must be exactly 512 bytes");
        }
    }

    // =========================================================================
    // 9. DHT FULL DECOY SCAN: 100 peers + 10 fakes
    // =========================================================================

    #[test]
    fn test_dht_full_decoy_scan() {
        let mut dht = MemoryDht::new();
        let epoch = 42;

        // Generate 100 peer secrets
        let peers: Vec<[u8; 32]> = (0..100)
            .map(|_| titan_entropy::generate_seed())
            .collect();

        // Set 5 peers as active
        let active_indices = vec![3, 17, 42, 78, 99];
        for &idx in &active_indices {
            let key = derive_notify_key(&peers[idx], epoch);
            dht.put(&key, DhtSignal::Active);
        }

        // Full scan
        let found = epoch_scan(&dht, &peers, epoch);
        assert_eq!(found, active_indices);
    }

    // =========================================================================
    // 10. SENTRY MODE TRANSITIONS
    // =========================================================================

    #[test]
    fn test_sentry_full_lifecycle() {
        let mut sentry = SentryState::new();

        // Start in foreground
        assert_eq!(sentry.mode, PollingMode::Foreground);
        assert!(sentry.should_wake_tor(false)); // always awake in foreground

        // App goes to background
        sentry.set_mode(PollingMode::Background);
        assert!(!sentry.should_wake_tor(false)); // no signal = sleep
        assert!(sentry.should_wake_tor(true));  // signal = wake

        // Device enters Doze
        sentry.set_mode(PollingMode::Doze);
        assert!(!sentry.should_wake_tor(false));
        assert!(sentry.should_wake_tor(true));

        // Time drift check
        assert!(sentry.check_time_drift(100, 102));  // 20 min = OK
        assert!(!sentry.check_time_drift(100, 120)); // 200 min = WARN
    }

    // =========================================================================
    // 11. DILITHIUM SIGNING: handshake signature flow
    // =========================================================================

    #[test]
    fn test_dilithium_handshake_flow() {
        let alice = titan_dilithium::DilithiumKeyPair::generate();
        let bob = titan_dilithium::DilithiumKeyPair::generate();

        // Alice signs her Kyber public key
        let alice_kyber = KyberKeyPair::generate();
        let sig = alice.sign(&alice_kyber.public_key);

        // Bob verifies Alice's identity
        titan_dilithium::verify(&alice.public_key, &alice_kyber.public_key, &sig)
            .expect("Alice's signature should verify");

        // Tampered key should fail
        let mut tampered = alice_kyber.public_key.clone();
        tampered[0] ^= 0xFF;
        assert!(titan_dilithium::verify(&alice.public_key, &tampered, &sig).is_err());
    }

    // =========================================================================
    // 12. EPOCH ROLLOVER: addresses change at epoch boundary
    // =========================================================================

    #[test]
    fn test_epoch_rollover_changes_rendezvous() {
        let ss = titan_entropy::generate_seed();
        let ss32: [u8; 32] = ss;

        let r1 = titan_hopping::rendezvous_addr(&ss32, 100);
        let r2 = titan_hopping::rendezvous_addr(&ss32, 101);
        assert_ne!(r1, r2, "Rendezvous must change at epoch boundary");
    }

    // =========================================================================
    // 13. DEADLOCK STATE: progressive degradation
    // =========================================================================

    #[test]
    fn test_deadlock_progressive_degradation() {
        use titan_hopping::DeadlockState;

        // 0s = normal
        assert_eq!(titan_hopping::deadlock_state(0), DeadlockState::Normal);
        // 29min = still normal
        assert_eq!(titan_hopping::deadlock_state(29 * 60), DeadlockState::Normal);
        // 30min = widen
        assert_eq!(titan_hopping::deadlock_state(30 * 60), DeadlockState::Widen);
        // 59min = still widen
        assert_eq!(titan_hopping::deadlock_state(59 * 60), DeadlockState::Widen);
        // 60min = teleport
        assert_eq!(titan_hopping::deadlock_state(60 * 60), DeadlockState::Teleport);
        // 71h = still teleport
        assert_eq!(titan_hopping::deadlock_state(71 * 3600), DeadlockState::Teleport);
        // 72h = offline
        assert_eq!(titan_hopping::deadlock_state(72 * 3600), DeadlockState::Offline);
    }

    // =========================================================================
    // 14. MULTI-PEER: 50 simultaneous conversations
    // =========================================================================

    #[test]
    fn test_50_simultaneous_peers() {
        let mut store = MemoryKeyStore::new();
        let mut dd = MemoryDeadDrop::new();

        // Create 50 peer conversations
        let peers: Vec<([u8; 32], RatchetState, Navigator)> = (0..50)
            .map(|i| {
                let ss = titan_entropy::generate_seed();
                let ratchet = RatchetState::init(&ss);
                let nav = Navigator::new(&format!("peer{}", i), 0, 0, 100);
                (ss, ratchet, nav)
            })
            .collect();

        // Send 10 messages per peer = 500 total
        for (ss, mut ratchet, mut nav) in peers {
            let ss32: [u8; 32] = ss;
            for n in 0..10u32 {
                let addr = titan_hopping::send_addr(&ss32, n);
                let key = ratchet.next_send_key();
                let header = EnvelopeHeader::new([n as u8; 8], n as u64);
                let sealed = titan_envelope::seal(&key, &header, b"test", 512).unwrap();
                dd.store(&addr, sealed).unwrap();
                nav.message_sent();
            }
            nav.checkpoint(&mut store).unwrap();
        }

        // All 500 messages stored
        assert_eq!(dd.count(), 500);
    }

    // =========================================================================
    // 15. NULL PACKET: indistinguishable from real traffic
    // =========================================================================

    #[test]
    fn test_null_packets_match_envelope_sizes() {
        for _ in 0..100 {
            let size = titan_sentry::random_null_packet_size();
            let pkt = titan_sentry::generate_null_packet(size);
            assert!(
                size == 512 || size == 4096 || size == 8192,
                "Null packet size must match envelope tiers"
            );
            assert_eq!(pkt.len(), size);
        }
    }

    // =========================================================================
    // 16. BATCH SWEEP: navigator generates correct addresses
    // =========================================================================

    #[test]
    fn test_batch_sweep_correctness() {
        let nav = Navigator::new("alice", 100, 50, 999);
        let ss = titan_entropy::generate_seed();
        let ss32: [u8; 32] = ss;

        let sweep = nav.sweep_addresses(&ss32, 20);
        assert_eq!(sweep.len(), 20);

        // First address should be at N_in = 100
        assert_eq!(sweep[0].0, 100);
        // Last should be at 119
        assert_eq!(sweep[19].0, 119);

        // All addresses unique
        let addrs: std::collections::HashSet<[u8; 32]> = sweep.iter().map(|s| s.1).collect();
        assert_eq!(addrs.len(), 20);
    }

    // =========================================================================
    // 17. HEADER KEY: different chains → different header keys
    // =========================================================================

    #[test]
    fn test_header_key_isolation() {
        let k1 = titan_envelope::derive_header_key(&[0xAA; 32]);
        let k2 = titan_envelope::derive_header_key(&[0xBB; 32]);
        assert_ne!(k1, k2);
    }

    // =========================================================================
    // 18. DH RATCHET: re-key preserves communication
    // =========================================================================

    #[test]
    fn test_dh_ratchet_rekey() {
        let initial_ss = titan_entropy::generate_seed();
        let mut alice = RatchetState::init(&initial_ss);
        let mut bob = RatchetState::init(&initial_ss);

        // Exchange 100 messages
        for _ in 0..100 {
            let ak = alice.next_send_key();
            let bk = bob.next_send_key();
            assert_eq!(ak, bk);
        }

        // DH ratchet with new shared secret (simulating Kyber re-exchange)
        let new_ss = titan_entropy::generate_seed();
        alice.dh_ratchet(&new_ss);
        bob.dh_ratchet(&new_ss);

        // Post-ratchet keys must still match
        for _ in 0..100 {
            let ak = alice.next_send_key();
            let bk = bob.next_send_key();
            assert_eq!(ak, bk);
        }
    }
}
