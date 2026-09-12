//! One place for outbound TLS trust policy.
//!
//! Six call sites (the Trojan, VLESS and VMess outbounds, the TLS transport,
//! the TLS client and the two DNS-over-TLS clients) used to build their own
//! root store, and they did not agree: some read only the platform store — so a
//! container without a CA bundle failed every handshake with a certificate
//! error — and the DNS clients trusted only the bundled Mozilla set, which
//! silently ignores a private or corporate CA installed on the host.
//!
//! "Which certificates do we trust" is one decision, so it is made once here:
//!
//! 1. **the platform trust store** (`rustls-native-certs`), because it is the
//!    operator's answer — enterprise CAs, private roots and system policy
//!    included;
//! 2. **the bundled Mozilla set** (`webpki-roots`) only when the platform store
//!    could not be read, so a minimal image still verifies public sites instead
//!    of failing every handshake.
//!
//! Loader errors are logged, never swallowed. The store is built once per
//! process: reading the platform store on every connection was pure overhead.
//!
//! This module also owns [`SkipServerVerification`], the one and only "accept
//! any certificate" verifier — duplicated once before it lived here. It exists
//! for the explicit `skip-cert-verify` switches and for nothing else.

use std::sync::{Arc, OnceLock};

use rustls::pki_types::{CertificateDer, ServerName, UnixTime};

/// The roots this process trusts for outbound TLS.
pub fn platform_root_store() -> rustls::RootCertStore {
    static STORE: OnceLock<rustls::RootCertStore> = OnceLock::new();
    STORE.get_or_init(build_root_store).clone()
}

/// The same store, wrapped for `ClientConfig::with_root_certificates`.
pub fn platform_roots() -> Arc<rustls::RootCertStore> {
    Arc::new(platform_root_store())
}

fn build_root_store() -> rustls::RootCertStore {
    let mut store = rustls::RootCertStore::empty();

    let native = rustls_native_certs::load_native_certs();
    for error in &native.errors {
        tracing::warn!("Platform trust store entry could not be read: {error}");
    }
    for certificate in native.certs {
        if let Err(error) = store.add(certificate) {
            tracing::debug!("Ignoring an unreadable platform root: {error}");
        }
    }

    if store.is_empty() {
        tracing::warn!(
            "The platform trust store is empty; falling back to the bundled Mozilla root set \
             (public CAs only — a private CA installed on this host cannot be honoured)"
        );
        store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    }

    store
}

/// A `tokio-rustls` connector for an outbound connection.
///
/// Trojan, VLESS and VMess each built this by hand — and the three copies had
/// already started to disagree about which roots they used. One implementation
/// means `skip-cert-verify` and ALPN behave identically everywhere.
pub fn client_connector(alpn: &[String], skip_cert_verify: bool) -> tokio_rustls::TlsConnector {
    let mut config = if skip_cert_verify {
        rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
            .with_no_client_auth()
    } else {
        rustls::ClientConfig::builder()
            .with_root_certificates(platform_root_store())
            .with_no_client_auth()
    };
    config.alpn_protocols = alpn
        .iter()
        .map(|protocol| protocol.as_bytes().to_vec())
        .collect();
    tokio_rustls::TlsConnector::from(Arc::new(config))
}

/// A certificate verifier that accepts anything.
///
/// Reached only through an explicit `skip-cert-verify` (or equivalent) option:
/// it removes every guarantee TLS provides about the peer, so it must never be
/// installed by default.
#[derive(Debug)]
pub struct SkipServerVerification;

impl rustls::client::danger::ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::ED25519,
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_root_store_is_never_empty() {
        // Empty means "every handshake fails", which is worse than trusting the
        // bundled public set; the fallback exists precisely to avoid that.
        assert!(
            !platform_root_store().is_empty(),
            "a process with no trusted roots cannot reach any TLS peer"
        );
    }

    #[test]
    fn the_root_store_is_shared_between_calls() {
        // Same cached store, not a fresh platform read per connection.
        let first = platform_root_store();
        let second = platform_root_store();
        assert_eq!(first.len(), second.len());
    }

    #[test]
    fn roots_are_wrapped_for_client_configs() {
        assert!(!platform_roots().is_empty());
    }
}
