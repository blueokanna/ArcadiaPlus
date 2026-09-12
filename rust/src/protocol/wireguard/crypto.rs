//! WireGuard's cryptographic primitives, wired to the in-house implementations.
//!
//! The construction string below names the exact primitive set Noise_IKpsk2
//! negotiates, so every function here has to match it byte for byte:
//!
//! * `hash`/`hmac`/`kdf*` — BLAKE2s, the latter as HMAC (RFC 2104),
//! * `mac` — BLAKE2s in keyed mode with a 16-byte digest (`mac1`),
//! * `dh` — X25519,
//! * `aead_*` — ChaCha20-Poly1305 with WireGuard's 4-zero-byte + LE-counter nonce.

use crate::crypto::{Aead, Blake2s, ChaCha20Poly1305, Digest, Hmac, x25519};

pub const CONSTRUCTION: &[u8] = b"Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";
pub const IDENTIFIER: &[u8] = b"WireGuard v1 zx2c4 Jason@zx2c4.com";
pub const LABEL_MAC1: &[u8] = b"mac1----";
#[allow(dead_code)]
pub const LABEL_COOKIE: &[u8] = b"cookie--";

pub const REKEY_AFTER_MESSAGES: u64 = 1 << 60;
pub const REJECT_AFTER_MESSAGES: u64 = u64::MAX - (1 << 13);
pub const REKEY_AFTER_TIME: u64 = 120;
pub const REJECT_AFTER_TIME: u64 = 180;
pub const REKEY_TIMEOUT: u64 = 5;
pub const KEEPALIVE_TIMEOUT: u64 = 10;

/// BLAKE2s-256 of `data`.
pub fn hash(data: &[u8]) -> [u8; 32] {
    Blake2s::digest(data)
}

/// HMAC-BLAKE2s — the PRF behind `kdf1..kdf3` and the handshake MACs.
pub fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    Hmac::<Blake2s>::mac_into(key, data, &mut out);
    out
}

/// Keyed BLAKE2s truncated to 16 bytes — WireGuard's `mac1`/`cookie` tag.
///
/// Note this is *keyed* BLAKE2s, not an HMAC: the key feeds the parameter
/// block exactly as `mac1 = MAC(HASH(LABEL_MAC1 || peer_static_public), msg)`
/// requires, and the digest length is part of the parameter block, so it
/// cannot be emulated by truncating an unkeyed hash.
pub fn mac(key: &[u8], data: &[u8]) -> [u8; 16] {
    let mut hasher =
        Blake2s::with_params(16, key).expect("WireGuard keys are 32 bytes, within BLAKE2s limits");
    hasher.update(data);
    let digest = hasher.finalize();
    let mut out = [0u8; 16];
    out.copy_from_slice(&digest[..16]);
    out
}

pub fn kdf1(key: &[u8], input: &[u8]) -> [u8; 32] {
    let prk = hmac(key, input);
    hmac(&prk, &[0x01])
}

pub fn kdf2(key: &[u8], input: &[u8]) -> ([u8; 32], [u8; 32]) {
    let prk = hmac(key, input);
    let t0 = hmac(&prk, &[0x01]);
    let mut t1_input = t0.to_vec();
    t1_input.push(0x02);
    let t1 = hmac(&prk, &t1_input);
    (t0, t1)
}

pub fn kdf3(key: &[u8], input: &[u8]) -> ([u8; 32], [u8; 32], [u8; 32]) {
    let prk = hmac(key, input);
    let t0 = hmac(&prk, &[0x01]);
    let mut t1_input = t0.to_vec();
    t1_input.push(0x02);
    let t1 = hmac(&prk, &t1_input);
    let mut t2_input = t1.to_vec();
    t2_input.push(0x03);
    let t2 = hmac(&prk, &t2_input);
    (t0, t1, t2)
}

/// X25519 scalar multiplication. The scalar is clamped by the implementation,
/// so private keys are used exactly as the configuration spells them.
pub fn dh(private_key: &[u8; 32], public_key: &[u8; 32]) -> [u8; 32] {
    x25519::x25519(private_key, public_key)
}

pub fn public_key_from_private(private_key: &[u8; 32]) -> [u8; 32] {
    x25519::public_key(private_key)
}

/// WireGuard's nonce: 32 zero bits followed by the little-endian counter.
#[inline]
fn transport_nonce(counter: u64) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[4..].copy_from_slice(&counter.to_le_bytes());
    nonce
}

pub fn aead_encrypt(key: &[u8; 32], counter: u64, plaintext: &[u8], aad: &[u8]) -> Vec<u8> {
    ChaCha20Poly1305::new(key)
        .encrypt(&transport_nonce(counter), plaintext, aad)
        .expect("ChaCha20-Poly1305 with a fixed-size key and nonce cannot fail")
}

pub fn aead_decrypt(
    key: &[u8; 32],
    counter: u64,
    ciphertext: &[u8],
    aad: &[u8],
) -> Option<Vec<u8>> {
    ChaCha20Poly1305::new(key)
        .decrypt(&transport_nonce(counter), ciphertext, aad)
        .ok()
}

pub fn generate_keypair() -> ([u8; 32], [u8; 32]) {
    let mut secret_bytes = [0u8; 32];
    crate::crypto::fill_random(&mut secret_bytes).expect("the OS entropy source must be available");
    let public = x25519::public_key(&secret_bytes);
    (secret_bytes, public)
}

pub fn timestamp() -> [u8; 12] {
    use std::time::{SystemTime, UNIX_EPOCH};

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Time went backwards");

    let secs = now.as_secs();
    let nanos = now.subsec_nanos();

    let mut tai64n = [0u8; 12];
    tai64n[0..8].copy_from_slice(&(secs + 4611686018427387914u64).to_be_bytes());
    tai64n[8..12].copy_from_slice(&nanos.to_be_bytes());
    tai64n
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hash() {
        let data = b"test data";
        let h1 = hash(data);
        let h2 = hash(data);
        assert_eq!(h1, h2);
        assert_eq!(h1.len(), 32);
    }

    #[test]
    fn test_hmac() {
        let key = b"test key";
        let data = b"test data";
        let h1 = hmac(key, data);
        let h2 = hmac(key, data);
        assert_eq!(h1, h2);
        assert_eq!(h1.len(), 32);
    }

    #[test]
    fn test_kdf() {
        let key = [0u8; 32];
        let input = b"test input";
        let k1 = kdf1(&key, input);
        assert_eq!(k1.len(), 32);

        let (k2a, k2b) = kdf2(&key, input);
        assert_eq!(k2a.len(), 32);
        assert_eq!(k2b.len(), 32);
        assert_ne!(k2a, k2b);
    }

    #[test]
    fn test_dh() {
        let (priv1, pub1) = generate_keypair();
        let (priv2, pub2) = generate_keypair();

        let shared1 = dh(&priv1, &pub2);
        let shared2 = dh(&priv2, &pub1);

        assert_eq!(shared1, shared2);
    }

    #[test]
    fn test_aead_roundtrip() {
        let key = [0u8; 32];
        let plaintext = b"hello world";
        let aad = b"additional data";

        let ciphertext = aead_encrypt(&key, 0, plaintext, aad);
        let decrypted = aead_decrypt(&key, 0, &ciphertext, aad).unwrap();

        assert_eq!(plaintext.as_slice(), decrypted.as_slice());
    }
}
