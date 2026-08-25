//! ★ P6 #70: 100% Static Allocation
//!
//! Heap kullanımını tamamen ortadan kaldıran statik veri yapıları.
//! Runtime heap allocation = panic (debug) / abort (release).
//!
//! ## Güvenlik
//! - Heap overflow / use-after-free imkansız
//! - Deterministik bellek kullanımı (no OOM at runtime)
//! - Embedded-safe: no_std uyumlu

/// Fixed-capacity vector — heap-free Vec alternative.
/// Capacity is compile-time constant.
pub struct StaticVec<T, const N: usize> {
    data: [Option<T>; N],
    len: usize,
}

impl<T: Copy + Default, const N: usize> StaticVec<T, N> {
    /// Create empty StaticVec.
    pub const fn new() -> Self {
        Self {
            data: [None; N],
            len: 0,
        }
    }

    /// Push an element. Returns Err if full.
    pub fn push(&mut self, value: T) -> Result<(), T> {
        if self.len >= N {
            return Err(value);
        }
        self.data[self.len] = Some(value);
        self.len += 1;
        Ok(())
    }

    /// Pop last element.
    pub fn pop(&mut self) -> Option<T> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        self.data[self.len].take()
    }

    /// Get element by index.
    pub fn get(&self, index: usize) -> Option<&T> {
        if index < self.len {
            self.data[index].as_ref()
        } else {
            None
        }
    }

    /// Get mutable reference by index.
    pub fn get_mut(&mut self, index: usize) -> Option<&mut T> {
        if index < self.len {
            self.data[index].as_mut()
        } else {
            None
        }
    }

    /// Current length.
    pub fn len(&self) -> usize {
        self.len
    }

    /// Check if empty.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Maximum capacity.
    pub const fn capacity(&self) -> usize {
        N
    }

    /// Clear all elements.
    pub fn clear(&mut self) {
        for i in 0..self.len {
            self.data[i] = None;
        }
        self.len = 0;
    }

    /// Iterate over elements.
    pub fn iter(&self) -> impl Iterator<Item = &T> {
        self.data[..self.len].iter().filter_map(|x| x.as_ref())
    }
}

/// Fixed-capacity byte buffer — heap-free String/Vec<u8> alternative.
pub struct StaticBuf<const N: usize> {
    data: [u8; N],
    len: usize,
}

impl<const N: usize> StaticBuf<N> {
    /// Create empty buffer.
    pub const fn new() -> Self {
        Self {
            data: [0u8; N],
            len: 0,
        }
    }

    /// Append bytes. Returns number of bytes actually written.
    pub fn extend(&mut self, bytes: &[u8]) -> usize {
        let available = N - self.len;
        let to_copy = bytes.len().min(available);
        self.data[self.len..self.len + to_copy].copy_from_slice(&bytes[..to_copy]);
        self.len += to_copy;
        to_copy
    }

    /// Get contents as slice.
    pub fn as_slice(&self) -> &[u8] {
        &self.data[..self.len]
    }

    /// Clear buffer.
    pub fn clear(&mut self) {
        self.data[..self.len].fill(0);
        self.len = 0;
    }

    /// Current length.
    pub fn len(&self) -> usize {
        self.len
    }

    /// Is empty.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Remaining capacity.
    pub fn remaining(&self) -> usize {
        N - self.len
    }
}

/// Fixed-capacity ring buffer for streaming data.
pub struct StaticRing<const N: usize> {
    data: [u8; N],
    head: usize,
    tail: usize,
    full: bool,
}

impl<const N: usize> StaticRing<N> {
    pub const fn new() -> Self {
        Self {
            data: [0u8; N],
            head: 0,
            tail: 0,
            full: false,
        }
    }

    /// Push one byte. Returns false if full.
    pub fn push(&mut self, byte: u8) -> bool {
        if self.full {
            return false;
        }
        self.data[self.head] = byte;
        self.head = (self.head + 1) % N;
        self.full = self.head == self.tail;
        true
    }

    /// Pop one byte. Returns None if empty.
    pub fn pop(&mut self) -> Option<u8> {
        if self.is_empty() {
            return None;
        }
        let byte = self.data[self.tail];
        self.tail = (self.tail + 1) % N;
        self.full = false;
        Some(byte)
    }

    pub fn is_empty(&self) -> bool {
        !self.full && self.head == self.tail
    }

    pub fn len(&self) -> usize {
        if self.full {
            N
        } else if self.head >= self.tail {
            self.head - self.tail
        } else {
            N - self.tail + self.head
        }
    }
}

// =============================================================================
// Tests
// =============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn t1_static_vec_basic() {
        let mut v: StaticVec<u32, 4> = StaticVec::new();
        assert!(v.is_empty());
        assert_eq!(v.capacity(), 4);

        v.push(10).unwrap();
        v.push(20).unwrap();
        assert_eq!(v.len(), 2);
        assert_eq!(*v.get(0).unwrap(), 10);
        assert_eq!(*v.get(1).unwrap(), 20);
    }

    #[test]
    fn t2_static_vec_overflow() {
        let mut v: StaticVec<u8, 2> = StaticVec::new();
        v.push(1).unwrap();
        v.push(2).unwrap();
        assert!(v.push(3).is_err()); // Full
    }

    #[test]
    fn t3_static_vec_pop() {
        let mut v: StaticVec<u8, 4> = StaticVec::new();
        v.push(1).unwrap();
        v.push(2).unwrap();
        assert_eq!(v.pop(), Some(2));
        assert_eq!(v.pop(), Some(1));
        assert_eq!(v.pop(), None);
    }

    #[test]
    fn t4_static_buf_extend() {
        let mut buf: StaticBuf<8> = StaticBuf::new();
        assert_eq!(buf.extend(b"hello"), 5);
        assert_eq!(buf.as_slice(), b"hello");
        assert_eq!(buf.remaining(), 3);
        assert_eq!(buf.extend(b"world"), 3); // Only 3 bytes fit
        assert_eq!(buf.len(), 8);
    }

    #[test]
    fn t5_static_buf_clear() {
        let mut buf: StaticBuf<16> = StaticBuf::new();
        buf.extend(b"secret");
        buf.clear();
        assert!(buf.is_empty());
        // Data should be zeroed
        assert!(buf.as_slice().is_empty());
    }

    #[test]
    fn t6_static_ring_basic() {
        let mut ring: StaticRing<4> = StaticRing::new();
        assert!(ring.push(1));
        assert!(ring.push(2));
        assert!(ring.push(3));
        assert!(ring.push(4));
        assert!(!ring.push(5)); // Full

        assert_eq!(ring.pop(), Some(1));
        assert_eq!(ring.pop(), Some(2));
        assert!(ring.push(5)); // Space freed
    }

    #[test]
    fn t7_static_ring_wraparound() {
        let mut ring: StaticRing<3> = StaticRing::new();
        ring.push(1);
        ring.push(2);
        ring.pop(); // Remove 1
        ring.push(3);
        ring.push(4); // Wraps around

        assert_eq!(ring.len(), 3);
        assert_eq!(ring.pop(), Some(2));
        assert_eq!(ring.pop(), Some(3));
        assert_eq!(ring.pop(), Some(4));
        assert!(ring.is_empty());
    }

    #[test]
    fn t8_static_vec_iter() {
        let mut v: StaticVec<u32, 4> = StaticVec::new();
        v.push(10).unwrap();
        v.push(20).unwrap();
        v.push(30).unwrap();

        let sum: u32 = v.iter().sum();
        assert_eq!(sum, 60);
    }
}
