//! ★ C-5: Firmware Secure Boot Verification
//!
//! Provides integrity verification for firmware images loaded onto the
//! TITAN FPGA via the SPI bridge. Uses HMAC-SHA256 with a device-unique
//! key (derived from PUF or pre-provisioned) to verify firmware authenticity.
//!
//! Boot flow:
//!   1. Read firmware image from flash/SPI
//!   2. Compute HMAC-SHA256(device_key, firmware_bytes)  
//!   3. Compare against stored signature (constant-time)
//!   4. Only proceed to execution if signature matches

use sha2::Sha256;
use hmac::{Hmac, Mac};

type HmacSha256 = Hmac<Sha256>;

/// Firmware image metadata
pub struct FirmwareHeader {
    /// Firmware version (monotonic counter, prevents rollback)
    pub version: u32,
    /// Expected HMAC-SHA256 signature
    pub signature: [u8; 32],
    /// Minimum allowed version (anti-rollback)
    pub min_version: u32,
}

/// Verify firmware image integrity
///
/// Returns Ok(version) if the firmware is authentic, Err otherwise.
pub fn verify_firmware(
    device_key: &[u8; 32],
    header: &FirmwareHeader,
    firmware_bytes: &[u8],
) -> Result<u32, SecureBootError> {
    // 1. Anti-rollback check
    if header.version < header.min_version {
        return Err(SecureBootError::RollbackDetected {
            version: header.version,
            minimum: header.min_version,
        });
    }

    // 2. Compute HMAC-SHA256
    let mut mac = HmacSha256::new_from_slice(device_key)
        .map_err(|_| SecureBootError::KeyError)?;
    
    // Include version in MAC to bind signature to version
    mac.update(&header.version.to_be_bytes());
    mac.update(firmware_bytes);

    // 3. Constant-time comparison
    mac.verify_slice(&header.signature)
        .map_err(|_| SecureBootError::SignatureInvalid)?;

    Ok(header.version)
}

/// Compute firmware signature for signing (development tool)
pub fn sign_firmware(
    device_key: &[u8; 32],
    version: u32,
    firmware_bytes: &[u8],
) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(device_key)
        .expect("HMAC key length is valid");
    mac.update(&version.to_be_bytes());
    mac.update(firmware_bytes);
    
    let result = mac.finalize();
    let mut sig = [0u8; 32];
    sig.copy_from_slice(&result.into_bytes());
    sig
}

/// Secure boot error types
#[derive(Debug, Clone)]
pub enum SecureBootError {
    /// Firmware version is below minimum (rollback attack)
    RollbackDetected { version: u32, minimum: u32 },
    /// HMAC-SHA256 signature does not match
    SignatureInvalid,
    /// Device key is invalid
    KeyError,
}

impl std::fmt::Display for SecureBootError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RollbackDetected { version, minimum } =>
                write!(f, "Rollback detected: v{} < min v{}", version, minimum),
            Self::SignatureInvalid =>
                write!(f, "Firmware signature verification failed"),
            Self::KeyError =>
                write!(f, "Invalid device key"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sign_and_verify() {
        let key = [0x42u8; 32];
        let firmware = b"test firmware image data";
        let version = 5;

        let sig = sign_firmware(&key, version, firmware);
        let header = FirmwareHeader {
            version,
            signature: sig,
            min_version: 1,
        };

        assert!(verify_firmware(&key, &header, firmware).is_ok());
    }

    #[test]
    fn test_tampered_firmware() {
        let key = [0x42u8; 32];
        let firmware = b"test firmware image data";
        let version = 5;

        let sig = sign_firmware(&key, version, firmware);
        let header = FirmwareHeader {
            version,
            signature: sig,
            min_version: 1,
        };

        let tampered = b"test firmware TAMPERED data";
        assert!(matches!(
            verify_firmware(&key, &header, tampered),
            Err(SecureBootError::SignatureInvalid)
        ));
    }

    #[test]
    fn test_rollback_detection() {
        let key = [0x42u8; 32];
        let firmware = b"old firmware";
        let sig = sign_firmware(&key, 2, firmware);
        let header = FirmwareHeader {
            version: 2,
            signature: sig,
            min_version: 5, // Minimum is higher
        };

        assert!(matches!(
            verify_firmware(&key, &header, firmware),
            Err(SecureBootError::RollbackDetected { .. })
        ));
    }
}
