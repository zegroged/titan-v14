#![no_main]
//! Fuzz target: Layer1Envelope::from_bytes()
//! Exercises AES-GCM-SIV envelope parsing with arbitrary byte sequences.
//! Run: cargo +nightly fuzz run fuzz_layer1_envelope

use libfuzzer_sys::fuzz_target;
use hidra_core::crypto::Layer1Envelope;

fuzz_target!(|data: &[u8]| {
    let _ = Layer1Envelope::from_bytes(data);
});
