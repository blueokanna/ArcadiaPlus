//! An asynchronous HTTP/1.1 server core over `courierust_h1`.
//!
//! Three servers in this crate need to speak HTTP/1.1 to a client we do not
//! control: the HTTP and mixed inbounds (which must tunnel with `CONNECT`), the
//! DNS-over-HTTPS server, and the local REST API. A general-purpose server
//! framework is the wrong shape for two of them — `CONNECT` needs the raw socket
//! *after* the response, and the REST API must not drag a whole framework's
//! dependency tree into a proxy — so the framing comes from `courierust_h1`
//! (request line, header block, body length rules, response encoding, hop-by-hop
//! classification) and this module adds exactly what a server needs around it:
//!
//! * **Buffered reads that never lose bytes.** A request head and its body may
//!   arrive in any number of TCP segments, and a `CONNECT` tunnel must start
//!   from byte zero of what follows the head — so the buffer is owned by this
//!   type and [`H1Connection::into_parts`] hands back whatever it still holds.
//! * **Bounds.** A head is capped at [`DEFAULT_MAX_HEAD_LEN`] and a body at the
//!   caller's limit, both enforced while reading rather than after, so a slow
//!   flood cannot grow memory.
//! * **Correct framing of the answer.** `Content-Length` for fixed bodies,
//!   `Transfer-Encoding: chunked` when the caller streams, `Connection: close`
//!   when the client asked for it or the server decided to end the session.
//! * **A tunnel that starts at byte zero.** [`accept_connect`][H1Connection::accept_connect]
//!   answers `CONNECT` without a `Content-Length` (RFC 9112 §6.3 forbids one
//!   on a 2xx answer) and hands back a [`PrefixedStream`] that replays the
//!   read-ahead bytes before it reads the socket, so the first tunnelled byte
//!   is never lost and never reordered.

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use bytes::{Bytes, BytesMut};
use courierust::courierust_h1;
use courierust::courierust_http::{
    HeaderMap, HeaderName, HeaderValue, Method, StatusCode, Version,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};

/// Cap on a request head (request line plus headers).
pub const DEFAULT_MAX_HEAD_LEN: usize = 64 * 1024;

/// Cap on a request body for the servers in this crate.
pub const DEFAULT_MAX_BODY_LEN: usize = 8 * 1024 * 1024;

/// A parsed request.
#[derive(Debug, Clone)]
pub struct Request {
    pub method: Method,
    /// The request target exactly as sent: an absolute URI on the proxy path,
    /// an origin-form path for the DoH and API servers.
    pub target: String,
    pub version: Version,
    pub headers: HeaderMap,
    pub body: Bytes,
}

impl Request {
    /// A header value as text, if present and valid UTF-8.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).and_then(|value| value.to_str().ok())
    }

    /// Whether the client asked for a persistent connection.
    pub fn keep_alive(&self) -> bool {
        courierust_h1::keep_alive_requested(self.version, &self.headers)
    }

    /// The `CONNECT` authority (`host:port`), when this is a CONNECT.
    pub fn connect_authority(&self) -> Option<&str> {
        if !self.method.as_str().eq_ignore_ascii_case("CONNECT") {
            return None;
        }
        Some(self.target.as_str())
    }
}

/// The answer to send.
#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Bytes,
    /// Send the body with `Transfer-Encoding: chunked`.
    ///
    /// Needed when the length is not known up front; the REST API and the DoH
    /// server always know theirs, so this defaults to `false`.
    pub chunked: bool,
    /// Close the connection after this response.
    pub close: bool,
}

impl Response {
    /// A response with a body and the given status.
    pub fn new(status: u16, body: impl Into<Bytes>) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: body.into(),
            chunked: false,
            close: false,
        }
    }

    /// A response with no body.
    pub fn empty(status: u16) -> Self {
        Self::new(status, Bytes::new())
    }

    /// HTML/text helper used by the inbounds when they answer directly.
    pub fn text(status: u16, body: impl Into<String>) -> Self {
        let mut response = Self::new(status, Bytes::from(body.into()));
        response.headers.push((
            "content-type".to_string(),
            "text/plain; charset=utf-8".to_string(),
        ));
        response
    }

    /// Set a header, replacing any previous value with the same name.
    pub fn set_header(&mut self, name: &str, value: &str) -> &mut Self {
        self.headers
            .retain(|(existing, _)| !existing.eq_ignore_ascii_case(name));
        self.headers.push((name.to_string(), value.to_string()));
        self
    }
}

/// A buffered HTTP/1.1 connection.
pub struct H1Connection<S> {
    stream: S,
    buffer: BytesMut,
    head_limit: usize,
    body_limit: usize,
    /// The version of the request being answered; a response mirrors it.
    version: Version,
}

impl<S> H1Connection<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    /// Wrap a connection with the default bounds.
    pub fn new(stream: S) -> Self {
        Self::with_limits(stream, DEFAULT_MAX_HEAD_LEN, DEFAULT_MAX_BODY_LEN)
    }

    /// Wrap a connection with explicit limits.
    pub fn with_limits(stream: S, head_limit: usize, body_limit: usize) -> Self {
        Self {
            stream,
            buffer: BytesMut::with_capacity(8 * 1024),
            head_limit,
            body_limit,
            version: Version::HTTP_11,
        }
    }

    /// Bytes read ahead of the request head and not yet consumed.
    ///
    /// A `CONNECT` tunnel must forward these before it forwards the socket.
    pub fn buffered(&self) -> &[u8] {
        &self.buffer
    }

    /// Split the connection back into its socket and its read-ahead buffer.
    pub fn into_parts(self) -> (S, BytesMut) {
        (self.stream, self.buffer)
    }

    /// Read one request, or `None` when the peer closed the connection cleanly.
    pub async fn read_request(&mut self) -> io::Result<Option<Request>> {
        let head =
            match read_head_block(&mut self.stream, &mut self.buffer, self.head_limit).await? {
                Some(head) => head,
                None => return Ok(None),
            };

        let (method, target, version, headers) = parse_head(&head)?;
        self.version = version;
        let body = self.read_body(&headers).await?;

        Ok(Some(Request {
            method,
            target,
            version,
            headers,
            body,
        }))
    }

    /// Write a response, framing the body according to the headers.
    pub async fn write_response(&mut self, response: &Response) -> io::Result<()> {
        let status = StatusCode::from_u16(response.status);

        let mut headers = HeaderMap::new();
        for (name, value) in &response.headers {
            if let (Ok(name), Ok(value)) = (
                name.parse::<HeaderName>(),
                HeaderValue::from_bytes(value.as_bytes()),
            ) {
                headers.append(name, value);
            }
        }

        let has_body = !response.body.is_empty();
        if response.chunked {
            if let Ok(name) = "transfer-encoding".parse::<HeaderName>() {
                let _ = headers.insert(name, HeaderValue::from_static("chunked"));
            }
        } else if has_body {
            if let Ok(name) = "content-length".parse::<HeaderName>() {
                let _ = headers.insert(name, HeaderValue::from(response.body.len().to_string()));
            }
        } else if let Ok(name) = "content-length".parse::<HeaderName>() {
            let _ = headers.insert(name, HeaderValue::from_static("0"));
        }

        // `close` is a promise, not a hint: a caller that sets it must be able
        // to rely on the peer learning the session is over from the head
        // itself, rather than from a socket that goes silent.
        if response.close
            && let Ok(name) = "connection".parse::<HeaderName>()
        {
            let _ = headers.insert(name, HeaderValue::from_static("close"));
        }

        let mut out = Vec::with_capacity(256);
        courierust_h1::write_response_head(&mut out, status, self.version, &headers)
            .map_err(|error| io::Error::other(error.to_string()))?;

        if response.chunked {
            if has_body {
                courierust_h1::encode_chunk(&response.body, &mut out);
            }
            out.extend_from_slice(b"0\r\n\r\n");
        } else {
            out.extend_from_slice(&response.body);
        }

        self.stream.write_all(&out).await?;
        self.stream.flush().await?;

        if response.close {
            // Half-close so the peer sees the end of the session instead of a
            // socket that lingers until a timeout reaps it.
            let _ = self.stream.shutdown().await;
        }

        Ok(())
    }

    /// Answer a `CONNECT` and hand back the socket plus any bytes already read.
    ///
    /// The success answer is written by hand instead of through
    /// [`Self::write_response`]: RFC 9112 §6.3 forbids a `Content-Length` (or
    /// `Transfer-Encoding`) on a 2xx answer to `CONNECT`, and the generic
    /// writer adds `Content-Length: 0` to bodyless responses. A client that
    /// validates the tunnel answer — or a middlebox that does — would reject
    /// the connection over that byte, so the head is serialized without it.
    pub async fn accept_connect(self, extra_headers: &[(&str, &str)]) -> io::Result<(S, BytesMut)> {
        let mut headers = HeaderMap::new();
        for (name, value) in extra_headers {
            if let (Ok(name), Ok(value)) = (
                name.parse::<HeaderName>(),
                HeaderValue::from_bytes(value.as_bytes()),
            ) {
                headers.append(name, value);
            }
        }

        let mut out = Vec::with_capacity(128);
        courierust_h1::write_response_head(&mut out, StatusCode::OK, self.version, &headers)
            .map_err(|error| io::Error::other(error.to_string()))?;

        let mut this = self;
        this.stream.write_all(&out).await?;
        this.stream.flush().await?;
        Ok(this.into_parts())
    }

    /// Read exactly the body the framing rules promise.
    async fn read_body(&mut self, headers: &HeaderMap) -> io::Result<Bytes> {
        let length = body_length(headers)?;
        match length {
            BodyLength::None => Ok(Bytes::new()),
            BodyLength::Fixed(0) => Ok(Bytes::new()),
            BodyLength::Fixed(len) => {
                if len > self.body_limit {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "the request body exceeded the configured limit",
                    ));
                }
                fill_buffer(&mut self.stream, &mut self.buffer, len, "a request body").await?;
                Ok(Bytes::from(self.buffer.split_to(len)))
            }
            BodyLength::Chunked => {
                read_chunked_body(&mut self.stream, &mut self.buffer, self.body_limit).await
            }
        }
    }
}

/// Read one head block (through its terminating empty line) into `buffer`.
///
/// `Ok(None)` means the peer closed cleanly before the first byte; a truncated
/// head is an error, because a server that treated a half-read head as "no
/// request" would let a slow-loris renegotiate message boundaries.
///
/// Shared by both halves of an exchange: [`H1Connection`] reads requests with
/// it and [`crate::protocol::h1_client`] reads responses with it, so the two
/// sides can never disagree about where a head ends.
pub(crate) async fn read_head_block<S: AsyncRead + Unpin>(
    stream: &mut S,
    buffer: &mut BytesMut,
    head_limit: usize,
) -> io::Result<Option<BytesMut>> {
    loop {
        if let Some(position) = find_head_end(buffer) {
            return Ok(Some(buffer.split_to(position + 4)));
        }

        if buffer.len() > head_limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the head exceeded the configured limit",
            ));
        }

        let mut chunk = [0u8; 8 * 1024];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            if buffer.is_empty() {
                return Ok(None);
            }
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the connection closed inside a head",
            ));
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
}

/// Buffer at least `needed` bytes, reading from `stream` as required.
pub(crate) async fn fill_buffer<S: AsyncRead + Unpin>(
    stream: &mut S,
    buffer: &mut BytesMut,
    needed: usize,
    what: &'static str,
) -> io::Result<()> {
    while buffer.len() < needed {
        let mut chunk = [0u8; 16 * 1024];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                format!("the connection closed inside {what}"),
            ));
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
    Ok(())
}

/// Decode one `Transfer-Encoding: chunked` body, bounded by `limit`.
///
/// Shared by both halves of an exchange so the chunk framing a server accepts
/// and the chunk framing a client accepts are decoded by the same code — a
/// disagreement between the two ends of a proxy is a smuggling vector.
pub(crate) async fn read_chunked_body<S: AsyncRead + Unpin>(
    stream: &mut S,
    buffer: &mut BytesMut,
    limit: usize,
) -> io::Result<Bytes> {
    let mut body = BytesMut::new();

    loop {
        // Chunk size line.
        let line_end = loop {
            if let Some(position) = find_line_end(buffer) {
                break position;
            }
            let mut chunk = [0u8; 4 * 1024];
            let read = stream.read(&mut chunk).await?;
            if read == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the connection closed inside a chunk header",
                ));
            }
            buffer.extend_from_slice(&chunk[..read]);
        };

        let line = buffer.split_to(line_end + 2);
        let size_text = std::str::from_utf8(&line[..line_end])
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "chunk size is not ASCII"))?;
        let size_text = size_text.split(';').next().unwrap_or("").trim();
        let size = usize::from_str_radix(size_text, 16).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidData, "chunk size is not hexadecimal")
        })?;

        if size == 0 {
            // Trailer section, terminated by an empty line.
            loop {
                let line_end = loop {
                    if let Some(position) = find_line_end(buffer) {
                        break position;
                    }
                    let mut chunk = [0u8; 4 * 1024];
                    let read = stream.read(&mut chunk).await?;
                    if read == 0 {
                        return Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            "the connection closed inside a chunk trailer",
                        ));
                    }
                    buffer.extend_from_slice(&chunk[..read]);
                };
                let line = buffer.split_to(line_end + 2);
                if line.len() <= 2 {
                    return Ok(body.freeze());
                }
            }
        }

        if body.len().saturating_add(size) > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the body exceeded the configured limit",
            ));
        }

        fill_buffer(stream, buffer, size + 2, "a chunk").await?;

        let data = buffer.split_to(size);
        body.extend_from_slice(&data);
        let _terminator = buffer.split_to(2);
    }
}

/// A stream with a replay prefix: the bytes the server read ahead of a request
/// head are handed back before any new byte is read from the socket.
///
/// A `CONNECT` tunnel is a byte pipe whose first payload bytes may already sit
/// in the server's read buffer — a client is free to send its TLS `ClientHello`
/// in the same segment as the `CONNECT` request line. Feeding those bytes into
/// a fresh stream would reorder or drop them; this type keeps the tunnel
/// single-sourced, so the first byte a relay reads is the first byte the client
/// sent after the head.
pub struct PrefixedStream<S> {
    inner: S,
    prefix: BytesMut,
    offset: usize,
}

impl<S> PrefixedStream<S> {
    /// Wrap `inner`, replaying `prefix` before the first socket read.
    pub fn new(inner: S, prefix: BytesMut) -> Self {
        Self {
            inner,
            prefix,
            offset: 0,
        }
    }

    /// The bytes that have not been replayed yet.
    pub fn pending(&self) -> &[u8] {
        &self.prefix[self.offset..]
    }

    /// Split back into the underlying stream and the unreplayed bytes.
    pub fn into_parts(mut self) -> (S, BytesMut) {
        let pending = self.prefix.split_off(self.offset);
        (self.inner, pending)
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for PrefixedStream<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if this.offset < this.prefix.len() {
            let remaining = &this.prefix[this.offset..];
            let count = remaining.len().min(buf.remaining());
            buf.put_slice(&remaining[..count]);
            this.offset += count;
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut this.inner).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for PrefixedStream<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

/// How much body the headers announce.
enum BodyLength {
    None,
    Fixed(usize),
    Chunked,
}

/// Decide the body framing from the headers, per RFC 9112.
fn body_length(headers: &HeaderMap) -> io::Result<BodyLength> {
    if let Some(encoding) = headers
        .get("transfer-encoding")
        .and_then(|value| value.to_str().ok())
        && encoding.to_ascii_lowercase().contains("chunked")
    {
        return Ok(BodyLength::Chunked);
    }

    match headers
        .get("content-length")
        .and_then(|value| value.to_str().ok())
    {
        Some(value) => value
            .trim()
            .parse::<usize>()
            .map(BodyLength::Fixed)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid content-length")),
        None => Ok(BodyLength::None),
    }
}

/// Split the head into its parts.
fn parse_head(head: &[u8]) -> io::Result<(Method, String, Version, HeaderMap)> {
    let text = std::str::from_utf8(head)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "the request head is not UTF-8"))?;

    let mut lines = text.split("\r\n");
    let request_line = lines
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing request line"))?;

    // `CONNECT` carries an authority-form target (`host:port`), which the
    // origin/absolute-form parser rejects on purpose — RFC 9110 §9.3.6 gives
    // CONNECT its own form, so the target is taken verbatim here.
    let (method, target, version) = if request_line
        .split(' ')
        .next()
        .is_some_and(|token| token.eq_ignore_ascii_case("CONNECT"))
    {
        let mut parts = request_line.split(' ');
        let _method = parts.next();
        let authority = parts.next().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "CONNECT without an authority")
        })?;
        let version = parts
            .next()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing HTTP version"))?;
        let version = courierust_h1::parse_version(version.as_bytes())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;
        let method = Method::from_bytes(b"CONNECT")
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;
        (method, authority.to_string(), version)
    } else {
        let parsed = courierust_h1::parse_request_line(request_line.as_bytes())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;
        (
            parsed.method,
            parsed.target.as_str().to_string(),
            parsed.version,
        )
    };

    let headers = parse_header_lines(lines)?;

    Ok((method, target, version, headers))
}

/// Parse a header block's lines into a [`HeaderMap`].
///
/// Shared with [`crate::protocol::h1_client`]: a proxy parses the headers it
/// receives with this function and writes the ones it forwards with
/// `courierust_h1`'s serializer, so "what arrives" and "what leaves" are
/// validated by the same rules — the alternative is two parsers that disagree
/// about duplicates, whitespace or an embedded `\r`, and that disagreement is a
/// request-smuggling surface.
pub(crate) fn parse_header_lines<'a>(
    lines: impl Iterator<Item = &'a str>,
) -> io::Result<HeaderMap> {
    let mut headers = HeaderMap::new();
    for line in lines {
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "malformed header line",
            ));
        };
        if let (Ok(name), Ok(value)) = (
            name.trim().parse::<HeaderName>(),
            HeaderValue::from_bytes(value.trim().as_bytes()),
        ) {
            headers.append(name, value);
        }
    }
    Ok(headers)
}

fn find_head_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

fn find_line_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(2).position(|window| window == b"\r\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::{TcpListener, TcpStream};

    /// Drive one round trip through the connection over a real socket pair.
    async fn serve_once(server: TcpStream) -> (String, Vec<u8>) {
        let mut connection = H1Connection::new(server);
        let request = connection
            .read_request()
            .await
            .expect("read")
            .expect("a request");
        let body = request.body.clone();
        connection
            .write_response(&Response::new(200, Bytes::from_static(b"pong")))
            .await
            .expect("write");
        (request.target, body.to_vec())
    }

    #[tokio::test]
    async fn reads_a_request_and_writes_a_response() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("accept");
            serve_once(socket).await
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        client
            .write_all(
                b"POST /submit HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\n\r\nbody",
            )
            .await
            .expect("write");

        let mut response = Vec::new();
        client.read_to_end(&mut response).await.expect("read");
        let text = String::from_utf8_lossy(&response);
        assert!(text.starts_with("HTTP/1.1 200"));
        assert!(text.ends_with("pong"));

        let (target, body) = server.await.expect("server");
        assert_eq!(target, "/submit");
        assert_eq!(body, b"body");
    }

    #[tokio::test]
    async fn chunked_bodies_are_decoded() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("accept");
            serve_once(socket).await
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        client
            .write_all(
                b"POST /chunked HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n\
                  4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n",
            )
            .await
            .expect("write");

        let mut response = Vec::new();
        client.read_to_end(&mut response).await.expect("read");
        let (_, body) = server.await.expect("server");
        assert_eq!(body, b"Wikipedia");
    }

    #[tokio::test]
    async fn connect_hands_back_the_read_ahead_bytes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("accept");
            let mut connection = H1Connection::new(socket);
            let request = connection
                .read_request()
                .await
                .expect("read")
                .expect("a request");
            assert_eq!(request.connect_authority(), Some("example.com:443"));
            let (_socket, buffered) = connection
                .accept_connect(&[("proxy-agent", "VeloGuard")])
                .await
                .expect("accept");
            buffered.to_vec()
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        client
            .write_all(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\nearly")
            .await
            .expect("write");

        let mut response = Vec::new();
        client.read_to_end(&mut response).await.expect("read");
        let text = String::from_utf8_lossy(&response);
        assert!(text.contains("200 Connection Established") || text.contains("HTTP/1.1 200"));

        assert_eq!(server.await.expect("server"), b"early");
    }

    #[test]
    fn body_length_follows_the_rfc() {
        let mut chunked = HeaderMap::new();
        chunked.append(
            "transfer-encoding".parse().expect("name"),
            HeaderValue::from_static("chunked"),
        );
        assert!(matches!(
            body_length(&chunked).expect("length"),
            BodyLength::Chunked
        ));

        let mut fixed = HeaderMap::new();
        fixed.append(
            "content-length".parse().expect("name"),
            HeaderValue::from_static("12"),
        );
        assert!(matches!(
            body_length(&fixed).expect("length"),
            BodyLength::Fixed(12)
        ));

        assert!(matches!(
            body_length(&HeaderMap::new()).expect("length"),
            BodyLength::None
        ));
    }

    #[tokio::test]
    async fn prefixed_stream_replays_before_reading_the_socket() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("accept");
            let mut prefixed = PrefixedStream::new(socket, BytesMut::from(&b"early"[..]));
            let mut first = [0u8; 5];
            prefixed.read_exact(&mut first).await.expect("prefix");
            let mut second = [0u8; 4];
            prefixed.read_exact(&mut second).await.expect("socket");
            (first, second)
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        client.write_all(b"late").await.expect("write");
        client.flush().await.expect("flush");

        let (first, second) = server.await.expect("server");
        assert_eq!(&first, b"early");
        assert_eq!(&second, b"late");
    }

    #[tokio::test]
    async fn connect_answer_carries_no_body_framing_headers() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("accept");
            let mut connection = H1Connection::new(socket);
            let request = connection
                .read_request()
                .await
                .expect("read")
                .expect("a request");
            assert_eq!(request.connect_authority(), Some("example.com:443"));

            let (mut socket, buffered) = connection
                .accept_connect(&[("proxy-agent", "VeloGuard")])
                .await
                .expect("accept");

            // Hold the tunnel open until the client hangs up, then report the
            // read-ahead buffer the caller must forward itself.
            let mut until_close = [0u8; 1];
            let _ = socket.read(&mut until_close).await;
            buffered
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        client
            .write_all(b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
            .await
            .expect("write");

        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            let mut byte = [0u8; 1];
            client.read_exact(&mut byte).await.expect("read");
            head.push(byte[0]);
        }

        let text = String::from_utf8(head).expect("utf8");
        assert!(text.starts_with("HTTP/1.1 200"), "got: {text}");
        let lowered = text.to_ascii_lowercase();
        assert!(
            !lowered.contains("content-length"),
            "a 2xx CONNECT answer must not frame a body: {text}"
        );
        assert!(
            !lowered.contains("transfer-encoding"),
            "a 2xx CONNECT answer must not frame a body: {text}"
        );
        assert!(lowered.contains("proxy-agent: veloguard"));

        drop(client);
        let buffered = server.await.expect("server");
        assert!(buffered.is_empty());
    }
}
