//! One door to every cryptographic primitive this engine uses.
//!
//! Nothing here comes from a third-party crypto crate: hashes, MACs, KDFs,
//! AEADs, ECDH and encodings are all implemented in `corduit`'s `crypto`
//! module. Call sites import from `crate::crypto` instead of reaching for
//! `sha2`, `blake3`, `base64`, … so that swapping or hardening a primitive is
//! a one-file change, and so that "which crypto are we actually running" has a
//! single auditable answer.
//!
//! The re-exports deliberately keep the familiar shapes (`Digest::new()`,
//! `update()`, `finalize()`, `Hkdf::<Sha1>::new(...).expand(...)`) so protocol
//! code reads like protocol code rather than like a library adapter.
//!
//! `no_std` note: everything re-exported here is `no_std + alloc`-clean. The
//! only `std` this module needs comes from the callers that were already
//! `std`-bound.

/// Streaming digests: `new()`, `update()`, `finalize()`.
pub use corduit::crypto::digest::Digest;

/// Hash implementations (MD-style and BLAKE family).
pub use corduit::crypto::hash::{
    Blake2b, Blake2s, Blake3, Md5, Sha1, Sha224, Sha256, Sha384, Sha512,
};

/// HKDF over any [`Digest`].
pub use corduit::crypto::kdf::{Hkdf, HkdfError};

/// AEADs and the traits used to drive them.
pub use corduit::crypto::aead::{
    Aead, AeadError, AeadInPlace, Aes128Gcm, Aes192Gcm, Aes256Gcm, AesGcm, ChaCha20Poly1305,
};

/// Keyed MACs: HMAC over any [`Digest`] (RFC 2104) and one-shot Poly1305.
pub use corduit::crypto::mac::{Hmac, Poly1305};

/// Stream ciphers, for the places that need a raw keystream.
pub use corduit::crypto::stream::{Aes, ChaCha20};

/// ChaCha20-based CSPRNG (the caller supplies the seed and the stream id).
pub use corduit::crypto::rng::ChaChaRng;

/// Length-validation error returned by the primitive constructors.
pub use corduit::crypto::InvalidLength;

/// Entropy straight from the operating system.
///
/// This is the one primitive that deliberately does *not* live in this crate:
/// the kernel's CSPRNG is the root of trust, and re-deriving it would be
/// theatre. Everything downstream of the seed — stream generation, key
/// agreement, AEAD nonces — is ours.
pub fn fill_random(out: &mut [u8]) -> Result<(), getrandom::Error> {
    getrandom::fill(out)
}

/// Bytes after which the process CSPRNG re-seeds itself from the OS.
const RESEED_AFTER_BYTES: usize = 64 * 1024;

/// Process-wide cryptographic RNG: the in-house ChaCha20 keystream over an OS
/// seed, re-seeded every [`RESEED_AFTER_BYTES`] bytes.
///
/// This exists because the interesting randomness in a proxy is not only key
/// material: DNS transaction IDs, VMess padding and masks, ephemeral source
/// ports and TCP initial sequence numbers are all guessable inputs if they
/// repeat, so they need a CSPRNG rather than a fast non-cryptographic one.
/// Going through this type keeps that property while paying one syscall per
/// 64 KiB instead of one per value.
struct Entropy {
    rng: ChaChaRng,
    remaining: usize,
}

impl Entropy {
    fn seed() -> Self {
        let mut seed = [0u8; 32];
        let mut stream = [0u8; 8];
        fill_random(&mut seed).expect("the OS entropy source must be available");
        fill_random(&mut stream).expect("the OS entropy source must be available");
        Self {
            rng: ChaChaRng::from_seed_and_stream(&seed, u64::from_le_bytes(stream)),
            remaining: RESEED_AFTER_BYTES,
        }
    }

    fn fill(&mut self, out: &mut [u8]) {
        if out.len() > self.remaining {
            *self = Self::seed();
        }
        self.rng.fill_bytes(out);
        self.remaining -= out.len();
    }
}

thread_local! {
    static ENTROPY: core::cell::RefCell<Entropy> = core::cell::RefCell::new(Entropy::seed());
}

/// Fill `out` from the process CSPRNG.
pub fn random_bytes(out: &mut [u8]) {
    ENTROPY.with(|entropy| entropy.borrow_mut().fill(out));
}

/// A random `u8`.
pub fn random_u8() -> u8 {
    let mut bytes = [0u8; 1];
    random_bytes(&mut bytes);
    bytes[0]
}

/// A random `u16`.
pub fn random_u16() -> u16 {
    let mut bytes = [0u8; 2];
    random_bytes(&mut bytes);
    u16::from_le_bytes(bytes)
}

/// A random `u32`.
pub fn random_u32() -> u32 {
    let mut bytes = [0u8; 4];
    random_bytes(&mut bytes);
    u32::from_le_bytes(bytes)
}

/// A random `u64`.
pub fn random_u64() -> u64 {
    let mut bytes = [0u8; 8];
    random_bytes(&mut bytes);
    u64::from_le_bytes(bytes)
}

/// Curve25519 primitives: `x25519(scalar, u)` and `public_key(private)`.
///
/// A module of our own because `corduit::crypto::dh` re-exports the bare
/// function `x25519` (its module is private), and call sites read better as
/// `x25519::public_key(..)` next to `ChaCha20Poly1305::new(..)`.
pub mod x25519 {
    /// X25519 scalar multiplication. The scalar is clamped per RFC 7748, so
    /// raw configuration bytes can be passed through unchanged.
    pub fn x25519(scalar: &[u8; 32], u: &[u8; 32]) -> [u8; 32] {
        corduit::crypto::dh::x25519(scalar, u)
    }

    /// The public key belonging to `private`.
    pub fn public_key(private: &[u8; 32]) -> [u8; 32] {
        corduit::crypto::dh::public_key(private)
    }
}

/// Base64 (RFC 4648) with the two alphabets this codebase needs.
///
/// Both spellings are provided: the free functions (`encode(bytes, URL_SAFE_NO_PAD)`)
/// and an [`Engine`] extension so a call site can keep reading
/// `URL_SAFE_NO_PAD.encode(bytes)` — that is what the DoH and subscription
/// paths already wrote, and it is the more readable of the two.
pub mod base64 {
    pub use corduit::crypto::encoding::{
        Alphabet, Config, DecodeError, decode, encode, encoded_len,
    };

    /// Standard alphabet, padded.
    pub const STANDARD: Config = Config::STANDARD;
    /// Standard alphabet, unpadded.
    pub const STANDARD_NO_PAD: Config = Config::STANDARD_NO_PAD;
    /// URL-safe alphabet, padded.
    pub const URL_SAFE: Config = Config::URL_SAFE;
    /// URL-safe alphabet, unpadded (what DoH uses).
    pub const URL_SAFE_NO_PAD: Config = Config::URL_SAFE_NO_PAD;

    /// Method-style sugar over [`Config`].
    pub trait Engine {
        /// Encode `input` with this configuration.
        fn encode(&self, input: impl AsRef<[u8]>) -> std::string::String;

        /// Decode `input` with this configuration.
        fn decode(&self, input: impl AsRef<[u8]>) -> Result<std::vec::Vec<u8>, DecodeError>;
    }

    impl Engine for Config {
        fn encode(&self, input: impl AsRef<[u8]>) -> std::string::String {
            encode(input.as_ref(), *self)
        }

        fn decode(&self, input: impl AsRef<[u8]>) -> Result<std::vec::Vec<u8>, DecodeError> {
            decode(input.as_ref(), *self)
        }
    }
}

/// Hex, for wire dumps and test vectors.
pub mod hex {
    use corduit::crypto::encoding::{HexDecodeError, hex_decode, hex_encode};

    /// Lowercase hex of `data`.
    pub fn encode(data: impl AsRef<[u8]>) -> std::string::String {
        hex_encode(data.as_ref())
    }

    /// Decode hex text (an optional `0x` prefix is not accepted — wire dumps
    /// here never carry one, and silently accepting it hides format drift).
    pub fn decode(text: impl AsRef<[u8]>) -> Result<std::vec::Vec<u8>, HexDecodeError> {
        hex_decode(text.as_ref())
    }
}
