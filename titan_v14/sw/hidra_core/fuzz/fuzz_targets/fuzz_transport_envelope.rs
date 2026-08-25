#![no_main]
//! Fuzz target: TransportEnvelope::from_bytes()
//! Exercises XChaCha20-Poly1305 envelope parsing with arbitrary byte sequences.
//! Run: cargo +nightly fuzz run fuzz_transport_envelope

use libfuzzer_sys::fuzz_target;
use hidra_core::transport_crypto::TransportEnvelope;

fuzz_target!(|data: &[u8]| {
    let _ = TransportEnvelope::from_bytes(data);
});
