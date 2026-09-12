//! The client half of HTTP/1.1: one request out, one response in.
//!
//! The HTTP and mixed inbounds terminate a client connection with
//! [`crate::protocol::h1_server`] and then speak HTTP/1.1 a *second* time to
//! whatever the router picked as the outbound — a proxy chain means this crate
//! sits at both ends of the same protocol. This module is the half that faces
//! upstream:
//!
//! * **One message per connection.** The exchange opens at the caller's
//!   transport (which is already established by the outbound), sends exactly one
//!   request, reads exactly one response, and asks upstream for
//!   `Connection: close`. That turns "the server sent no framing header at all"
//!   into a legal answer — the body ends at EOF — instead of an ambiguity two
//!   parsers could resolve differently.
//! * **Framing by the same authority as the server half.** Request bodies are
//!   re-framed with a plain `Content-Length` because the body is already
//!   buffered; hop-by-hop headers are dropped; response bodies are framed by
//!   `courierust_h1`'s RFC 9112 rules — the same code the server half uses to
//!   decide where a message ends. A proxy whose two ends disagree about that is
//!   a request-smuggling vector, so there is deliberately only one answer.
//! * **Bounds, enforced while reading.** A head stops at
//!   [`DEFAULT_MAX_HEAD_LEN`], a body at the caller's limit, and both are
//!   checked as bytes arrive rather than after they are all in memory.

use std::io;

use bytes::{Bytes, BytesMut};
use courierust::courierust_h1::{self, BodyLen};
use courierust::courierust_http::{
    HeaderMap, HeaderName, HeaderValue, Method, PathAndQuery, StatusCode, Version,
};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};

use super::h1_server::{fill_buffer, parse_header_lines, read_chunked_body, read_head_block};

/// Cap on a response head we accept from upstream.
pub const DEFAULT_MAX_HEAD_LEN: usize = 64 * 1024;

/// Cap on a response body we buffer from upstream.
///
/// The inbounds answer one client request at a time, so the response is
/// buffered whole; the bound is what keeps a hostile upstream from turning an
/// 8 KiB request into unbounded memory.
pub const DEFAULT_MAX_BODY_LEN: usize = 8 * 1024 * 1024;

/// One request to send upstream.
pub struct UpstreamRequest<'a> {
    /// The client's method, kept verbatim: a proxy forwards semantics, not a
    /// normalized subset, so `PATCH`, `PROPFIND` and a custom token all survive.
    pub method: &'a Method,
    /// Origin-form target (`/path?query`).
    pub target: &'a str,
    /// End-to-end headers. Hop-by-hop fields are dropped here.
    pub headers: HeaderMap,
    /// The body, exactly as the client sent it.
    pub body: Bytes,
}

/// One response read back from upstream.
pub struct UpstreamResponse {
    /// Upstream's status code, forwarded unchanged.
    pub status: StatusCode,
    /// The version upstream answered with.
    pub version: Version,
    /// End-to-end headers, hop-by-hop fields removed.
    pub headers: HeaderMap,
    /// The response body, decoded.
    pub body: Bytes,
}

/// Hop-by-hop fields a proxy must consume rather than forward (RFC 9110 §7.6.1).
///
/// `proxy-connection` is not in the RFC; it is the de-facto header a browser
/// sends to a proxy meaning `connection`, and leaving it in would forward a
/// connection-specific header end to end.
const HOP_BY_HOP: &[&str] = &[
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
];

/// Remove every hop-by-hop header from `headers`.
pub fn strip_hop_by_hop(headers: &mut HeaderMap) {
    for name in HOP_BY_HOP {
        headers.remove(name);
    }
}

/// Send `request` and read exactly one response.
///
/// The caller owns `stream` and is expected to drop it afterwards: this is a
/// one-shot exchange, not a keep-alive pool.
pub async fn exchange<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    request: &UpstreamRequest<'_>,
    max_head: usize,
    max_body: usize,
) -> io::Result<UpstreamResponse> {
    if request.body.len() > max_body {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the request body exceeded the configured limit",
        ));
    }

    let mut headers = request.headers.clone();
    strip_hop_by_hop(&mut headers);

    // Ask for a single answer and a closed connection: the body of a response
    // without `Content-Length` is then delimited by EOF, which is the only way
    // to read it without guessing.
    if let Ok(name) = "connection".parse::<HeaderName>() {
        headers.insert(name, HeaderValue::from_static("close"));
    }

    // The body is buffered, so its length is known: re-framing it with
    // `Content-Length` (and never `Transfer-Encoding`) leaves nothing for the
    // two ends to disagree about.
    if let (Ok(name), Ok(value)) = (
        "content-length".parse::<HeaderName>(),
        HeaderValue::from_bytes(request.body.len().to_string().as_bytes()),
    ) {
        headers.insert(name, value);
    }

    let target = PathAndQuery::from_bytes(request.target.as_bytes())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;

    let mut head = Vec::with_capacity(512);
    courierust_h1::write_request_head(
        &mut head,
        request.method,
        &target,
        Version::HTTP_11,
        &headers,
    )
    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;

    stream.write_all(&head).await?;
    if !request.body.is_empty() {
        stream.write_all(&request.body).await?;
    }
    stream.flush().await?;

    read_response(stream, request.method, max_head, max_body).await
}

/// Read one response, framing its body per RFC 9112.
async fn read_response<S: AsyncRead + Unpin>(
    stream: &mut S,
    method: &Method,
    max_head: usize,
    max_body: usize,
) -> io::Result<UpstreamResponse> {
    let mut buffer = BytesMut::with_capacity(8 * 1024);

    let block = read_head_block(stream, &mut buffer, max_head)
        .await?
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "upstream closed before sending a response",
            )
        })?;

    let text = std::str::from_utf8(&block).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidData, "the response head is not UTF-8")
    })?;

    let mut lines = text.split("\r\n");
    let status_line = lines.next().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "missing response status line")
    })?;

    let (status, version) = courierust_h1::parse_status_line(status_line.as_bytes())
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?;

    let mut headers = parse_header_lines(lines)?;

    // Framing is decided from the headers *as sent*: `Transfer-Encoding` is
    // hop-by-hop for forwarding purposes, but it is exactly the field that tells
    // this hop how to read the body, so it must still be present here.
    let mode = body_mode(method, status, &headers)?;

    strip_hop_by_hop(&mut headers);

    let body = match mode {
        BodyMode::Empty => Bytes::new(),
        BodyMode::Length(len) => {
            if len > max_body {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "the response body exceeded the configured limit",
                ));
            }
            fill_buffer(stream, &mut buffer, len, "a response body").await?;
            Bytes::from(buffer.split_to(len))
        }
        BodyMode::Chunked => read_chunked_body(stream, &mut buffer, max_body).await?,
        BodyMode::UntilEof => read_until_eof(stream, &mut buffer, max_body).await?,
    };

    Ok(UpstreamResponse {
        status,
        version,
        headers,
        body,
    })
}

/// How a response body is delimited.
enum BodyMode {
    /// The response cannot carry a body.
    Empty,
    /// `Content-Length: n`.
    Length(usize),
    /// `Transfer-Encoding: chunked`.
    Chunked,
    /// Delimited by connection close (we always ask for close).
    UntilEof,
}

/// Decide how to delimit the body of a response to `method`.
fn body_mode(method: &Method, status: StatusCode, headers: &HeaderMap) -> io::Result<BodyMode> {
    // RFC 9112 §6.3: a response to `HEAD`, and every 1xx/204/304 response, has
    // no body no matter what the framing headers claim. The check comes first
    // on purpose — reading a body a 204 does not have would consume the head of
    // the next message.
    if method == &Method::HEAD
        || status.is_informational()
        || status == StatusCode::NO_CONTENT
        || status == StatusCode::NOT_MODIFIED
    {
        return Ok(BodyMode::Empty);
    }

    // `body_length` is the crate's single authority for TE/CL conflicts: it
    // rejects `chunked` in a non-final position, conflicting duplicate
    // `Content-Length` values, and `Transfer-Encoding` it does not understand.
    match courierust_h1::body_length(headers, Some(method), Some(status))
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))?
    {
        BodyLen::Length(len) => Ok(BodyMode::Length(len)),
        BodyLen::Chunked => Ok(BodyMode::Chunked),
        // No framing header: with `Connection: close` the body runs to EOF.
        BodyLen::None => Ok(BodyMode::UntilEof),
    }
}

/// Read to EOF, bounded by `limit`.
async fn read_until_eof<S: AsyncRead + Unpin>(
    stream: &mut S,
    buffer: &mut BytesMut,
    limit: usize,
) -> io::Result<Bytes> {
    use tokio::io::AsyncReadExt;

    if buffer.len() > limit {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the response body exceeded the configured limit",
        ));
    }

    loop {
        let mut chunk = [0u8; 16 * 1024];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        if buffer.len().saturating_add(read) > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the response body exceeded the configured limit",
            ));
        }
        buffer.extend_from_slice(&chunk[..read]);
    }

    Ok(buffer.split().freeze())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::{TcpListener, TcpStream};

    /// Answer one request with `raw` and then close the connection.
    async fn serve_one(method: Method, raw: &'static [u8]) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept");
            use tokio::io::AsyncReadExt;
            let mut request = Vec::new();
            let mut chunk = [0u8; 4096];
            // Read the head, then whatever body arrived with it.
            loop {
                let read = socket.read(&mut chunk).await.expect("read");
                if read == 0 {
                    break;
                }
                request.extend_from_slice(&chunk[..read]);
                if request.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            socket.write_all(raw).await.expect("write");
            socket.shutdown().await.expect("shutdown");
            String::from_utf8_lossy(&request).to_string()
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        let request = UpstreamRequest {
            method: &method,
            target: "/index.html",
            headers: HeaderMap::new(),
            body: Bytes::new(),
        };
        let response = exchange(
            &mut client,
            &request,
            DEFAULT_MAX_HEAD_LEN,
            DEFAULT_MAX_BODY_LEN,
        )
        .await
        .expect("exchange");

        assert_eq!(response.status, StatusCode::OK);
        let seen = server.await.expect("server");
        assert!(
            seen.starts_with(&format!("{} /index.html HTTP/1.1", method.as_str())),
            "unexpected request head: {seen}"
        );
        // `courierust` serializes field names in their lowercase form, which is
        // what a proxy must forward: HTTP/1.1 field names are case-insensitive.
        assert!(seen.contains("connection: close"), "got: {seen}");
        assert!(seen.contains("content-length: 0"), "got: {seen}");
        String::from_utf8(response.body.to_vec()).expect("utf8")
    }

    #[tokio::test]
    async fn reads_a_fixed_length_body() {
        let body = serve_one(
            Method::GET,
            b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Trace: 1\r\n\r\nhello",
        )
        .await;
        assert_eq!(body, "hello");
    }

    #[tokio::test]
    async fn reads_a_chunked_body() {
        let body = serve_one(
            Method::GET,
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
        )
        .await;
        assert_eq!(body, "hello world");
    }

    #[tokio::test]
    async fn reads_an_unframed_body_to_eof() {
        let body = serve_one(Method::GET, b"HTTP/1.0 200 OK\r\n\r\nno framing headers").await;
        assert_eq!(body, "no framing headers");
    }

    #[tokio::test]
    async fn head_replies_carry_no_body_even_with_content_length() {
        let body = serve_one(
            Method::HEAD,
            b"HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n",
        )
        .await;
        assert_eq!(body, "");
    }

    #[tokio::test]
    async fn rejects_conflicting_content_lengths() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");

        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept");
            let _ = socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc")
                .await;
            let _ = socket.shutdown().await;
        });

        let mut client = TcpStream::connect(addr).await.expect("connect");
        let request = UpstreamRequest {
            method: &Method::GET,
            target: "/",
            headers: HeaderMap::new(),
            body: Bytes::new(),
        };
        let error = match exchange(
            &mut client,
            &request,
            DEFAULT_MAX_HEAD_LEN,
            DEFAULT_MAX_BODY_LEN,
        )
        .await
        {
            Ok(_) => panic!("conflicting lengths must be rejected"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn hop_by_hop_fields_are_stripped() {
        let mut headers = HeaderMap::new();
        headers.append(
            "connection".parse().expect("name"),
            HeaderValue::from_static("keep-alive"),
        );
        headers.append(
            "x-keep".parse().expect("name"),
            HeaderValue::from_static("1"),
        );
        strip_hop_by_hop(&mut headers);

        assert!(headers.get("connection").is_none());
        assert_eq!(
            headers.get("x-keep").and_then(|v| v.to_str().ok()),
            Some("1")
        );
    }
}
