//! COBS (Consistent Overhead Byte Stuffing) — MCU-UART Frame Layer
//!
//! TCP stream'de paket sınırlarını belirlemek için kullanılır.
//! Veri içinde 0x00 asla geçmez → 0x00 = paket ayırıcı.
//! Overhead: ~%1 (254 byte'da 1 byte ek)
//!
//! # Kullanım
//! ```
//! use hidra_net::cobs;
//!
//! let data = vec![0x01, 0x00, 0x02];
//! let encoded = cobs::encode(&data);
//! // encoded içinde 0x00 yok (ayırıcı hariç)
//!
//! let decoded = cobs::decode(&encoded).unwrap();
//! assert_eq!(data, decoded);
//! ```

use thiserror::Error;

/// COBS decode hataları
#[derive(Debug, Error, PartialEq)]
pub enum CobsError {
    #[error("COBS frame bos olamaz")]
    EmptyFrame,

    #[error("COBS frame icinde beklenmeyen 0x00 byte (pozisyon: {0})")]
    UnexpectedZero(usize),

    #[error("COBS frame yapisi gecersiz — code byte sinir disi")]
    InvalidStructure,
}

/// COBS encode: girdi byte dizisini 0x00-free çıktıya dönüştürür.
///
/// Algoritma:
/// - Veriyi 254 byte'lık bloklara böl
/// - Her bloğun başına "sonraki 0x00'a kaç byte var" bilgisi (code byte) yaz
/// - 0x00 byte'ları code byte zincirleme ile temsil et
pub fn encode(input: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(input.len() + input.len() / 254 + 2);

    let mut read_idx = 0;

    while read_idx < input.len() {
        // Sonraki 0x00'ın konumunu bul (veya 254 byte sınırı)
        let mut block_end = read_idx;
        while block_end < input.len()
            && input[block_end] != 0x00
            && (block_end - read_idx) < 254
        {
            block_end += 1;
        }

        let block_len = block_end - read_idx;

        if block_end < input.len() && input[block_end] == 0x00 {
            // 0x00 bulundu — code = block_len + 1 (sonraki 0x00'a mesafe)
            output.push((block_len + 1) as u8);
            output.extend_from_slice(&input[read_idx..block_end]);
            read_idx = block_end + 1; // 0x00'ı atla
        } else {
            // 0x00 bulunamadı veya 254 byte sınırına ulaşıldı
            output.push((block_len + 1) as u8);
            output.extend_from_slice(&input[read_idx..block_end]);
            read_idx = block_end;

            // Eğer tam 254 byte'lık blok ve sonraki byte 0x00 ise,
            // 0xFF code byte zaten sonraki bloğu işaret eder
            if block_len == 254 && read_idx < input.len() && input[read_idx] != 0x00 {
                // 254 byte dolu blok, 0x00 yok — 0xFF code byte
                // (zaten block_len + 1 = 255 = 0xFF)
                // Sonraki blok normal devam eder
            }
        }
    }

    // Eğer girdi boşsa veya son byte 0x00 ise, kapanış code byte
    if input.is_empty() || (input.last() == Some(&0x00)) {
        output.push(0x01);
    }

    output
}

/// COBS decode: 0x00-free encoded veriyi orijinal veriye dönüştürür.
///
/// Girdi: son delimitör (0x00) hariç COBS encoded byte dizisi
pub fn decode(input: &[u8]) -> Result<Vec<u8>, CobsError> {
    if input.is_empty() {
        return Err(CobsError::EmptyFrame);
    }

    let mut output = Vec::with_capacity(input.len());
    let mut read_idx = 0;

    while read_idx < input.len() {
        let code = input[read_idx] as usize;

        if code == 0 {
            return Err(CobsError::UnexpectedZero(read_idx));
        }

        read_idx += 1;

        // code - 1 adet data byte kopyala
        let data_count = code - 1;

        if read_idx + data_count > input.len() {
            return Err(CobsError::InvalidStructure);
        }

        for i in 0..data_count {
            let byte = input[read_idx + i];
            if byte == 0x00 {
                return Err(CobsError::UnexpectedZero(read_idx + i));
            }
            output.push(byte);
        }

        read_idx += data_count;

        // code < 0xFF ve frame devam ediyorsa → 0x00 ekle
        if code < 0xFF && read_idx < input.len() {
            output.push(0x00);
        }
    }

    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn t1_empty_data() {
        let encoded = encode(&[]);
        assert_eq!(encoded, vec![0x01]);
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded, vec![]);
    }

    #[test]
    fn t2_single_zero() {
        let encoded = encode(&[0x00]);
        assert_eq!(encoded, vec![0x01, 0x01]);
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded, vec![0x00]);
    }

    #[test]
    fn t3_no_zeros() {
        let data = vec![0x11, 0x22, 0x33];
        let encoded = encode(&data);
        assert_eq!(encoded, vec![0x04, 0x11, 0x22, 0x33]);
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn t4_round_trip_mixed() {
        let data = vec![0x01, 0x00, 0x02, 0x00, 0x03];
        let encoded = encode(&data);
        // Encoded'da 0x00 olmamalı
        assert!(!encoded.contains(&0x00), "encoded must not contain 0x00");
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn t5_round_trip_254_bytes() {
        // 254 byte sınır testi (code byte 0xFF)
        let data: Vec<u8> = (1..=254).collect();
        let encoded = encode(&data);
        assert!(!encoded.contains(&0x00));
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn t6_decode_error_empty() {
        assert_eq!(decode(&[]), Err(CobsError::EmptyFrame));
    }

    #[test]
    fn t7_decode_error_unexpected_zero() {
        assert!(matches!(
            decode(&[0x02, 0x00]),
            Err(CobsError::UnexpectedZero(_))
        ));
    }

    #[test]
    fn t8_round_trip_aes_block() {
        // TITAN AES ciphertext bloğu simülasyonu (16 byte, rastgele)
        let data = vec![
            0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x42, 0xFF, 0x00,
            0x13, 0x37, 0x00, 0x00, 0xCA, 0xFE, 0xBA, 0xBE,
        ];
        let encoded = encode(&data);
        assert!(!encoded.contains(&0x00));
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded, data);
    }

    #[test]
    fn t9_all_zeros() {
        let data = vec![0x00, 0x00, 0x00];
        let encoded = encode(&data);
        assert!(!encoded.contains(&0x00));
        let decoded = decode(&encoded).unwrap();
        assert_eq!(decoded, data);
    }
}
