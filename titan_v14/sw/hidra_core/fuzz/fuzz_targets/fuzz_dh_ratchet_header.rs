#![no_main]
//! Fuzz target: DhRatchetHeader::from_bytes()
//! Exercises Double Ratchet header parsing with arbitrary byte sequences.
//! Run: cargo +nightly fuzz run fuzz_dh_ratchet_header

use libfuzzer_sys::fuzz_target;
use hidra_core::ratchet::DhRatchetHeader;

fuzz_target!(|data: &[u8]| {
    let _ = DhRatchetHeader::from_bytes(data);
});
