//! The `h2` transport: one HTTP/2 request stream used as a byte pipe.
//!
//! VMess and VLESS both offer an "h2" transport, and it is unusual: the payload
//! is not an HTTP body in any useful sense, it is the raw client↔server byte
//! stream of the protocol, carried inside a *single* request stream that both
//! ends keep half-open for the life of the connection. That shape rules out
//! every general-purpose HTTP client — they want to own the connection and to
//! finish a request — so the protocol machinery comes from
//! [`crate::protocol::http2`] and this file is only the transport's vocabulary:
//! where to send it, what to send, and how to hand the byte pipe to an outbound.
//!
//! The connection stays deferred: [`H2Transport::connect`] captures the raw
//! transport (a TLS session, a WebSocket, a hop through another outbound) and
//! [`H2Stream::initialize`] turns it into a stream, because the pseudonym
//! headers are not known until then.

use std::collections::HashMap;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use crate::protocol::http2;
use super::{Result, TransportError};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct H2Config {
    #[serde(default = "default_path")]
    pub path: String,
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default = "default_method")]
    pub method: String,
}

fn default_path() -> String {
    "/".to_string()
}

fn default_method() -> String {
    "POST".to_string()
}

impl Default for H2Config {
    fn default() -> Self {
        Self {
            path: default_path(),
            host: None,
            headers: HashMap::new(),
            method: default_method(),
        }
    }
}

/// Any transport this stream can ride on.
pub(crate) trait BoxedTransport: AsyncRead + AsyncWrite + Unpin + Send {}

impl<T> BoxedTransport for T where T: AsyncRead + AsyncWrite + Unpin + Send {}

pub struct H2Transport {
    config: H2Config,
    server: String,
    port: u16,
}

impl H2Transport {
    pub fn new(config: H2Config, server: &str, port: u16) -> Self {
        Self {
            config,
            server: server.to_string(),
            port,
        }
    }

    pub fn config(&self) -> &H2Config {
        &self.config
    }

    /// Capture the transport; [`H2Stream::initialize`] opens the request stream.
    pub async fn connect<S>(&self, stream: S) -> Result<H2Stream>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        Ok(H2Stream::deferred(
            Box::new(stream),
            self.authority(),
            self.config.path.clone(),
            self.config.method.clone(),
            Vec::new(),
        ))
    }

    /// `:authority` — the configured host, or the server we dialled.
    fn authority(&self) -> String {
        format!(
            "{}:{}",
            self.config.host.as_deref().unwrap_or(&self.server),
            self.port
        )
    }

    /// Extra header fields from the configuration, empty when none are set.
    pub fn extra_fields(&self) -> Vec<(String, String)> {
        self.config
            .headers
            .iter()
            .map(|(name, value)| (name.clone(), value.clone()))
            .collect()
    }
}

/// A byte pipe carried by one HTTP/2 request stream.
pub struct H2Stream {
    transport: Option<Box<dyn BoxedTransport>>,
    authority: String,
    path: String,
    method: String,
    extra: Vec<(String, String)>,
    stream: Option<http2::H2Stream>,
}

impl H2Stream {
    pub(crate) fn deferred(
        transport: Box<dyn BoxedTransport>,
        authority: String,
        path: String,
        method: String,
        extra: Vec<(String, String)>,
    ) -> Self {
        Self {
            transport: Some(transport),
            authority,
            path,
            method,
            extra,
            stream: None,
        }
    }

    /// Open the request stream and wait for the response headers.
    pub async fn initialize(&mut self) -> Result<()> {
        if self.stream.is_some() {
            return Ok(());
        }

        let transport = self.transport.take().ok_or_else(|| {
            TransportError::H2("the transport was already consumed".to_string())
        })?;

        let extra: Vec<(&str, &str)> = self
            .extra
            .iter()
            .map(|(name, value)| (name.as_str(), value.as_str()))
            .collect();
        let fields = http2::request_fields(&self.authority, &self.path, &self.method, &extra);

        let stream = http2::H2Stream::open(transport, fields).await?;
        let status = stream.status();
        if status != 0 && !(200..300).contains(&status) {
            return Err(TransportError::H2(format!(
                "the peer answered HTTP {status} instead of a stream"
            )));
        }

        self.stream = Some(stream);
        Ok(())
    }

    /// The response status observed while opening the stream.
    pub fn status(&self) -> u16 {
        self.stream.as_ref().map(http2::H2Stream::status).unwrap_or(0)
    }

    fn stream_mut(&mut self) -> io::Result<&mut http2::H2Stream> {
        self.stream.as_mut().ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotConnected, "H2 stream not initialized")
        })
    }
}

impl AsyncRead for H2Stream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let stream = match self.stream_mut() {
            Ok(stream) => stream,
            Err(error) => return Poll::Ready(Err(error)),
        };
        Pin::new(stream).poll_read(cx, buf)
    }
}

impl AsyncWrite for H2Stream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let stream = match self.stream_mut() {
            Ok(stream) => stream,
            Err(error) => return Poll::Ready(Err(error)),
        };
        Pin::new(stream).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let stream = match self.stream_mut() {
            Ok(stream) => stream,
            Err(error) => return Poll::Ready(Err(error)),
        };
        Pin::new(stream).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let stream = match self.stream_mut() {
            Ok(stream) => stream,
            Err(error) => return Poll::Ready(Err(error)),
        };
        Pin::new(stream).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_is_a_post_to_the_root() {
        let config = H2Config::default();
        assert_eq!(config.path, "/");
        assert!(config.host.is_none());
        assert!(config.headers.is_empty());
        assert_eq!(config.method, "POST");
    }

    #[test]
    fn authority_prefers_the_configured_host() {
        let mut config = H2Config::default();
        config.host = Some("front.example".to_string());
        let transport = H2Transport::new(config, "203.0.113.7", 8443);
        assert_eq!(transport.authority(), "front.example:8443");
    }

    #[test]
    fn authority_falls_back_to_the_dialled_server() {
        let transport = H2Transport::new(H2Config::default(), "203.0.113.7", 443);
        assert_eq!(transport.authority(), "203.0.113.7:443");
    }

    #[test]
    fn extra_fields_mirror_the_configuration() {
        let mut config = H2Config::default();
        config
            .headers
            .insert("x-custom".to_string(), "value".to_string());
        let transport = H2Transport::new(config, "example.com", 443);
        assert_eq!(
            transport.extra_fields(),
            vec![("x-custom".to_string(), "value".to_string())]
        );
    }

    #[test]
    fn config_round_trips_through_serde() {
        let mut headers = HashMap::new();
        headers.insert("authorization".to_string(), "Bearer t".to_string());
        let config = H2Config {
            path: "/api/stream".to_string(),
            host: Some("api.example.com".to_string()),
            headers,
            method: "PUT".to_string(),
        };

        let encoded = serde_json::to_string(&config).expect("serialize");
        let decoded: H2Config = serde_json::from_str(&encoded).expect("deserialize");
        assert_eq!(decoded.path, "/api/stream");
        assert_eq!(decoded.host.as_deref(), Some("api.example.com"));
        assert_eq!(decoded.method, "PUT");
        assert_eq!(decoded.headers.len(), 1);
    }
}
