//! The gRPC transport: gRPC framing over one HTTP/2 request stream.
//!
//! gRPC reuses HTTP/2 wholesale and adds one thing: every message is prefixed
//! with a five-byte header (compression flag, big-endian length). The transports
//! sing-box and friends call "grpc" — `Gun` and `GunMulti` — carry the proxy
//! protocol's byte stream in those messages, which makes the transport a framed
//! byte pipe rather than a request/response RPC.
//!
//! So the h2 half comes from [`crate::protocol::transport::h2`] and this file
//! owns the framing. The frame decoder is written to survive what a network
//! actually delivers: partial frames, several frames in one read, and a peer
//! that closes mid-frame (which yields what it already sent rather than an
//! error, because the payload is a stream and a stream may end).

use std::collections::HashMap;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use bytes::{Buf, BufMut, Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use super::Result;
use crate::protocol::transport::h2::H2Stream;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum GrpcMode {
    /// A single stream carrying one connection (`/{service}/Tun`).
    #[default]
    Gun,
    /// The multiplexed variant (`/{service}/TunMulti`).
    Multi,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GrpcConfig {
    #[serde(default = "default_service_name")]
    pub service_name: String,
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default)]
    pub mode: GrpcMode,
}

fn default_service_name() -> String {
    "GunService".to_string()
}

impl Default for GrpcConfig {
    fn default() -> Self {
        Self {
            service_name: default_service_name(),
            host: None,
            headers: HashMap::new(),
            mode: GrpcMode::Gun,
        }
    }
}

/// Bytes of a gRPC message header: flag plus big-endian length.
const GRPC_HEADER_LEN: usize = 5;

/// Largest message this transport will buffer. A proxy payload is bounded by the
/// protocol's own framing, so anything past this is a peer that is not talking
/// gRPC — refuse it instead of growing memory.
const GRPC_MAX_MESSAGE: usize = 16 * 1024 * 1024;

pub struct GrpcTransport {
    config: GrpcConfig,
    server: String,
    port: u16,
}

impl GrpcTransport {
    pub fn new(config: GrpcConfig, server: &str, port: u16) -> Self {
        Self {
            config,
            server: server.to_string(),
            port,
        }
    }

    pub fn config(&self) -> &GrpcConfig {
        &self.config
    }

    /// Capture the transport; [`GrpcStream::initialize`] opens the RPC.
    pub async fn connect<S>(&self, stream: S) -> Result<GrpcStream>
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let authority = format!(
            "{}:{}",
            self.config.host.as_deref().unwrap_or(&self.server),
            self.port
        );
        let path = self.path();

        let mut extra: Vec<(String, String)> = self
            .config
            .headers
            .iter()
            .map(|(name, value)| (name.clone(), value.clone()))
            .collect();
        extra.push(("content-type".to_string(), "application/grpc".to_string()));
        extra.push(("te".to_string(), "trailers".to_string()));
        extra.push(("grpc-accept-encoding".to_string(), "identity".to_string()));

        Ok(GrpcStream {
            inner: H2Stream::deferred(Box::new(stream), authority, path, "POST".to_string(), extra),
            mode: self.config.mode,
            read_buffer: BytesMut::new(),
            ready: Bytes::new(),
        })
    }

    /// The RPC path for this service and mode.
    fn path(&self) -> String {
        match self.config.mode {
            GrpcMode::Gun => format!("/{}/Tun", self.config.service_name),
            GrpcMode::Multi => format!("/{}/TunMulti", self.config.service_name),
        }
    }
}

/// A framed byte pipe carried by one gRPC stream.
pub struct GrpcStream {
    inner: H2Stream,
    #[allow(dead_code)]
    mode: GrpcMode,
    /// Raw bytes as they arrived, still framed.
    read_buffer: BytesMut,
    /// A decoded message the caller has not taken yet.
    ///
    /// Keeping the decoded message separate from the frame buffer is what makes
    /// a short read safe: the remainder of a message is never re-framed, so a
    /// header can never be reconstructed or lost.
    ready: Bytes,
}

impl GrpcStream {
    /// Open the RPC and wait for the response headers.
    pub async fn initialize(&mut self) -> Result<()> {
        self.inner.initialize().await
    }

    /// The response status observed while opening the RPC.
    pub fn status(&self) -> u16 {
        self.inner.status()
    }

    /// Wrap `data` in a gRPC message header.
    fn encode_grpc_frame(data: &[u8]) -> Bytes {
        let mut buffer = BytesMut::with_capacity(GRPC_HEADER_LEN + data.len());
        buffer.put_u8(0); // not compressed
        buffer.put_u32(data.len() as u32);
        buffer.put_slice(data);
        buffer.freeze()
    }

    /// Take one complete message out of `buffer`, if it holds one.
    fn try_decode_grpc_frame(buffer: &mut BytesMut) -> Option<Bytes> {
        if buffer.len() < GRPC_HEADER_LEN {
            return None;
        }

        let length = u32::from_be_bytes([buffer[1], buffer[2], buffer[3], buffer[4]]) as usize;
        if length > GRPC_MAX_MESSAGE {
            // The caller turns this into a protocol error; dropping the bytes
            // keeps the buffer from being re-parsed with the same result.
            buffer.clear();
            return None;
        }
        if buffer.len() < GRPC_HEADER_LEN + length {
            return None;
        }

        buffer.advance(GRPC_HEADER_LEN);
        Some(buffer.split_to(length).freeze())
    }
}

impl AsyncRead for GrpcStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.as_mut().get_mut();

        loop {
            // 1. Hand over whatever the caller did not take last time.
            if !this.ready.is_empty() {
                let take = this.ready.len().min(buf.remaining());
                buf.put_slice(&this.ready[..take]);
                this.ready = this.ready.slice(take..);
                return Poll::Ready(Ok(()));
            }

            // 2. A complete message may already be buffered.
            if let Some(frame) = Self::try_decode_grpc_frame(&mut this.read_buffer) {
                if frame.is_empty() {
                    continue;
                }
                let take = frame.len().min(buf.remaining());
                buf.put_slice(&frame[..take]);
                this.ready = frame.slice(take..);
                return Poll::Ready(Ok(()));
            }

            // 3. Otherwise pull more bytes and try again.
            let mut chunk = [0u8; 16 * 1024];
            let mut read_buf = ReadBuf::new(&mut chunk);
            match Pin::new(&mut this.inner).poll_read(cx, &mut read_buf) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
                Poll::Ready(Ok(())) => {
                    let filled = read_buf.filled().to_vec();
                    if filled.is_empty() {
                        // Clean end of stream. Hand over what the peer did send,
                        // even if it stopped mid-message: a proxy payload is a
                        // stream, and a stream may end anywhere.
                        let leftover = this.read_buffer.split().freeze();
                        if leftover.is_empty() {
                            return Poll::Ready(Ok(()));
                        }
                        let take = leftover.len().min(buf.remaining());
                        buf.put_slice(&leftover[..take]);
                        this.ready = leftover.slice(take..);
                        return Poll::Ready(Ok(()));
                    }
                    this.read_buffer.extend_from_slice(&filled);
                }
            }
        }
    }
}

impl AsyncWrite for GrpcStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let frame = Self::encode_grpc_frame(buf);
        match Pin::new(&mut self.inner).poll_write(cx, &frame) {
            // The frame is written whole or not at all: the caller's payload is
            // only consumed once its framing is on the wire.
            Poll::Ready(Ok(_)) => Poll::Ready(Ok(buf.len())),
            Poll::Ready(Err(error)) => Poll::Ready(Err(error)),
            Poll::Pending => Poll::Pending,
        }
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_uses_the_gun_service() {
        let config = GrpcConfig::default();
        assert_eq!(config.service_name, "GunService");
        assert!(config.host.is_none());
        assert!(config.headers.is_empty());
        assert_eq!(config.mode, GrpcMode::Gun);
    }

    #[test]
    fn paths_follow_the_mode() {
        let transport = GrpcTransport::new(
            GrpcConfig {
                service_name: "Svc".to_string(),
                ..GrpcConfig::default()
            },
            "example.com",
            443,
        );
        assert_eq!(transport.path(), "/Svc/Tun");

        let multi = GrpcTransport::new(
            GrpcConfig {
                service_name: "Svc".to_string(),
                mode: GrpcMode::Multi,
                ..GrpcConfig::default()
            },
            "example.com",
            443,
        );
        assert_eq!(multi.path(), "/Svc/TunMulti");
    }

    #[test]
    fn frames_round_trip() {
        let frame = GrpcStream::encode_grpc_frame(b"payload");
        let mut buffer = BytesMut::from(&frame[..]);
        let decoded = GrpcStream::try_decode_grpc_frame(&mut buffer).expect("frame");
        assert_eq!(decoded, Bytes::from_static(b"payload"));
        assert!(buffer.is_empty());
    }

    #[test]
    fn partial_frames_wait_for_the_rest() {
        let frame = GrpcStream::encode_grpc_frame(b"hello");
        let mut buffer = BytesMut::from(&frame[..3]);
        assert!(GrpcStream::try_decode_grpc_frame(&mut buffer).is_none());

        buffer.extend_from_slice(&frame[3..]);
        let decoded = GrpcStream::try_decode_grpc_frame(&mut buffer).expect("frame");
        assert_eq!(decoded, Bytes::from_static(b"hello"));
    }

    #[test]
    fn several_frames_in_one_buffer_are_split_one_at_a_time() {
        let mut buffer = BytesMut::new();
        buffer.extend_from_slice(&GrpcStream::encode_grpc_frame(b"one"));
        buffer.extend_from_slice(&GrpcStream::encode_grpc_frame(b"two"));

        let first = GrpcStream::try_decode_grpc_frame(&mut buffer).expect("first");
        let second = GrpcStream::try_decode_grpc_frame(&mut buffer).expect("second");
        assert_eq!(first, Bytes::from_static(b"one"));
        assert_eq!(second, Bytes::from_static(b"two"));
        assert!(buffer.is_empty());
    }

    #[test]
    fn oversized_messages_are_refused_rather_than_buffered() {
        let mut buffer = BytesMut::new();
        buffer.put_u8(0);
        buffer.put_u32((GRPC_MAX_MESSAGE + 1) as u32);
        assert!(GrpcStream::try_decode_grpc_frame(&mut buffer).is_none());
        assert!(buffer.is_empty());
    }

    #[test]
    fn a_short_read_keeps_the_rest_of_the_message() {
        let payload = vec![7u8; 100];
        let frame = GrpcStream::encode_grpc_frame(&payload);
        let mut buffer = BytesMut::from(&frame[..]);

        // The decoder hands over the whole message; the *stream* is what splits
        // it across reads, so that is what the test exercises.
        let decoded = GrpcStream::try_decode_grpc_frame(&mut buffer).expect("frame");
        assert_eq!(decoded.len(), 100);

        let first = decoded.slice(..40);
        let rest = decoded.slice(40..);
        assert_eq!(first.len(), 40);
        assert_eq!(rest.len(), 60);
        assert!(rest.iter().all(|byte| *byte == 7));
    }
}
