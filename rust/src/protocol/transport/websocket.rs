//! The WebSocket transport: an RFC 6455 client used as a byte pipe.
//!
//! VMess, VLESS and Trojan all offer a `ws` transport, and what they need from
//! WebSocket is only the framing — the payload is an opaque byte stream. This
//! module implements exactly that, on top of a stream the caller already
//! established (TLS or plain TCP):
//!
//! * **Handshake.** A client upgrade request with a fresh `Sec-WebSocket-Key`
//!   from the in-house CSPRNG, and a strict answer check: `101`, an
//!   `Upgrade: websocket` token, and a `Sec-WebSocket-Accept` that matches
//!   `base64(SHA-1(key + GUID))`. A server that answers `200` is rejected —
//!   accepting it would silently proxy plain HTTP into a frame decoder.
//! * **Framing.** Client frames are masked with a fresh key per frame (RFC 6455
//!   §5.3), server frames must *not* be masked (§5.1) and a masked one is a
//!   protocol error, control frames are length-bounded and never fragmented,
//!   and a fragmented message is reassembled under a hard ceiling.
//! * **Control traffic.** `PING` is answered with `PONG` carrying the same
//!   payload, even while the reader is between messages; `CLOSE` is echoed with
//!   its status code and ends the stream.
//!
//! Byte-level work is deliberate: a transport that feeds a tunnel must not
//! rewrite payloads, and must not let a peer's framing choices (fragmentation,
//! control interleaving) escape as anything but bytes.

use std::collections::HashMap;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use bytes::BytesMut;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::io::{ReadHalf, WriteHalf};

use crate::crypto::base64::Engine;
use crate::crypto::base64::STANDARD;
use crate::crypto::{Digest, Sha1, random_bytes};
use crate::protocol::h1_server::{parse_header_lines, read_head_block};

use super::{Result, TransportError};

/// Continuation of a fragmented message.
const OP_CONTINUATION: u8 = 0x0;
/// A text message (we do not interpret it; the tunnel is byte-oriented).
const OP_TEXT: u8 = 0x1;
/// A binary message.
const OP_BINARY: u8 = 0x2;
/// Close the connection.
const OP_CLOSE: u8 = 0x8;
/// Liveness check.
const OP_PING: u8 = 0x9;
/// Reply to a ping.
const OP_PONG: u8 = 0xA;

/// Cap on a single frame payload.
///
/// The RFC leaves this to the implementation; 16 MiB is far above any proxy
/// payload chunk and far below "a peer can ask us to allocate 2^63 bytes".
const MAX_FRAME_PAYLOAD: usize = 16 * 1024 * 1024;

/// Cap on a reassembled fragmented message.
const MAX_MESSAGE: usize = 16 * 1024 * 1024;

/// Cap on a control frame payload (RFC 6455 §5.5).
const MAX_CONTROL_PAYLOAD: usize = 125;

/// Cap on the upgrade response head.
const MAX_HANDSHAKE_HEAD: usize = 16 * 1024;

/// The GUID RFC 6455 §1.3 appends to the client key.
const WS_GUID: &[u8] = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Status code "normal closure" (RFC 6455 §7.4.1).
const CLOSE_NORMAL: [u8; 2] = [0x03, 0xE8];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebSocketConfig {
    #[serde(default = "default_path")]
    pub path: String,
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default)]
    pub max_early_data: usize,
    #[serde(default)]
    pub early_data_header: Option<String>,
}

fn default_path() -> String {
    "/".to_string()
}

impl Default for WebSocketConfig {
    fn default() -> Self {
        Self {
            path: default_path(),
            host: None,
            headers: HashMap::new(),
            max_early_data: 0,
            early_data_header: None,
        }
    }
}

/// A WebSocket client bound to one server.
pub struct WebSocketTransport {
    config: WebSocketConfig,
    server: String,
    port: u16,
    use_tls: bool,
}

impl WebSocketTransport {
    pub fn new(config: WebSocketConfig, server: &str, port: u16, use_tls: bool) -> Self {
        Self {
            config,
            server: server.to_string(),
            port,
            use_tls,
        }
    }

    pub fn config(&self) -> &WebSocketConfig {
        &self.config
    }

    /// Upgrade `stream` to WebSocket.
    pub async fn connect<S>(&self, stream: S) -> Result<WsStream<S>>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let path = self.config.path.clone();
        self.handshake(stream, &path).await
    }

    /// Upgrade `stream`, carrying `early_data` in the request URL.
    ///
    /// The early bytes ride in the query string so the first application data
    /// arrives with the handshake — one round trip less on a protocol that
    /// otherwise sends a greeting immediately after the upgrade.
    pub async fn connect_with_early_data<S>(
        &self,
        stream: S,
        early_data: &[u8],
    ) -> Result<WsStream<S>>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        if early_data.is_empty() || self.config.max_early_data == 0 {
            return self.connect(stream).await;
        }

        let capped = &early_data[..early_data.len().min(self.config.max_early_data)];
        let encoded = STANDARD.encode(capped);

        let path = match &self.config.early_data_header {
            Some(header) => format!("{}?{}={}", self.config.path, header, encoded),
            None => format!("{}?ed={}", self.config.path, encoded),
        };

        self.handshake(stream, &path).await
    }

    /// Perform the client handshake and wrap the stream.
    async fn handshake<S>(&self, mut stream: S, path: &str) -> Result<WsStream<S>>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let host = self.config.host.as_deref().unwrap_or(&self.server);

        let mut key_material = [0u8; 16];
        random_bytes(&mut key_material);
        let key = STANDARD.encode(key_material);

        // RFC 6455 §4.1: the `Host` field carries the authority, and the port
        // is omitted when it is the scheme default.
        let authority = if (self.use_tls && self.port == 443) || (!self.use_tls && self.port == 80)
        {
            host.to_string()
        } else {
            format!("{host}:{}", self.port)
        };

        let mut request = format!(
            "GET {path} HTTP/1.1\r\n\
             Host: {authority}\r\n\
             Upgrade: websocket\r\n\
             Connection: Upgrade\r\n\
             Sec-WebSocket-Key: {key}\r\n\
             Sec-WebSocket-Version: 13\r\n"
        );

        for (name, value) in &self.config.headers {
            // A header that contains CR/LF would split the request into two
            // messages; refusing here is cheaper than detecting the smuggling
            // attempt downstream.
            if name.contains(['\r', '\n']) || value.contains(['\r', '\n']) {
                return Err(TransportError::InvalidConfig(format!(
                    "WebSocket header '{name}' contains a line break"
                )));
            }
            request.push_str(&format!("{name}: {value}\r\n"));
        }
        request.push_str("\r\n");

        stream
            .write_all(request.as_bytes())
            .await
            .map_err(TransportError::Io)?;
        stream.flush().await.map_err(TransportError::Io)?;

        let mut buffer = BytesMut::with_capacity(2048);
        let head = read_head_block(&mut stream, &mut buffer, MAX_HANDSHAKE_HEAD)
            .await
            .map_err(TransportError::Io)?
            .ok_or_else(|| {
                TransportError::Handshake(
                    "the server closed before answering the upgrade request".to_string(),
                )
            })?;

        Self::check_upgrade(&head, &key)?;

        // Bytes read past the head are the first frames: the server may speak
        // the moment it accepts.
        Ok(WsStream::new(stream, buffer))
    }

    /// Validate the upgrade answer.
    fn check_upgrade(head: &[u8], key: &str) -> Result<()> {
        let text = std::str::from_utf8(head)
            .map_err(|_| TransportError::Handshake("the upgrade answer is not UTF-8".to_string()))?;

        let mut lines = text.split("\r\n");
        let status_line = lines
            .next()
            .ok_or_else(|| TransportError::Handshake("empty upgrade answer".to_string()))?;

        let (status, _version) = courierust::courierust_h1::parse_status_line(status_line.as_bytes())
            .map_err(|error| TransportError::Handshake(format!("malformed status line: {error}")))?;

        if status.as_u16() != 101 {
            return Err(TransportError::Handshake(format!(
                "the server answered {} instead of 101",
                status.as_u16()
            )));
        }

        let headers = parse_header_lines(lines).map_err(TransportError::Io)?;

        // Both fields are token lists, not exact strings: `Upgrade: websocket`
        // may arrive as part of a list, and `Connection` normally is one.
        let has_upgrade = headers
            .get("upgrade")
            .and_then(|value| value.to_str().ok())
            .map(|value| {
                value
                    .split(',')
                    .any(|token| token.trim().eq_ignore_ascii_case("websocket"))
            })
            .unwrap_or(false);
        if !has_upgrade {
            return Err(TransportError::Handshake(
                "the answer does not upgrade to websocket".to_string(),
            ));
        }

        let has_connection = headers
            .get("connection")
            .and_then(|value| value.to_str().ok())
            .map(|value| {
                value
                    .split(',')
                    .any(|token| token.trim().eq_ignore_ascii_case("upgrade"))
            })
            .unwrap_or(false);
        if !has_connection {
            return Err(TransportError::Handshake(
                "the answer does not carry Connection: Upgrade".to_string(),
            ));
        }

        let expected = accept_key(key);
        let actual = headers
            .get("sec-websocket-accept")
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default();
        if actual != expected {
            return Err(TransportError::Handshake(
                "Sec-WebSocket-Accept does not match the client key".to_string(),
            ));
        }

        Ok(())
    }
}

/// `base64(SHA-1(key + GUID))` — the value the server must echo (RFC 6455 §4.2.2).
pub fn accept_key(key: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(key.as_bytes());
    hasher.update(WS_GUID);
    STANDARD.encode(hasher.finalize())
}

/// A WebSocket connection used as a byte stream.
///
/// Reads deliver one message worth of bytes at a time; writes produce one
/// binary frame per call. Both directions are poll-based, so a `WsStream` can
/// be handed to `tokio::io::copy` like any other socket.
pub struct WsStream<S> {
    stream: S,
    read: ReadState,
    write: FrameQueue,
    close_sent: bool,
}

impl<S> WsStream<S> {
    /// Wrap a stream whose handshake is already done; `pending` holds any bytes
    /// that were read past the upgrade answer.
    pub fn new(stream: S, pending: BytesMut) -> Self {
        Self {
            stream,
            read: ReadState::new(pending),
            write: FrameQueue::new(),
            close_sent: false,
        }
    }

    /// Hand back the underlying stream.
    pub fn into_inner(self) -> S {
        self.stream
    }
}

impl<S> WsStream<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    /// Split into a writer and a reader that can be moved independently.
    pub fn split(self) -> (WsSink<S>, WsReader<S>) {
        let (read, write) = tokio::io::split(self);
        (WsSink { inner: write }, WsReader { inner: read })
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncRead for WsStream<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();

        loop {
            if let Some(error) = this.read.failed.take() {
                return Poll::Ready(Err(error));
            }

            // Deliver whatever a previous poll decoded. A control reply queued
            // while decoding (a pong, say) is pushed out first — but never at
            // the cost of the data the caller is waiting for: a blocked write
            // just leaves the frame queued, with a waker registered for the
            // next poll.
            if this.read.decoded_offset < this.read.decoded.len() {
                if let Poll::Ready(Err(error)) =
                    flush_queue(&mut this.write, Pin::new(&mut this.stream), cx)
                {
                    return Poll::Ready(Err(error));
                }

                let remaining = &this.read.decoded[this.read.decoded_offset..];
                let count = remaining.len().min(buf.remaining());
                buf.put_slice(&remaining[..count]);
                this.read.decoded_offset += count;
                if this.read.decoded_offset >= this.read.decoded.len() {
                    this.read.decoded.clear();
                    this.read.decoded_offset = 0;
                }
                return Poll::Ready(Ok(()));
            }

            // A close frame ends the stream, but its reply still has to reach
            // the peer: flush first, and only report EOF once it is out (or the
            // socket refuses it, which means the peer is gone anyway).
            if this.read.seen_close {
                match flush_queue(&mut this.write, Pin::new(&mut this.stream), cx) {
                    Poll::Ready(Ok(())) | Poll::Ready(Err(_)) => return Poll::Ready(Ok(())),
                    Poll::Pending => return Poll::Pending,
                }
            }

            // Parse whatever is already buffered.
            match try_read_frame(&mut this.read.buffer) {
                Ok(Some(frame)) => {
                    if let Err(error) = this.handle_frame(frame) {
                        this.read.failed = Some(error);
                        continue;
                    }
                    continue;
                }
                Ok(None) => {}
                Err(error) => return Poll::Ready(Err(error)),
            }

            // Control replies (a pong, or our close echo) must not wait for a
            // write call that may never come.
            match flush_queue(&mut this.write, Pin::new(&mut this.stream), cx) {
                Poll::Ready(Ok(())) => {}
                Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
                Poll::Pending => return Poll::Pending,
            }

            let mut chunk = [0u8; 8 * 1024];
            let mut incoming = ReadBuf::new(&mut chunk);
            match Pin::new(&mut this.stream).poll_read(cx, &mut incoming) {
                Poll::Ready(Ok(())) => {
                    let filled = incoming.filled();
                    if filled.is_empty() {
                        // EOF: legal between messages, not inside one.
                        if this.read.buffer.is_empty() && !this.read.fragments_open {
                            this.read.seen_close = true;
                            continue;
                        }
                        return Poll::Ready(Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            "the WebSocket closed in the middle of a frame",
                        )));
                    }
                    if this.read.buffer.len() + filled.len() > MAX_MESSAGE + MAX_FRAME_PAYLOAD {
                        return Poll::Ready(Err(protocol_error(
                            "the peer is buffering faster than the limit allows",
                        )));
                    }
                    this.read.buffer.extend_from_slice(filled);
                }
                Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
                Poll::Pending => return Poll::Pending,
            }
        }
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncWrite for WsStream<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        let this = self.get_mut();

        if this.close_sent || this.read.seen_close {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "the WebSocket is closing",
            )));
        }

        if buf.is_empty() {
            return Poll::Ready(Ok(0));
        }

        // An unfinished frame must reach the wire before the next one starts;
        // interleaving two frames would produce a stream no peer can parse.
        match flush_queue(&mut this.write, Pin::new(&mut this.stream), cx) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }

        if let Err(detail) = this.write.push(OP_BINARY, true, buf) {
            return Poll::Ready(Err(protocol_error(&detail)));
        }

        // The bytes are queued: a caller that never flushes still has them
        // written on the next poll, and `poll_flush` finishes the job. A write
        // error is surfaced here rather than swallowed — the frame is already
        // in the queue, so losing the error would turn a dead socket into a
        // silent stall.
        if let Poll::Ready(Err(error)) = flush_queue(&mut this.write, Pin::new(&mut this.stream), cx)
        {
            return Poll::Ready(Err(error));
        }
        Poll::Ready(Ok(buf.len()))
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();

        match flush_queue(&mut this.write, Pin::new(&mut this.stream), cx) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }

        Pin::new(&mut this.stream).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();

        // RFC 6455 §7.1.1: a close frame with a normal status, sent once.
        if !this.close_sent {
            if let Err(detail) = this.write.push(OP_CLOSE, true, &CLOSE_NORMAL) {
                return Poll::Ready(Err(protocol_error(&detail)));
            }
            this.close_sent = true;
        }

        match flush_queue(&mut this.write, Pin::new(&mut this.stream), cx) {
            Poll::Ready(Ok(())) => {}
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }

        Pin::new(&mut this.stream).poll_shutdown(cx)
    }
}

impl<S> WsStream<S> {
    /// Route one decoded frame.
    fn handle_frame(&mut self, frame: Frame) -> io::Result<()> {
        match frame.opcode {
            OP_CONTINUATION => {
                if !self.read.fragments_open {
                    return Err(protocol_error(
                        "a continuation frame arrived without an open message",
                    ));
                }
                self.push_fragment(&frame.payload)?;
                if frame.fin {
                    self.finish_fragment();
                }
            }
            OP_TEXT | OP_BINARY => {
                if self.read.fragments_open {
                    return Err(protocol_error(
                        "a new data frame arrived inside a fragmented message",
                    ));
                }
                if frame.fin {
                    self.read.decoded = frame.payload;
                    self.read.decoded_offset = 0;
                } else {
                    self.read.message = frame.payload;
                    self.read.fragments_open = true;
                }
            }
            OP_PING => {
                // §5.5.3: the pong must carry the ping's application data.
                self.write.push(OP_PONG, true, &frame.payload).map_err(|detail| {
                    protocol_error(&format!("could not answer a ping: {detail}"))
                })?;
            }
            OP_PONG => {}
            OP_CLOSE => {
                // §5.5.1: echo the status code, or an empty close if the peer
                // sent none.
                let status: &[u8] = if frame.payload.len() >= 2 {
                    &frame.payload[..2]
                } else {
                    &[]
                };
                self.write
                    .push(OP_CLOSE, true, status)
                    .map_err(|detail| protocol_error(&format!("could not answer a close: {detail}")))?;
                self.close_sent = true;
                self.read.seen_close = true;
            }
            other => {
                return Err(protocol_error(&format!(
                    "unknown opcode 0x{other:x}"
                )));
            }
        }

        Ok(())
    }

    /// Append a continuation payload to the message under assembly.
    fn push_fragment(&mut self, payload: &[u8]) -> io::Result<()> {
        if self.read.message.len().saturating_add(payload.len()) > MAX_MESSAGE {
            return Err(protocol_error("the fragmented message exceeded the limit"));
        }
        self.read.message.extend_from_slice(payload);
        Ok(())
    }

    /// Publish a completed fragmented message to the reader.
    fn finish_fragment(&mut self) {
        self.read.decoded = std::mem::take(&mut self.read.message);
        self.read.decoded_offset = 0;
        self.read.fragments_open = false;
    }
}

/// The reader half of [`WsStream::split`].
pub struct WsReader<S> {
    inner: ReadHalf<WsStream<S>>,
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncRead for WsReader<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

/// The writer half of [`WsStream::split`].
pub struct WsSink<S> {
    inner: WriteHalf<WsStream<S>>,
}

impl<S: AsyncRead + AsyncWrite + Unpin> AsyncWrite for WsSink<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// What the reader has assembled so far.
struct ReadState {
    /// Raw socket bytes not yet decoded into frames.
    buffer: BytesMut,
    /// Payload of the message currently being reassembled.
    message: BytesMut,
    /// Whether a fragmented message is in progress.
    fragments_open: bool,
    /// The message ready for the caller.
    decoded: BytesMut,
    /// How much of `decoded` has been handed out.
    decoded_offset: usize,
    /// The peer closed (or a close is being answered).
    seen_close: bool,
    /// A protocol error to report on the next read.
    failed: Option<io::Error>,
}

impl ReadState {
    fn new(pending: BytesMut) -> Self {
        Self {
            buffer: pending,
            message: BytesMut::new(),
            fragments_open: false,
            decoded: BytesMut::new(),
            decoded_offset: 0,
            seen_close: false,
            failed: None,
        }
    }
}

/// Bytes waiting to go out, frames already serialized and masked.
struct FrameQueue {
    bytes: Vec<u8>,
    offset: usize,
}

impl FrameQueue {
    fn new() -> Self {
        Self {
            bytes: Vec::new(),
            offset: 0,
        }
    }

    fn is_empty(&self) -> bool {
        self.offset >= self.bytes.len()
    }

    /// Serialize one masked client frame onto the queue.
    fn push(&mut self, opcode: u8, fin: bool, payload: &[u8]) -> std::result::Result<(), String> {
        if payload.len() > MAX_FRAME_PAYLOAD {
            return Err("frame payload exceeds the limit".to_string());
        }

        let mut mask = [0u8; 4];
        random_bytes(&mut mask);

        self.bytes.push(if fin { 0x80 | opcode } else { opcode });

        let len = payload.len();
        if len < 126 {
            self.bytes.push(0x80 | len as u8);
        } else if len <= u16::MAX as usize {
            self.bytes.push(0x80 | 126);
            self.bytes.extend_from_slice(&(len as u16).to_be_bytes());
        } else {
            self.bytes.push(0x80 | 127);
            self.bytes.extend_from_slice(&(len as u64).to_be_bytes());
        }

        self.bytes.extend_from_slice(&mask);
        let payload_start = self.bytes.len();
        self.bytes.extend_from_slice(payload);
        mask_in_place(&mut self.bytes[payload_start..], mask);

        Ok(())
    }

    /// Drop the bytes that reached the wire.
    fn compact(&mut self) {
        if self.is_empty() {
            self.bytes.clear();
            self.offset = 0;
        } else if self.offset >= 64 * 1024 {
            self.bytes.drain(..self.offset);
            self.offset = 0;
        }
    }
}

/// Push queued frames to the socket.
fn flush_queue<S: AsyncWrite + Unpin>(
    queue: &mut FrameQueue,
    mut stream: Pin<&mut S>,
    cx: &mut Context<'_>,
) -> Poll<io::Result<()>> {
    while !queue.is_empty() {
        match stream.as_mut().poll_write(cx, &queue.bytes[queue.offset..]) {
            Poll::Ready(Ok(0)) => {
                return Poll::Ready(Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "the socket stopped accepting bytes",
                )));
            }
            Poll::Ready(Ok(written)) => queue.offset += written,
            Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
            Poll::Pending => return Poll::Pending,
        }
    }

    queue.compact();
    Poll::Ready(Ok(()))
}

/// A decoded frame.
#[derive(Debug)]
struct Frame {
    fin: bool,
    opcode: u8,
    payload: BytesMut,
}

/// Decode one frame from `buffer`, consuming it only when complete.
fn try_read_frame(buffer: &mut BytesMut) -> io::Result<Option<Frame>> {
    if buffer.len() < 2 {
        return Ok(None);
    }

    let first = buffer[0];
    let second = buffer[1];

    if first & 0x70 != 0 {
        return Err(protocol_error("reserved bits are set"));
    }
    let fin = first & 0x80 != 0;
    let opcode = first & 0x0F;

    if second & 0x80 != 0 {
        // RFC 6455 §5.1: a client MUST fail the connection when it receives a
        // masked frame; only clients mask.
        return Err(protocol_error("a server frame must not be masked"));
    }

    let short_len = (second & 0x7F) as usize;
    let mut cursor = 2;
    let payload_len = match short_len {
        126 => {
            if buffer.len() < cursor + 2 {
                return Ok(None);
            }
            let len = u16::from_be_bytes([buffer[cursor], buffer[cursor + 1]]) as usize;
            cursor += 2;
            len
        }
        127 => {
            if buffer.len() < cursor + 8 {
                return Ok(None);
            }
            let mut raw = [0u8; 8];
            raw.copy_from_slice(&buffer[cursor..cursor + 8]);
            cursor += 8;
            let len = u64::from_be_bytes(raw);
            if len & (1 << 63) != 0 {
                return Err(protocol_error("the frame length has its high bit set"));
            }
            if len > MAX_FRAME_PAYLOAD as u64 {
                return Err(protocol_error("the frame payload exceeds the limit"));
            }
            len as usize
        }
        len => len,
    };

    let is_control = opcode & 0x08 != 0;
    if is_control {
        if !fin {
            return Err(protocol_error("control frames must not be fragmented"));
        }
        if payload_len > MAX_CONTROL_PAYLOAD {
            return Err(protocol_error("control frame payload exceeds 125 bytes"));
        }
        if !matches!(opcode, OP_CLOSE | OP_PING | OP_PONG) {
            return Err(protocol_error("unknown control opcode"));
        }
    } else if !matches!(opcode, OP_CONTINUATION | OP_TEXT | OP_BINARY) {
        return Err(protocol_error("unknown data opcode"));
    }

    if payload_len > MAX_FRAME_PAYLOAD {
        return Err(protocol_error("the frame payload exceeds the limit"));
    }

    if buffer.len() < cursor + payload_len {
        return Ok(None);
    }

    let _head = buffer.split_to(cursor);
    let payload = buffer.split_to(payload_len);

    Ok(Some(Frame {
        fin,
        opcode,
        payload,
    }))
}

/// XOR `payload` with the four-byte masking key (RFC 6455 §5.3).
fn mask_in_place(payload: &mut [u8], mask: [u8; 4]) {
    for (index, byte) in payload.iter_mut().enumerate() {
        *byte ^= mask[index & 3];
    }
}

/// A protocol violation, as an IO error so it travels the stream traits.
fn protocol_error(detail: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("WebSocket protocol error: {detail}"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    #[test]
    fn accept_key_matches_rfc_6455() {
        // RFC 6455 §1.3: this key must produce this accept value.
        assert_eq!(
            accept_key("dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        );
    }

    /// Decode a client (masked) frame, the mirror of `try_read_frame`.
    fn decode_client_frame(bytes: &[u8]) -> (bool, u8, Vec<u8>) {
        let fin = bytes[0] & 0x80 != 0;
        let opcode = bytes[0] & 0x0F;
        let masked = bytes[1] & 0x80 != 0;
        assert!(masked, "client frames must be masked");
        let mut cursor = 2;
        let len = match bytes[1] & 0x7F {
            126 => {
                let len = u16::from_be_bytes([bytes[cursor], bytes[cursor + 1]]) as usize;
                cursor += 2;
                len
            }
            127 => {
                let mut raw = [0u8; 8];
                raw.copy_from_slice(&bytes[cursor..cursor + 8]);
                cursor += 8;
                u64::from_be_bytes(raw) as usize
            }
            len => len as usize,
        };
        let mask = [bytes[cursor], bytes[cursor + 1], bytes[cursor + 2], bytes[cursor + 3]];
        cursor += 4;
        let mut payload = bytes[cursor..cursor + len].to_vec();
        mask_in_place(&mut payload, mask);
        (fin, opcode, payload)
    }

    #[test]
    fn client_frames_are_masked_and_round_trip() {
        let mut queue = FrameQueue::new();
        queue
            .push(OP_BINARY, true, b"hello ws")
            .expect("frame");

        let (fin, opcode, payload) = decode_client_frame(&queue.bytes);
        assert!(fin);
        assert_eq!(opcode, OP_BINARY);
        assert_eq!(payload, b"hello ws");
    }

    #[test]
    fn extended_lengths_round_trip() {
        let payload = vec![0xA5u8; 600];
        let mut queue = FrameQueue::new();
        queue.push(OP_BINARY, true, &payload).expect("frame");
        let (_, _, decoded) = decode_client_frame(&queue.bytes);
        assert_eq!(decoded, payload);

        let payload = vec![0x5Au8; 70_000];
        let mut queue = FrameQueue::new();
        queue.push(OP_BINARY, true, &payload).expect("frame");
        let (_, _, decoded) = decode_client_frame(&queue.bytes);
        assert_eq!(decoded, payload);
    }

    #[test]
    fn server_frames_are_parsed_and_fragments_reassemble() {
        let mut buffer = BytesMut::new();
        // First fragment: text, FIN = 0, three bytes of payload.
        buffer.extend_from_slice(&[OP_TEXT, 3]);
        buffer.extend_from_slice(b"hel");
        // Continuation with FIN.
        buffer.extend_from_slice(&[0x80 | OP_CONTINUATION, 2]);
        buffer.extend_from_slice(b"lo");

        let first = try_read_frame(&mut buffer).expect("parse").expect("frame");
        assert!(!first.fin);
        assert_eq!(&first.payload[..], b"hel");
        let second = try_read_frame(&mut buffer).expect("parse").expect("frame");
        assert!(second.fin);
        assert_eq!(&second.payload[..], b"lo");
    }

    #[test]
    fn masked_server_frames_are_refused() {
        let mut buffer = BytesMut::new();
        buffer.extend_from_slice(&[0x80 | OP_TEXT, 0x80 | 2, 0, 0, 0, 0, b'h', b'i']);
        let error = try_read_frame(&mut buffer).expect_err("must refuse a masked server frame");
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn oversized_control_frames_are_refused() {
        let mut buffer = BytesMut::new();
        buffer.extend_from_slice(&[0x80 | OP_PING, 126, 0, 200]);
        buffer.extend_from_slice(&[0u8; 200]);
        let error = try_read_frame(&mut buffer).expect_err("control frames cap at 125 bytes");
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn incomplete_frames_wait_for_more_bytes() {
        let mut buffer = BytesMut::new();
        buffer.extend_from_slice(&[0x80 | OP_BINARY, 4]);
        buffer.extend_from_slice(b"ab");
        assert!(try_read_frame(&mut buffer).expect("parse").is_none());
    }

    /// A server that completes the handshake by hand, then echoes one message.
    #[tokio::test]
    async fn handshake_and_message_round_trip() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept");

            // Read the upgrade request head.
            let mut request = Vec::new();
            loop {
                let mut byte = [0u8; 1];
                socket.read_exact(&mut byte).await.expect("read");
                request.push(byte[0]);
                if request.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
            let text = String::from_utf8(request).expect("utf8");
            let key = text
                .lines()
                .find_map(|line| line.strip_prefix("Sec-WebSocket-Key: "))
                .expect("a client key")
                .trim()
                .to_string();

            let answer = format!(
                "HTTP/1.1 101 Switching Protocols\r\n\
                 Upgrade: websocket\r\n\
                 Connection: Upgrade\r\n\
                 Sec-WebSocket-Accept: {}\r\n\r\n",
                accept_key(&key)
            );
            socket.write_all(answer.as_bytes()).await.expect("answer");

            // Send one text frame, then one masked-frame check and a close.
            socket
                .write_all(&[0x80 | OP_TEXT, 5])
                .await
                .expect("frame head");
            socket.write_all(b"hello").await.expect("frame body");

            // Read the client's masked echo: 2 + 4 + len bytes for short ones.
            let mut header = [0u8; 2];
            socket.read_exact(&mut header).await.expect("header");
            assert_eq!(header[1] & 0x80, 0x80, "client frames must be masked");
            let mut mask = [0u8; 4];
            socket.read_exact(&mut mask).await.expect("mask");
            let len = (header[1] & 0x7F) as usize;
            let mut payload = vec![0u8; len];
            socket.read_exact(&mut payload).await.expect("payload");
            mask_in_place(&mut payload, mask);

            // Answer with a close carrying the normal status.
            socket
                .write_all(&[0x80 | OP_CLOSE, 2, 0x03, 0xE8])
                .await
                .expect("close");

            // Read the client's close echo.
            let mut close = [0u8; 8];
            let _ = socket.read(&mut close).await;

            String::from_utf8(payload).expect("utf8")
        });

        let stream = TcpStream::connect(addr).await.expect("connect");
        let transport = WebSocketTransport::new(
            WebSocketConfig {
                path: "/ws".to_string(),
                ..Default::default()
            },
            "127.0.0.1",
            addr.port(),
            false,
        );

        let mut client = transport.connect(stream).await.expect("handshake");

        let mut message = [0u8; 5];
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            client.read_exact(&mut message),
        )
        .await
        .expect("no timeout")
        .expect("read");
        assert_eq!(&message, b"hello");

        client.write_all(b"echo!").await.expect("write");
        client.flush().await.expect("flush");

        // The close frame from the server ends the stream cleanly.
        let mut trailing = [0u8; 1];
        let read = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            client.read(&mut trailing),
        )
        .await
        .expect("no timeout")
        .expect("read");
        assert_eq!(read, 0, "a close frame ends the stream");

        let echoed = server.await.expect("server");
        assert_eq!(echoed, "echo!");
    }

    #[tokio::test]
    async fn a_non_101_answer_is_refused() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept");
            let mut request = Vec::new();
            loop {
                let mut byte = [0u8; 1];
                socket.read_exact(&mut byte).await.expect("read");
                request.push(byte[0]);
                if request.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
                .await
                .expect("answer");
        });

        let stream = TcpStream::connect(addr).await.expect("connect");
        let transport = WebSocketTransport::new(
            WebSocketConfig::default(),
            "127.0.0.1",
            addr.port(),
            false,
        );

        let error = match transport.connect(stream).await {
            Ok(_) => panic!("a 200 answer must not be accepted"),
            Err(error) => error,
        };
        assert!(
            matches!(error, TransportError::Handshake(_)),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn a_wrong_accept_key_is_refused() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept");
            let mut request = Vec::new();
            loop {
                let mut byte = [0u8; 1];
                socket.read_exact(&mut byte).await.expect("read");
                request.push(byte[0]);
                if request.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
            socket
                .write_all(
                    b"HTTP/1.1 101 Switching Protocols\r\n\
                      Upgrade: websocket\r\n\
                      Connection: Upgrade\r\n\
                      Sec-WebSocket-Accept: not-the-key\r\n\r\n",
                )
                .await
                .expect("answer");
        });

        let stream = TcpStream::connect(addr).await.expect("connect");
        let transport = WebSocketTransport::new(
            WebSocketConfig::default(),
            "127.0.0.1",
            addr.port(),
            false,
        );

        let error = match transport.connect(stream).await {
            Ok(_) => panic!("a wrong accept key must not be accepted"),
            Err(error) => error,
        };
        assert!(
            matches!(error, TransportError::Handshake(_)),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn pings_are_answered_while_reading() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept");
            let mut request = Vec::new();
            loop {
                let mut byte = [0u8; 1];
                socket.read_exact(&mut byte).await.expect("read");
                request.push(byte[0]);
                if request.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
            let text = String::from_utf8(request).expect("utf8");
            let key = text
                .lines()
                .find_map(|line| line.strip_prefix("Sec-WebSocket-Key: "))
                .expect("a client key")
                .trim()
                .to_string();
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
                        accept_key(&key)
                    )
                    .as_bytes(),
                )
                .await
                .expect("answer");

            // Ping first, message second: the pong must come back before the
            // reader is ever polled for a write.
            socket
                .write_all(&[0x80 | OP_PING, 3])
                .await
                .expect("ping head");
            socket.write_all(b"hi!").await.expect("ping body");
            socket.write_all(&[0x80 | OP_TEXT, 2]).await.expect("text head");
            socket.write_all(b"ok").await.expect("text body");

            let mut header = [0u8; 2];
            socket.read_exact(&mut header).await.expect("pong header");
            let mut mask = [0u8; 4];
            socket.read_exact(&mut mask).await.expect("mask");
            let len = (header[1] & 0x7F) as usize;
            let mut payload = vec![0u8; len];
            socket.read_exact(&mut payload).await.expect("pong");
            mask_in_place(&mut payload, mask);
            (header[0] & 0x0F, payload)
        });

        let stream = TcpStream::connect(addr).await.expect("connect");
        let transport = WebSocketTransport::new(
            WebSocketConfig::default(),
            "127.0.0.1",
            addr.port(),
            false,
        );
        let mut client = transport.connect(stream).await.expect("handshake");

        let mut message = [0u8; 2];
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            client.read_exact(&mut message),
        )
        .await
        .expect("no timeout")
        .expect("read");
        assert_eq!(&message, b"ok");

        let (opcode, payload) = server.await.expect("server");
        assert_eq!(opcode, OP_PONG);
        assert_eq!(payload, b"hi!");
    }
}
