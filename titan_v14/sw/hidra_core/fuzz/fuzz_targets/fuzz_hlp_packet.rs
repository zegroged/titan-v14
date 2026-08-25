#![no_main]
//! Fuzz target: HlpPacket::from_bytes()
//! Exercises packet parsing with arbitrary byte sequences.
//! Run: cargo +nightly fuzz run fuzz_hlp_packet

use libfuzzer_sys::fuzz_target;
use hidra_core::protocol::HlpPacket;

fuzz_target!(|data: &[u8]| {
    // Must never panic — only Ok/Err
    let _ = HlpPacket::from_bytes(data);
});
