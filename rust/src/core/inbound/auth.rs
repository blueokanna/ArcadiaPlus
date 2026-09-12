//! Inbound client authentication.
//!
//! VeloGuard advertises `authentication` in its configuration (and the UI can
//! set it), so the inbounds have to enforce it — otherwise a configured
//! username/password silently degrades into an open proxy.
//!
//! Two wire formats are needed, and both live here so the three inbounds
//! (http, socks5, mixed) cannot drift apart:
//!
//! * HTTP proxy: `Proxy-Authorization: Basic base64(user:password)`
//!   (RFC 9110 §11.7.1), answered with `407` + `Proxy-Authenticate`.
//! * SOCKS5: the username/password sub-negotiation of RFC 1929, selected
//!   during the greeting instead of `0x00` (no authentication).
//!
//! Credentials come from the global `authentication` list plus an optional
//! per-inbound `username` / `password` pair in the inbound options.
//!
//! Comparison is constant-time (length is still observable, as usual).

use crate::core::config::{AuthenticationConfig, InboundConfig};
use crate::core::error::{Error, Result};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// SOCKS5 version byte.
const SOCKS5_VERSION: u8 = 0x05;
/// "No authentication required" method (RFC 1928).
const SOCKS5_METHOD_NONE: u8 = 0x00;
/// "Username/password" method (RFC 1929).
const SOCKS5_METHOD_USERPASS: u8 = 0x02;
/// "No acceptable methods" reply (RFC 1928).
const SOCKS5_METHOD_UNACCEPTABLE: u8 = 0xFF;
/// Username/password sub-negotiation version (RFC 1929).
const SOCKS5_USERPASS_VERSION: u8 = 0x01;

/// Outcome of the SOCKS5 greeting, before the request is read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Socks5Greeting {
    /// A method was selected (client authenticated when required).
    Accepted,
    /// The first byte was not the SOCKS5 version.
    NotSocks5,
    /// The client offered no method we can use; `0xFF` was sent.
    NoAcceptableMethod,
}

/// Credentials that inbound clients must present.
#[derive(Debug, Clone, Default)]
pub struct AuthStore {
    users: Vec<(String, String)>,
}

impl AuthStore {
    /// Build the store from the global `authentication` list and, when
    /// present, the inbound's own `username` / `password` options.
    pub fn from_config(global: Option<&[AuthenticationConfig]>, inbound: &InboundConfig) -> Self {
        let mut users: Vec<(String, String)> = Vec::new();

        if let Some(entries) = global {
            for entry in entries {
                if !entry.username.is_empty() {
                    users.push((entry.username.clone(), entry.password.clone()));
                }
            }
        }

        if let (Some(username), Some(password)) = (
            inbound_option(inbound, "username"),
            inbound_option(inbound, "password"),
        ) {
            users.push((username, password));
        }

        if users.is_empty() {
            return Self::default();
        }

        tracing::info!(
            inbound = %inbound.tag,
            users = users.len(),
            "inbound authentication enabled"
        );
        Self { users }
    }

    /// Build a store directly from credentials (tests, programmatic setups).
    pub fn from_users(users: impl IntoIterator<Item = (String, String)>) -> Self {
        Self {
            users: users.into_iter().collect(),
        }
    }

    /// Whether clients must authenticate at all.
    pub fn is_enabled(&self) -> bool {
        !self.users.is_empty()
    }

    /// Verify a username/password pair.
    pub fn verify(&self, username: &str, password: &str) -> bool {
        self.users
            .iter()
            .any(|(user, pass)| constant_time_eq(user.as_bytes(), username.as_bytes())
                && constant_time_eq(pass.as_bytes(), password.as_bytes()))
    }

    /// Validate an HTTP `Proxy-Authorization` header value.
    ///
    /// A disabled store accepts everything, a malformed header never does.
    pub fn check_proxy_authorization(&self, header: Option<&str>) -> bool {
        if !self.is_enabled() {
            return true;
        }
        let Some(decoded) = header.and_then(parse_basic_credentials) else {
            return false;
        };
        self.verify(&decoded.0, &decoded.1)
    }

    /// Value for the `Proxy-Authenticate` response header.
    pub fn proxy_authenticate_value(&self) -> &'static str {
        "Basic realm=\"VeloGuard\""
    }

    /// Run the SOCKS5 greeting, requiring credentials when configured.
    pub async fn socks5_greeting<S>(&self, stream: &mut S) -> Result<Socks5Greeting>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let mut head = [0u8; 2];
        stream
            .read_exact(&mut head)
            .await
            .map_err(|err| Error::network(format!("Failed to read SOCKS5 greeting: {err}")))?;

        if head[0] != SOCKS5_VERSION {
            return Ok(Socks5Greeting::NotSocks5);
        }

        let mut methods = vec![0u8; usize::from(head[1])];
        stream
            .read_exact(&mut methods)
            .await
            .map_err(|err| Error::network(format!("Failed to read SOCKS5 methods: {err}")))?;

        let method = if self.is_enabled() {
            if methods.contains(&SOCKS5_METHOD_USERPASS) {
                SOCKS5_METHOD_USERPASS
            } else {
                reject_methods(stream).await?;
                return Ok(Socks5Greeting::NoAcceptableMethod);
            }
        } else if methods.contains(&SOCKS5_METHOD_NONE) {
            SOCKS5_METHOD_NONE
        } else if methods.contains(&SOCKS5_METHOD_USERPASS) {
            // Credentials are optional here; a client that only offers
            // username/password still gets a chance to authenticate.
            SOCKS5_METHOD_USERPASS
        } else {
            reject_methods(stream).await?;
            return Ok(Socks5Greeting::NoAcceptableMethod);
        };

        stream
            .write_all(&[SOCKS5_VERSION, method])
            .await
            .map_err(|err| Error::network(format!("Failed to send SOCKS5 method: {err}")))?;

        if method == SOCKS5_METHOD_USERPASS {
            self.socks5_userpass(stream).await?;
        }

        Ok(Socks5Greeting::Accepted)
    }

    /// RFC 1929 sub-negotiation, already selected by the caller.
    async fn socks5_userpass<S>(&self, stream: &mut S) -> Result<()>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let mut head = [0u8; 2];
        stream
            .read_exact(&mut head)
            .await
            .map_err(|err| Error::network(format!("Failed to read SOCKS5 credentials: {err}")))?;

        if head[0] != SOCKS5_USERPASS_VERSION {
            return Err(Error::protocol(format!(
                "Unsupported SOCKS5 auth version: {}",
                head[0]
            )));
        }

        let mut username = vec![0u8; usize::from(head[1])];
        stream.read_exact(&mut username).await.map_err(|err| {
            Error::network(format!("Failed to read SOCKS5 username: {err}"))
        })?;

        let mut password_len = [0u8; 1];
        stream.read_exact(&mut password_len).await.map_err(|err| {
            Error::network(format!("Failed to read SOCKS5 password length: {err}"))
        })?;

        let mut password = vec![0u8; usize::from(password_len[0])];
        stream.read_exact(&mut password).await.map_err(|err| {
            Error::network(format!("Failed to read SOCKS5 password: {err}"))
        })?;

        let username = String::from_utf8_lossy(&username).into_owned();
        let password = String::from_utf8_lossy(&password).into_owned();
        let accepted = self.verify(&username, &password);

        stream
            .write_all(&[
                SOCKS5_USERPASS_VERSION,
                if accepted { 0x00 } else { 0x01 },
            ])
            .await
            .map_err(|err| Error::network(format!("Failed to send SOCKS5 auth result: {err}")))?;

        if accepted {
            Ok(())
        } else {
            Err(Error::Auth {
                message: "SOCKS5 credentials rejected".to_string(),
                username: Some(username),
            })
        }
    }
}

async fn reject_methods<S>(stream: &mut S) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    stream
        .write_all(&[SOCKS5_VERSION, SOCKS5_METHOD_UNACCEPTABLE])
        .await
        .map_err(|err| Error::network(format!("Failed to send SOCKS5 method reply: {err}")))
}

fn inbound_option(inbound: &InboundConfig, key: &str) -> Option<String> {
    match inbound.options.get(key) {
        Some(serde_yaml::Value::String(value)) if !value.is_empty() => Some(value.clone()),
        Some(serde_yaml::Value::Number(number)) => Some(number.to_string()),
        _ => None,
    }
}

/// Parse `Basic base64(user:password)`.
fn parse_basic_credentials(header: &str) -> Option<(String, String)> {
    let (scheme, encoded) = header.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("basic") {
        return None;
    }
    let decoded = decode_base64(encoded.trim())?;
    let text = String::from_utf8(decoded).ok()?;
    let (username, password) = text.split_once(':')?;
    Some((username.to_string(), password.to_string()))
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut diff = 0u8;
    for (lhs, rhs) in left.iter().zip(right.iter()) {
        diff |= lhs ^ rhs;
    }
    diff == 0
}

/// Minimal standard-alphabet base64 decoder (the workspace deliberately has no
/// base64 dependency).
fn decode_base64(input: &str) -> Option<Vec<u8>> {
    fn value(byte: u8) -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let mut output = Vec::with_capacity(input.len() / 4 * 3);
    let mut accumulator = 0u32;
    let mut bits = 0u32;
    let mut padding = 0usize;

    for byte in input.bytes() {
        if byte == b'=' {
            padding += 1;
            continue;
        }
        if padding > 0 {
            // Data after padding is not valid base64.
            return None;
        }
        let digit = u32::from(value(byte)?);
        accumulator = (accumulator << 6) | digit;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push((accumulator >> bits) as u8);
        }
    }

    if bits > 4 {
        return None;
    }
    // Left-over bits must be zero, otherwise the encoding is malformed.
    if accumulator & ((1 << bits) - 1) != 0 {
        return None;
    }
    Some(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::config::InboundType;
    use std::collections::HashMap;

    fn inbound_with_options(options: Vec<(&str, serde_yaml::Value)>) -> InboundConfig {
        InboundConfig {
            inbound_type: InboundType::Mixed,
            tag: "test-inbound".to_string(),
            listen: "127.0.0.1".to_string(),
            port: 7890,
            options: options
                .into_iter()
                .map(|(key, value)| (key.to_string(), value))
                .collect::<HashMap<_, _>>(),
        }
    }

    fn credentials() -> AuthenticationConfig {
        AuthenticationConfig {
            username: "alice".to_string(),
            password: "s3cret".to_string(),
        }
    }

    #[test]
    fn decodes_base64_padding_variants() {
        assert_eq!(decode_base64("YWxpY2U6czNjcmV0").unwrap(), b"alice:s3cret");
        assert_eq!(decode_base64("YQ==").unwrap(), b"a");
        assert_eq!(decode_base64("YWI=").unwrap(), b"ab");
        assert_eq!(decode_base64("YWJj").unwrap(), b"abc");
        assert!(decode_base64("YQ=a").is_none());
        assert!(decode_base64("!!!").is_none());
    }

    #[test]
    fn disabled_store_accepts_everything() {
        let store = AuthStore::default();
        assert!(!store.is_enabled());
        assert!(store.check_proxy_authorization(None));
    }

    #[test]
    fn http_basic_header_is_checked() {
        let store = AuthStore::from_users([("alice".to_string(), "s3cret".to_string())]);
        assert!(store.is_enabled());
        assert!(store.check_proxy_authorization(Some("Basic YWxpY2U6czNjcmV0")));
        assert!(store.check_proxy_authorization(Some("basic YWxpY2U6czNjcmV0")));
        assert!(!store.check_proxy_authorization(Some("Basic YWxpY2U6d3Jvbmc=")));
        assert!(!store.check_proxy_authorization(Some("Bearer YWxpY2U6czNjcmV0")));
        assert!(!store.check_proxy_authorization(None));
    }

    #[test]
    fn global_and_per_inbound_credentials_are_merged() {
        let inbound = inbound_with_options(vec![
            ("username", serde_yaml::Value::String("bob".to_string())),
            ("password", serde_yaml::Value::String("hunter2".to_string())),
        ]);
        let store = AuthStore::from_config(Some(&[credentials()]), &inbound);
        assert_eq!(store.users.len(), 2);
        assert!(store.verify("alice", "s3cret"));
        assert!(store.verify("bob", "hunter2"));
        assert!(!store.verify("bob", "s3cret"));
    }

    #[test]
    fn empty_global_list_keeps_inbound_single_user() {
        let inbound = inbound_with_options(vec![
            ("username", serde_yaml::Value::String("bob".to_string())),
            ("password", serde_yaml::Value::String("hunter2".to_string())),
        ]);
        let store = AuthStore::from_config(None, &inbound);
        assert!(store.verify("bob", "hunter2"));
    }

    #[tokio::test]
    async fn socks5_without_auth_is_accepted_when_disabled() {
        let store = AuthStore::default();
        let (mut client, mut server) = tokio::io::duplex(64);
        client.write_all(&[0x05, 0x01, 0x00]).await.unwrap();

        let greeting = store.socks5_greeting(&mut server).await.unwrap();
        assert_eq!(greeting, Socks5Greeting::Accepted);

        let mut reply = [0u8; 2];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply, [0x05, 0x00]);
    }

    #[tokio::test]
    async fn socks5_requires_credentials_when_enabled() {
        let store = AuthStore::from_users([("alice".to_string(), "s3cret".to_string())]);
        let (mut client, mut server) = tokio::io::duplex(64);
        // Only "no auth" offered: the server must refuse.
        client.write_all(&[0x05, 0x01, 0x00]).await.unwrap();

        let greeting = store.socks5_greeting(&mut server).await.unwrap();
        assert_eq!(greeting, Socks5Greeting::NoAcceptableMethod);

        let mut reply = [0u8; 2];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply, [0x05, 0xFF]);
    }

    #[tokio::test]
    async fn socks5_userpass_success_and_failure() {
        // Success
        let store = AuthStore::from_users([("alice".to_string(), "s3cret".to_string())]);
        let (mut client, mut server) = tokio::io::duplex(128);
        client.write_all(&[0x05, 0x02, 0x00, 0x02]).await.unwrap();
        client
            .write_all(&[0x01, 5, b'a', b'l', b'i', b'c', b'e', 6, b's', b'3', b'c', b'r', b'e', b't'])
            .await
            .unwrap();

        let greeting = store.socks5_greeting(&mut server).await.unwrap();
        assert_eq!(greeting, Socks5Greeting::Accepted);

        let mut reply = [0u8; 4];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply, [0x05, 0x02, 0x01, 0x00]);

        // Wrong password
        let (mut client, mut server) = tokio::io::duplex(128);
        client.write_all(&[0x05, 0x01, 0x02]).await.unwrap();
        client
            .write_all(&[0x01, 5, b'a', b'l', b'i', b'c', b'e', 5, b'w', b'r', b'o', b'n', b'g'])
            .await
            .unwrap();

        let err = store
            .socks5_greeting(&mut server)
            .await
            .expect_err("wrong password must fail");
        assert!(err.to_string().contains("rejected"), "{err}");

        let mut reply = [0u8; 4];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply[3], 0x01, "failure status must be reported");
    }

    #[tokio::test]
    async fn socks5_non_version_byte_is_reported() {
        let store = AuthStore::default();
        let (mut client, mut server) = tokio::io::duplex(16);
        client.write_all(b"GET ").await.unwrap();
        let greeting = store.socks5_greeting(&mut server).await.unwrap();
        assert_eq!(greeting, Socks5Greeting::NotSocks5);
    }
}
