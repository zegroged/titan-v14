//! ★ B5: Canary Trap Messages — Leak Detection Watermarks
//!
//! Injects invisible steganographic fingerprints into outgoing messages.
//! Each recipient gets a unique watermark derived from their identity.
//! If a message leaks, the watermark identifies the source.
//!
//! # Mechanism
//! 1. Derive per-recipient canary seed from HMAC(master_secret, recipient_id)
//! 2. Use seed to select invisible Unicode characters (zero-width spaces/joiners)
//! 3. Insert at deterministic positions in the plaintext
//! 4. Verify by extracting and comparing against expected fingerprint
//!
//! # Properties
//! - Invisible: Zero-width characters are not displayed
//! - Unique: Each recipient gets a different fingerprint
//! - Verifiable: Can extract and identify the leaker
//! - Fragile: Copy-paste often preserves zero-width chars

use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

/// Zero-width Unicode characters used for embedding
const ZW_SPACE: char = '\u{200B}';     // Zero-Width Space
const ZW_JOINER: char = '\u{200D}';    // Zero-Width Joiner
const ZW_NON_JOINER: char = '\u{200C}'; // Zero-Width Non-Joiner

/// Maximum canary bits to embed (keeps message size reasonable)
const MAX_CANARY_BITS: usize = 32;

/// Derive a canary fingerprint for a specific recipient
///
/// # Arguments
/// - `master_secret`: Shared secret for canary derivation
/// - `recipient_id`: Unique identifier for the recipient
///
/// # Returns
/// 32-bit fingerprint unique to this recipient
pub fn derive_fingerprint(master_secret: &[u8; 32], recipient_id: &[u8]) -> u32 {
    let mut mac = HmacSha256::new_from_slice(master_secret)
        .expect("HMAC key invalid");
    mac.update(b"HIDRA-CANARY-TRAP-V1:");
    mac.update(recipient_id);
    let result = mac.finalize().into_bytes();

    // First 4 bytes as u32
    u32::from_le_bytes([result[0], result[1], result[2], result[3]])
}

/// Embed a canary fingerprint into a text message
///
/// Inserts zero-width Unicode characters at deterministic positions
/// to encode the fingerprint bits.
///
/// # Arguments
/// - `text`: Original plaintext message
/// - `fingerprint`: 32-bit canary fingerprint
///
/// # Returns
/// Message with embedded canary (visually identical to original)
pub fn embed_canary(text: &str, fingerprint: u32) -> String {
    if text.is_empty() {
        return text.to_string();
    }

    let chars: Vec<char> = text.chars().collect();
    let bits_to_embed = MAX_CANARY_BITS.min(chars.len().saturating_sub(1));

    let mut result = String::with_capacity(text.len() + bits_to_embed * 3);

    for (i, ch) in chars.iter().enumerate() {
        result.push(*ch);

        // Embed one bit after each of the first N characters
        if i < bits_to_embed {
            let bit = (fingerprint >> i) & 1;
            if bit == 1 {
                result.push(ZW_JOINER);
            } else {
                result.push(ZW_SPACE);
            }
        }
    }

    result
}

/// Extract a canary fingerprint from a watermarked message
///
/// # Returns
/// The extracted fingerprint, or `None` if no canary detected
pub fn extract_canary(text: &str) -> Option<u32> {
    let mut fingerprint: u32 = 0;
    let mut bit_pos = 0;
    let mut found_any = false;

    for ch in text.chars() {
        let bit = match ch {
            c if c == ZW_SPACE => Some(0u32),
            c if c == ZW_JOINER => Some(1u32),
            c if c == ZW_NON_JOINER => continue, // Skip non-joiner
            _ => None,
        };

        if let Some(b) = bit {
            found_any = true;
            if bit_pos < 32 {
                fingerprint |= b << bit_pos;
                bit_pos += 1;
            }
        }
    }

    if found_any {
        Some(fingerprint)
    } else {
        None
    }
}

/// Verify if a message was leaked by a specific recipient
///
/// # Arguments
/// - `leaked_text`: The leaked message with a potentially embedded canary
/// - `master_secret`: The shared canary secret
/// - `suspect_id`: The suspected leaker's identity
///
/// # Returns
/// `true` if the canary matches the suspect's fingerprint
pub fn verify_leaker(
    leaked_text: &str,
    master_secret: &[u8; 32],
    suspect_id: &[u8],
) -> bool {
    let expected = derive_fingerprint(master_secret, suspect_id);
    match extract_canary(leaked_text) {
        // ★ Constant-time: prevents timing enumeration of recipients
        Some(extracted) => crate::constant_time::ct_u32_eq(extracted, expected),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fingerprint_unique_per_recipient() {
        let secret = [0x42u8; 32];
        let fp1 = derive_fingerprint(&secret, b"alice");
        let fp2 = derive_fingerprint(&secret, b"bob");
        let fp3 = derive_fingerprint(&secret, b"charlie");
        assert_ne!(fp1, fp2);
        assert_ne!(fp2, fp3);
        assert_ne!(fp1, fp3);
    }

    #[test]
    fn test_fingerprint_deterministic() {
        let secret = [0x42u8; 32];
        let fp1 = derive_fingerprint(&secret, b"alice");
        let fp2 = derive_fingerprint(&secret, b"alice");
        assert_eq!(fp1, fp2);
    }

    #[test]
    fn test_embed_extract_roundtrip() {
        let secret = [0x42u8; 32];
        let fp = derive_fingerprint(&secret, b"alice");
        let original = "This is a secret message for leak detection";
        let watermarked = embed_canary(original, fp);
        let extracted = extract_canary(&watermarked).unwrap();
        assert_eq!(extracted, fp);
    }

    #[test]
    fn test_canary_invisible() {
        let fp = 0xDEADBEEF;
        let original = "Hello World";
        let watermarked = embed_canary(original, fp);
        // Visual characters should be the same
        let visible: String = watermarked.chars()
            .filter(|c| *c != ZW_SPACE && *c != ZW_JOINER && *c != ZW_NON_JOINER)
            .collect();
        assert_eq!(visible, original);
    }

    #[test]
    fn test_verify_leaker() {
        let secret = [0x42u8; 32];
        let original = "Top secret: the coordinates are 40.7128 N, 74.0060 W";
        let alice_fp = derive_fingerprint(&secret, b"alice");
        let watermarked = embed_canary(original, alice_fp);
        assert!(verify_leaker(&watermarked, &secret, b"alice"));
        assert!(!verify_leaker(&watermarked, &secret, b"bob"));
    }

    #[test]
    fn test_no_canary_in_clean_text() {
        assert!(extract_canary("Clean text with no watermark").is_none());
    }

    #[test]
    fn test_different_recipients_different_watermarks() {
        let secret = [0x42u8; 32];
        let msg = "Same message sent to both Alice and Bob";
        let alice_wm = embed_canary(msg, derive_fingerprint(&secret, b"alice"));
        let bob_wm = embed_canary(msg, derive_fingerprint(&secret, b"bob"));
        // Different watermarks
        assert_ne!(alice_wm, bob_wm);
        // But same visible content
        let clean_a: String = alice_wm.chars()
            .filter(|c| *c != ZW_SPACE && *c != ZW_JOINER)
            .collect();
        let clean_b: String = bob_wm.chars()
            .filter(|c| *c != ZW_SPACE && *c != ZW_JOINER)
            .collect();
        assert_eq!(clean_a, clean_b);
    }
}
