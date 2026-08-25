//! Titan HAL — Hardware Abstraction Layer
//!
//! SecureKeyStore trait abstracts Secure Element (StrongBox) and USB HSM.
//! Faz 1: MemoryKeyStore (in-memory, Zeroized) for development.
//! Later: AndroidSEKeyStore, UsbHsmKeyStore.

use std::collections::HashMap;
use zeroize::Zeroize;

/// Errors from key store operations.
#[derive(Debug, PartialEq)]
pub enum KeyStoreError {
    NotFound,
    StoreFailed(String),
    AlreadyExists,
}

/// Hardware-agnostic key storage trait.
/// Implementations: MemoryKeyStore (dev), SE (prod), USB HSM (prod).
pub trait SecureKeyStore {
    fn store(&mut self, id: &str, data: &[u8]) -> Result<(), KeyStoreError>;
    fn load(&self, id: &str) -> Result<Vec<u8>, KeyStoreError>;
    fn delete(&mut self, id: &str) -> Result<(), KeyStoreError>;
    fn exists(&self, id: &str) -> bool;
}

/// In-memory key store for development and testing.
/// All values are zeroized on delete and on Drop.
pub struct MemoryKeyStore {
    store: HashMap<String, Vec<u8>>,
}

impl MemoryKeyStore {
    pub fn new() -> Self {
        Self {
            store: HashMap::new(),
        }
    }
}

impl Default for MemoryKeyStore {
    fn default() -> Self {
        Self::new()
    }
}

impl SecureKeyStore for MemoryKeyStore {
    fn store(&mut self, id: &str, data: &[u8]) -> Result<(), KeyStoreError> {
        self.store.insert(id.to_string(), data.to_vec());
        Ok(())
    }

    fn load(&self, id: &str) -> Result<Vec<u8>, KeyStoreError> {
        self.store
            .get(id)
            .cloned()
            .ok_or(KeyStoreError::NotFound)
    }

    fn delete(&mut self, id: &str) -> Result<(), KeyStoreError> {
        if let Some(mut val) = self.store.remove(id) {
            val.zeroize();
            Ok(())
        } else {
            Err(KeyStoreError::NotFound)
        }
    }

    fn exists(&self, id: &str) -> bool {
        self.store.contains_key(id)
    }
}

impl Drop for MemoryKeyStore {
    fn drop(&mut self) {
        for (_, val) in self.store.iter_mut() {
            val.zeroize();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_store_and_load() {
        let mut ks = MemoryKeyStore::new();
        let data = vec![1u8, 2, 3, 4];
        ks.store("key1", &data).unwrap();
        assert_eq!(ks.load("key1").unwrap(), data);
    }

    #[test]
    fn test_exists() {
        let mut ks = MemoryKeyStore::new();
        assert!(!ks.exists("key1"));
        ks.store("key1", &[0xAA]).unwrap();
        assert!(ks.exists("key1"));
    }

    #[test]
    fn test_delete() {
        let mut ks = MemoryKeyStore::new();
        ks.store("key1", &[0xBB]).unwrap();
        ks.delete("key1").unwrap();
        assert!(!ks.exists("key1"));
        assert_eq!(ks.load("key1"), Err(KeyStoreError::NotFound));
    }

    #[test]
    fn test_delete_not_found() {
        let mut ks = MemoryKeyStore::new();
        assert_eq!(ks.delete("nope"), Err(KeyStoreError::NotFound));
    }

    #[test]
    fn test_overwrite() {
        let mut ks = MemoryKeyStore::new();
        ks.store("key1", &[1]).unwrap();
        ks.store("key1", &[2]).unwrap();
        assert_eq!(ks.load("key1").unwrap(), vec![2]);
    }
}
