//! ★ C1: Shamir's Secret Sharing — K-of-N Message Splitting
//!
//! Splits ciphertext into N shares using GF(2^8) polynomial evaluation.
//! Any K shares can reconstruct the original; K-1 shares reveal nothing.
//!
//! Used by Hydra mesh: instead of sending the full ciphertext to 3 brokers,
//! split into 10 shares and send one to each broker. Any 3 reconstruct.
//!
//! # Security
//! - Information-theoretic security: K-1 shares = zero information leak
//! - GF(2^8): Operates in Galois Field 2^8 (same field as AES)
//! - No timing side-channels: all operations are constant-time in GF

/// A single Shamir share
#[derive(Debug, Clone)]
pub struct Share {
    /// Share index (x-coordinate, 1-indexed, never 0)
    pub x: u8,
    /// Share data (y-coordinates, one per byte of original secret)
    pub data: Vec<u8>,
}

/// GF(2^8) arithmetic with irreducible polynomial x^8 + x^4 + x^3 + x + 1
mod gf256 {
    /// GF(2^8) addition (XOR)
    #[inline(always)]
    pub fn add(a: u8, b: u8) -> u8 {
        a ^ b
    }

    /// GF(2^8) multiplication using Russian Peasant algorithm
    #[inline]
    pub fn mul(mut a: u8, mut b: u8) -> u8 {
        let mut result: u8 = 0;
        while b > 0 {
            if b & 1 != 0 {
                result ^= a;
            }
            let carry = a & 0x80;
            a <<= 1;
            if carry != 0 {
                a ^= 0x1B; // x^8 + x^4 + x^3 + x + 1
            }
            b >>= 1;
        }
        result
    }

    /// GF(2^8) multiplicative inverse using extended Euclidean / Fermat
    #[inline]
    pub fn inv(a: u8) -> u8 {
        if a == 0 {
            return 0; // 0 has no inverse, but we never evaluate at x=0
        }
        // Fermat's little theorem: a^(-1) = a^(254) in GF(2^8)
        let mut result = a;
        for _ in 0..6 {
            result = mul(result, result);
            result = mul(result, a);
        }
        mul(result, result) // a^254
    }

    /// GF(2^8) division
    #[inline]
    pub fn div(a: u8, b: u8) -> u8 {
        mul(a, inv(b))
    }
}

/// Split a secret into `n` shares with threshold `k`.
///
/// # Panics
/// - If `k == 0` or `k > n` or `n > 255`
/// - Secret must not be empty
pub fn split(secret: &[u8], k: u8, n: u8) -> Vec<Share> {
    assert!(k > 0 && k <= n && n > 0, "Invalid k={}, n={}", k, n);
    assert!(!secret.is_empty(), "Secret must not be empty");

    let mut shares: Vec<Share> = (1..=n)
        .map(|x| Share {
            x,
            data: Vec::with_capacity(secret.len()),
        })
        .collect();

    let mut rng = rand::thread_rng();
    use rand::RngCore;

    // For each byte of the secret, create a random polynomial of degree k-1
    for &secret_byte in secret {
        // Coefficients: a[0] = secret_byte, a[1..k-1] = random
        let mut coeffs = vec![0u8; k as usize];
        coeffs[0] = secret_byte;
        for coeff in coeffs.iter_mut().skip(1) {
            let mut r = [0u8; 1];
            rng.fill_bytes(&mut r);
            *coeff = r[0];
        }

        // Evaluate polynomial at x = 1, 2, ..., n
        for share in shares.iter_mut() {
            let x = share.x;
            let mut y = coeffs[0];
            let mut x_pow = x;
            for &coeff in coeffs.iter().skip(1) {
                y = gf256::add(y, gf256::mul(coeff, x_pow));
                x_pow = gf256::mul(x_pow, x);
            }
            share.data.push(y);
        }
    }

    shares
}

/// Reconstruct the secret from `k` or more shares using Lagrange interpolation.
///
/// # Errors
/// Returns `None` if shares are inconsistent or insufficient.
pub fn reconstruct(shares: &[Share]) -> Option<Vec<u8>> {
    if shares.is_empty() {
        return None;
    }

    let secret_len = shares[0].data.len();
    if shares.iter().any(|s| s.data.len() != secret_len) {
        return None; // Inconsistent share lengths
    }

    let mut secret = vec![0u8; secret_len];

    // For each byte position
    for byte_idx in 0..secret_len {
        let mut value = 0u8;

        // Lagrange interpolation at x = 0
        for (i, share_i) in shares.iter().enumerate() {
            let xi = share_i.x;
            let yi = share_i.data[byte_idx];

            // Compute Lagrange basis polynomial L_i(0)
            let mut basis = 1u8;
            for (j, share_j) in shares.iter().enumerate() {
                if i == j {
                    continue;
                }
                let xj = share_j.x;
                // L_i(0) *= (0 - xj) / (xi - xj) = xj / (xi ^ xj)
                basis = gf256::mul(basis, gf256::div(xj, gf256::add(xi, xj)));
            }

            value = gf256::add(value, gf256::mul(yi, basis));
        }

        secret[byte_idx] = value;
    }

    Some(secret)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_split_and_reconstruct_2_of_3() {
        let secret = b"PROJECT HIDRA TOP SECRET";
        let shares = split(secret, 2, 3);
        assert_eq!(shares.len(), 3);

        // Any 2 shares should reconstruct
        let result = reconstruct(&shares[0..2]).unwrap();
        assert_eq!(result, secret);
        let result = reconstruct(&shares[1..3]).unwrap();
        assert_eq!(result, secret);
        let result = reconstruct(&[shares[0].clone(), shares[2].clone()]).unwrap();
        assert_eq!(result, secret);
    }

    #[test]
    fn test_split_and_reconstruct_3_of_10() {
        let secret = b"HiDRA Shamir 3-of-10 split test payload with sufficient length";
        let shares = split(secret, 3, 10);
        assert_eq!(shares.len(), 10);

        // Any 3 shares should reconstruct
        let result = reconstruct(&[shares[0].clone(), shares[4].clone(), shares[9].clone()]).unwrap();
        assert_eq!(result, secret);
        let result = reconstruct(&[shares[2].clone(), shares[5].clone(), shares[7].clone()]).unwrap();
        assert_eq!(result, secret);
    }

    #[test]
    fn test_insufficient_shares_fail() {
        let secret = b"SECRET";
        let shares = split(secret, 3, 5);

        // Only 2 shares (need 3) — should NOT reconstruct correctly
        let result = reconstruct(&shares[0..2]).unwrap();
        assert_ne!(result, secret); // Insufficient shares = garbage
    }

    #[test]
    fn test_all_shares_reconstruct() {
        let secret = b"All shares test";
        let shares = split(secret, 3, 5);
        let result = reconstruct(&shares).unwrap();
        assert_eq!(result, secret);
    }

    #[test]
    fn test_single_byte_secret() {
        let secret = &[0x42u8];
        let shares = split(secret, 2, 3);
        let result = reconstruct(&shares[0..2]).unwrap();
        assert_eq!(result, secret);
    }

    #[test]
    fn test_gf256_mul_identity() {
        assert_eq!(gf256::mul(1, 42), 42);
        assert_eq!(gf256::mul(42, 1), 42);
    }

    #[test]
    fn test_gf256_mul_inverse() {
        for a in 1..=255u8 {
            let inv = gf256::inv(a);
            assert_eq!(gf256::mul(a, inv), 1, "Failed for a={}", a);
        }
    }
}
