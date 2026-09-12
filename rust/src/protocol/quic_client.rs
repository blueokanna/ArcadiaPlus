//! The one place a QUIC client is configured and dialled.
//!
//! Three outbounds speak QUIC — TUIC, Hysteria2 and VMess-over-QUIC — and all
//! three need the same preamble before their own protocol begins:
//!
//! 1. resolve the server to a socket address,
//! 2. bind a client socket,
//! 3. trust the platform roots, *unless* the user opted out of verification,
//! 4. advertise the protocol's ALPN,
//! 5. choose a congestion controller, stream limits and keep-alive policy,
//! 6. connect with the SNI as the certificate name — which is not always the
//!    dialled host (fronting).
//!
//! Written three times, that preamble drifts: one copy keeps the connection
//! alive and another does not, one caps stream counts and another runs
//! unlimited, and "skip verification" grows a second, subtly different
//! implementation. This module is the single answer, so QUIC policy is decided
//! once and audited once.
//!
//! ## The transport is corduit's, and it is synchronous
//!
//! [`corduit::protocol::quic`] is the workspace's QUIC v1 client: TLS 1.3 over
//! QUIC, ACK/loss recovery, flow control, streams and RFC 9221 datagrams,
//! implemented on courierust's public codecs, with a dedicated driver thread per
//! connection. It is deliberately *synchronous* — `connect` returns once the
//! handshake completed, and streams are `std::io::{Read, Write}` that park on a
//! condition variable while the driver moves packets.
//!
//! This crate is asynchronous, so every blocking call is moved off the runtime:
//!
//! | operation | where it runs | why |
//! |---|---|---|
//! | handshake | blocking pool | bounded by the handshake timeout |
//! | open a stream | blocking pool | returns immediately unless the peer's stream limit is reached |
//! | wait for a stream or datagram | dedicated thread | waits for an unbounded event |
//! | stream byte pumps | dedicated threads | live as long as the stream does |
//!
//! The threads and channel plumbing live in [`crate::protocol::sync_bridge`],
//! the mirror image of [`crate::protocol::io_shim`]. That module is unit-tested
//! against blocking pipes, so the bridge carries no protocol knowledge and no
//! unverified I/O.
//!
//! ## Scope notes, kept honest
//!
//! * **0-RTT / early data** is not offered by the transport; `reduce-rtt` style
//!   options are reported as ignored instead of pretending to be applied.
//! * **`disable-sni` cannot be honoured**: the transport always carries the
//!   certificate name as the SNI extension (there is no switch to omit it), so
//!   the outbounds warn when the option is set rather than silently sending it.
//! * **Congestion control is accepted, but one controller is implemented**: the
//!   transport runs a NewReno-style AIMD and maps every variant onto it, so the
//!   setting is recorded and logged instead of claiming BBR.
//! * **Certificate verification** uses the system trust store and fails closed;
//!   `skip_cert_verify` is the single, visible opt-out.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, ReadBuf};
use tokio::sync::{Mutex, mpsc};

use corduit::protocol::quic::{
    ClientConfig as CorduitClientConfig, ClientConnection, QuicClient, QuicRecvStream,
    QuicSendStream, Salamander,
};

use crate::protocol::error::{ProtocolError, Result};
use crate::protocol::sync_bridge::{
    BlockingReader, BlockingWriter, FinishWrite, run_blocking_dedicated,
};

/// Congestion controllers a QUIC client can be asked for.
///
/// Re-exported from the transport so configuration spellings keep parsing
/// (`cubic`, `new_reno`/`newreno`, `bbr`); see the scope notes above about the
/// controller actually implemented.
pub use corduit::protocol::quic::CongestionControl;

/// The QUIC policy of one outbound.
#[derive(Debug, Clone)]
pub struct QuicClientTuning {
    /// ALPN protocols to advertise, in preference order.
    pub alpn: Vec<String>,
    /// Accept any certificate. Opt-in, and visible here exactly once.
    pub skip_cert_verify: bool,
    /// Congestion controller to request.
    pub congestion: CongestionControl,
    /// Interval between keep-alive PINGs; `None` disables them.
    ///
    /// A NAT between the client and the server forgets an idle UDP mapping long
    /// before QUIC's own idle timeout notices, so a proxy tunnel needs a
    /// heartbeat shorter than the mapping lifetime.
    pub keep_alive: Option<Duration>,
    /// Drop the connection after this much silence.
    pub max_idle: Duration,
    /// Concurrent bidirectional streams this endpoint may open.
    pub max_bidi_streams: u64,
    /// Concurrent unidirectional streams this endpoint may open.
    pub max_uni_streams: u64,
    /// Salamander obfuscation key (Hysteria2's `obfs-password`).
    ///
    /// `Some` wraps every UDP datagram in the transport, which is where
    /// Salamander belongs: it obfuscates the QUIC packets themselves, not any
    /// stream payload.
    pub salamander_key: Option<Vec<u8>>,
}

impl Default for QuicClientTuning {
    fn default() -> Self {
        Self {
            alpn: Vec::new(),
            skip_cert_verify: false,
            congestion: CongestionControl::Cubic,
            keep_alive: Some(Duration::from_secs(10)),
            max_idle: Duration::from_secs(30),
            max_bidi_streams: 100,
            max_uni_streams: 100,
            salamander_key: None,
        }
    }
}

/// Build the transport configuration for one connection.
pub fn client_config(
    tuning: &QuicClientTuning,
    remote: SocketAddr,
    server_name: &str,
) -> CorduitClientConfig {
    let mut config = CorduitClientConfig::new(remote, server_name.to_string());
    // The socket must be bound in the remote's family: an IPv4 socket cannot
    // send to an IPv6 address, and `connect` would fail before any handshake.
    config.local_addr = Some(if remote.is_ipv6() {
        "[::]:0".parse().expect("the unspecified IPv6 address")
    } else {
        "0.0.0.0:0".parse().expect("the unspecified IPv4 address")
    });
    config.alpn = tuning.alpn.clone();
    config.skip_cert_verify = tuning.skip_cert_verify;
    config.idle_timeout = tuning.max_idle;
    config.keep_alive_interval = tuning.keep_alive;
    config.max_concurrent_bidi_streams = tuning.max_bidi_streams;
    config.max_concurrent_uni_streams = tuning.max_uni_streams;
    config.congestion_control = tuning.congestion;
    config.obfs = tuning
        .salamander_key
        .as_ref()
        .map(|key| Arc::new(Salamander::new(key)));
    config
}

/// Resolve `server:port` to the first address the system returns.
pub async fn resolve(server: &str, port: u16) -> Result<SocketAddr> {
    let authority = format!("{server}:{port}");
    tokio::net::lookup_host(&authority)
        .await
        .map_err(|error| ProtocolError::Network(format!("cannot resolve {authority}: {error}")))?
        .next()
        .ok_or_else(|| ProtocolError::Network(format!("no addresses found for {authority}")))
}

/// Dial `remote` and return the established connection.
///
/// `server_name` is the certificate name to verify (the SNI), which a fronted
/// deployment deliberately sets to something other than the dialled host. The
/// handshake runs on the blocking pool: corduit's `connect` returns only once
/// TLS 1.3 over QUIC completed, bounded by the transport's handshake timeout.
pub async fn connect(
    tuning: &QuicClientTuning,
    remote: SocketAddr,
    server_name: &str,
) -> Result<Arc<QuicConnection>> {
    let config = client_config(tuning, remote, server_name);
    tracing::debug!(
        %remote,
        server_name,
        alpn = ?tuning.alpn,
        congestion = ?tuning.congestion,
        keep_alive = ?tuning.keep_alive,
        obfuscated = tuning.salamander_key.is_some(),
        "dialling QUIC"
    );

    let attempt = tokio::task::spawn_blocking(
        move || -> Result<(Arc<QuicClient>, Arc<ClientConnection>)> {
            let client = Arc::new(QuicClient::new(config));
            let connection = client.connect().map_err(ProtocolError::from)?;
            Ok((client, connection))
        },
    )
    .await
    .map_err(|error| ProtocolError::Quic(format!("QUIC connect task failed: {error}")))?;

    let (client, connection) = attempt?;
    Ok(Arc::new(QuicConnection {
        client,
        connection,
        datagrams: Mutex::new(None),
        closed: AtomicBool::new(false),
    }))
}

/// One live QUIC connection, with an async face.
pub struct QuicConnection {
    /// Kept alive so the driver and its configuration outlive every handle.
    client: Arc<QuicClient>,
    connection: Arc<ClientConnection>,
    /// Started on first use; a connection that never relays UDP spends no
    /// thread waiting for datagrams.
    datagrams: Mutex<Option<mpsc::Receiver<std::io::Result<Bytes>>>>,
    closed: AtomicBool,
}

impl QuicConnection {
    /// Whether the connection has closed (by us, by the peer, or by timeout).
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Relaxed) || self.connection.is_closed()
    }

    /// The remote address this connection is talking to.
    pub fn remote_address(&self) -> SocketAddr {
        self.connection.remote_address()
    }

    /// The transport's current RTT estimate.
    pub fn rtt(&self) -> Duration {
        self.connection.rtt()
    }

    /// Close the connection and stop accepting new streams.
    pub fn close(&self) {
        self.closed.store(true, Ordering::Relaxed);
        self.connection.close();
        self.client.close();
    }

    /// Open a client-initiated bidirectional stream.
    pub async fn open_bi(&self) -> Result<(QuicSend, QuicRecv)> {
        let connection = Arc::clone(&self.connection);
        let (send, recv) =
            tokio::task::spawn_blocking(move || connection.open_bi().map_err(ProtocolError::from))
                .await
                .map_err(|error| ProtocolError::Quic(format!("open_bi task failed: {error}")))??;
        Ok((QuicSend::new(send)?, QuicRecv::new(recv)?))
    }

    /// Open a client-initiated bidirectional stream as one async stream.
    pub async fn open_stream(&self) -> Result<QuicStream> {
        let (send, recv) = self.open_bi().await?;
        Ok(QuicStream { send, recv })
    }

    /// Open a client-initiated unidirectional stream.
    pub async fn open_uni(&self) -> Result<QuicSend> {
        let connection = Arc::clone(&self.connection);
        let send =
            tokio::task::spawn_blocking(move || connection.open_uni().map_err(ProtocolError::from))
                .await
                .map_err(|error| ProtocolError::Quic(format!("open_uni task failed: {error}")))??;
        QuicSend::new(send)
    }

    /// Wait for the next server-initiated unidirectional stream.
    ///
    /// Runs on a dedicated thread: the transport parks until the peer opens a
    /// stream, which can be long after the request that triggers it.
    pub async fn accept_uni(&self) -> Result<QuicRecv> {
        let connection = Arc::clone(&self.connection);
        let recv = run_blocking_dedicated("veloguard-quic-accept", move || connection.accept_uni())
            .await
            .map_err(|error| ProtocolError::Quic(format!("accept_uni thread failed: {error}")))?
            .map_err(ProtocolError::from)?;
        QuicRecv::new(recv)
    }

    /// Send one datagram (RFC 9221).
    ///
    /// The transport only queues the packet, so this cannot park for long; it
    /// still runs on the blocking pool because it takes the connection lock.
    pub async fn send_datagram(&self, data: Bytes) -> Result<()> {
        let connection = Arc::clone(&self.connection);
        tokio::task::spawn_blocking(move || {
            connection
                .send_datagram(data.to_vec())
                .map_err(ProtocolError::from)
        })
        .await
        .map_err(|error| ProtocolError::Quic(format!("send_datagram task failed: {error}")))?
    }

    /// Receive the next datagram, waiting as long as the peer takes.
    pub async fn recv_datagram(&self) -> Result<Bytes> {
        let mut guard = self.datagrams.lock().await;
        if guard.is_none() {
            *guard = Some(self.start_datagram_pump()?);
        }
        let receiver = guard.as_mut().expect("just started");
        match receiver.recv().await {
            Some(Ok(datagram)) => Ok(datagram),
            Some(Err(error)) => Err(ProtocolError::Quic(format!(
                "datagram receive failed: {error}"
            ))),
            None => Err(ProtocolError::ConnectionClosed),
        }
    }

    /// Start (once) the thread that waits for datagrams and forwards them.
    fn start_datagram_pump(&self) -> Result<mpsc::Receiver<std::io::Result<Bytes>>> {
        let (tx, rx) = mpsc::channel::<std::io::Result<Bytes>>(32);
        let connection = Arc::clone(&self.connection);
        std::thread::Builder::new()
            .name("veloguard-quic-datagrams".to_string())
            .spawn(move || {
                loop {
                    match connection.read_datagram() {
                        Ok(datagram) => {
                            if tx.blocking_send(Ok(Bytes::from(datagram))).is_err() {
                                break;
                            }
                        }
                        Err(error) => {
                            // The connection is gone (closed or idle-timed-out);
                            // readers learn it from the channel, once.
                            let _ = tx.blocking_send(Err(std::io::Error::other(error.to_string())));
                            break;
                        }
                    }
                }
            })
            .map_err(|error| {
                ProtocolError::Quic(format!("cannot start datagram thread: {error}"))
            })?;
        Ok(rx)
    }
}

/// The send half of a QUIC stream.
pub struct QuicSend {
    writer: BlockingWriter,
    id: u64,
}

impl QuicSend {
    fn new(stream: QuicSendStream) -> Result<Self> {
        let id = stream.id();
        let writer = BlockingWriter::spawn(QuicSendWriter(stream))
            .map_err(|error| ProtocolError::Quic(format!("cannot start stream writer: {error}")))?;
        Ok(Self { writer, id })
    }

    /// The QUIC stream id.
    pub fn id(&self) -> u64 {
        self.id
    }

    /// Queue the FIN, after every byte written so far.
    pub async fn finish(&mut self) -> Result<()> {
        self.writer.finish().await.map_err(ProtocolError::Io)
    }
}

impl AsyncWrite for QuicSend {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.get_mut().writer).poll_write(cx, buf)
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().writer).poll_flush(cx)
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().writer).poll_shutdown(cx)
    }
}

/// The receive half of a QUIC stream.
pub struct QuicRecv {
    reader: BlockingReader,
    id: u64,
}

impl QuicRecv {
    fn new(stream: QuicRecvStream) -> Result<Self> {
        let id = stream.id();
        let reader = BlockingReader::spawn(stream)
            .map_err(|error| ProtocolError::Quic(format!("cannot start stream reader: {error}")))?;
        Ok(Self { reader, id })
    }

    /// The QUIC stream id.
    pub fn id(&self) -> u64 {
        self.id
    }

    /// Read until the peer finishes, refusing payloads above `limit`.
    ///
    /// TUIC's QUIC-mode UDP relay and Hysteria2's HTTP/3 auth both read a
    /// server-initiated stream to completion, and both need a bound: an
    /// unbounded read lets a peer decide how much memory this process allocates.
    pub async fn read_all(&mut self, limit: usize) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = self
                .reader
                .read(&mut chunk)
                .await
                .map_err(ProtocolError::Io)?;
            if n == 0 {
                return Ok(out);
            }
            if out.len() + n > limit {
                return Err(ProtocolError::Protocol(format!(
                    "stream carries more than {limit} bytes"
                )));
            }
            out.extend_from_slice(&chunk[..n]);
        }
    }
}

impl AsyncRead for QuicRecv {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().reader).poll_read(cx, buf)
    }
}

/// A bidirectional QUIC stream as a single async stream.
pub struct QuicStream {
    send: QuicSend,
    recv: QuicRecv,
}

impl QuicStream {
    /// Queue the FIN for the send half.
    pub async fn finish(&mut self) -> Result<()> {
        self.send.finish().await
    }
}

impl AsyncRead for QuicStream {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().recv).poll_read(cx, buf)
    }
}

impl AsyncWrite for QuicStream {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.get_mut().send).poll_write(cx, buf)
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().send).poll_flush(cx)
    }

    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().send).poll_shutdown(cx)
    }
}

/// Teach the bridge how to complete a QUIC send stream.
struct QuicSendWriter(QuicSendStream);

impl std::io::Write for QuicSendWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}

impl FinishWrite for QuicSendWriter {
    fn finish_stream(&mut self) -> std::io::Result<()> {
        self.0.finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote() -> SocketAddr {
        "127.0.0.1:443".parse().expect("an address")
    }

    #[test]
    fn tuning_maps_into_the_transport_configuration() {
        let tuning = QuicClientTuning {
            alpn: vec!["h3".to_string()],
            skip_cert_verify: true,
            congestion: CongestionControl::Bbr,
            keep_alive: Some(Duration::from_secs(7)),
            max_idle: Duration::from_secs(21),
            max_bidi_streams: 33,
            max_uni_streams: 44,
            salamander_key: Some(b"password".to_vec()),
        };

        let config = client_config(&tuning, remote(), "example.com");
        assert_eq!(config.server_addr, remote());
        assert_eq!(config.server_name, "example.com");
        assert_eq!(config.alpn, ["h3"]);
        assert!(config.skip_cert_verify);
        assert_eq!(config.congestion_control, CongestionControl::Bbr);
        assert_eq!(config.keep_alive_interval, Some(Duration::from_secs(7)));
        assert_eq!(config.idle_timeout, Duration::from_secs(21));
        assert_eq!(config.max_concurrent_bidi_streams, 33);
        assert_eq!(config.max_concurrent_uni_streams, 44);
        assert!(config.obfs.is_some(), "Salamander must be installed");
    }

    #[test]
    fn plain_quic_leaves_obfuscation_off() {
        let config = client_config(&QuicClientTuning::default(), remote(), "example.com");
        assert!(config.obfs.is_none());
        assert!(
            !config.skip_cert_verify,
            "verification is opt-out, not opt-in"
        );
    }

    #[test]
    fn the_local_socket_follows_the_remote_family() {
        let ipv4 = client_config(&QuicClientTuning::default(), remote(), "example.com");
        assert!(ipv4.local_addr.expect("a bind address").is_ipv4());

        let ipv6_remote: SocketAddr = "[::1]:443".parse().expect("an address");
        let ipv6 = client_config(&QuicClientTuning::default(), ipv6_remote, "example.com");
        assert!(
            ipv6.local_addr.expect("a bind address").is_ipv6(),
            "an IPv6 remote needs an IPv6 socket"
        );
    }

    #[test]
    fn congestion_control_accepts_the_spellings_in_the_wild() {
        assert_eq!(
            "bbr".parse::<CongestionControl>().expect("bbr"),
            CongestionControl::Bbr
        );
        assert_eq!(
            "BBR"
                .parse::<CongestionControl>()
                .expect("case-insensitive"),
            CongestionControl::Bbr
        );
        assert_eq!(
            "new_reno".parse::<CongestionControl>().expect("new_reno"),
            CongestionControl::NewReno
        );
        assert_eq!(
            "newreno".parse::<CongestionControl>().expect("newreno"),
            CongestionControl::NewReno
        );
        assert_eq!(
            "cubic".parse::<CongestionControl>().expect("cubic"),
            CongestionControl::Cubic
        );
    }

    #[test]
    fn congestion_control_refuses_unknown_values() {
        // A typo must not silently become a default the user did not choose.
        assert!("vegas".parse::<CongestionControl>().is_err());
        assert!("".parse::<CongestionControl>().is_err());
    }

    #[test]
    fn the_default_tuning_keeps_a_connection_alive() {
        let tuning = QuicClientTuning::default();
        assert_eq!(tuning.keep_alive, Some(Duration::from_secs(10)));
        assert!(tuning.max_idle > tuning.keep_alive.expect("keep-alive"));
        assert!(!tuning.skip_cert_verify);
        assert!(tuning.salamander_key.is_none());
    }

    #[test]
    fn transport_errors_keep_their_classification() {
        use corduit::protocol::quic::QuicError;

        assert!(matches!(
            ProtocolError::from(QuicError::Certificate("bad chain".into())),
            ProtocolError::Tls(_)
        ));
        assert!(matches!(
            ProtocolError::from(QuicError::Timeout),
            ProtocolError::Timeout
        ));
        assert!(matches!(
            ProtocolError::from(QuicError::Closed),
            ProtocolError::ConnectionClosed
        ));
        assert!(matches!(
            ProtocolError::from(QuicError::Io("bind".into())),
            ProtocolError::Network(_)
        ));
        assert!(matches!(
            ProtocolError::from(QuicError::InvalidConfig("nope".into())),
            ProtocolError::InvalidConfig(_)
        ));
    }
}
