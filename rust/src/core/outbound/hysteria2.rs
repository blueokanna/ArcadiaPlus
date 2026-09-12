//! The Hysteria2 outbound, speaking the real protocol over corduit's QUIC.
//!
//! ## What the protocol actually is
//!
//! Hysteria2 is HTTP/3-shaped, and the three parts that look like "just send a
//! header byte" are exactly where a plausible-looking implementation goes wrong:
//!
//! 1. **Authentication** is an HTTP/3 request — `POST /auth` with `:status 233`
//!    as the answer. The client first opens the HTTP/3 setup streams (control,
//!    QPACK encoder, QPACK decoder), then sends a `HEADERS` frame carrying QPACK
//!    literal fields (`hysteria-auth`, `hysteria-cc-rx`, `hysteria-padding`).
//!    The request is authenticated only when a `HEADERS` frame comes back whose
//!    `:status` is `233`.
//! 2. **A TCP relay** starts with a QUIC varint `0x401`, a varint address
//!    length, the `host:port` address (bracketed IPv6, as Go's `net.JoinHostPort`
//!    writes it), a varint padding length *and then the padding bytes*, and is
//!    accepted only if the server answers a `0` status byte (followed by an
//!    optional message and padding the client must drain).
//! 3. **UDP relay** travels in QUIC datagrams shaped
//!    `[session u32][packet u16][frag_id u8][frag_count u8][addr_len varint][addr][payload]`,
//!    and payloads above one datagram are fragmented, so the receive side has to
//!    reassemble by `(session, packet)`.
//!
//! Everything in this module follows those rules, on top of
//! [`crate::protocol::quic_client`] (corduit's QUIC v1 client). The wire helpers
//! and the reassembler are ports of the in-repo reference implementation
//! (`corduit::engine::outbound::hysteria2`), and the QPACK codec comes straight
//! from `corduit::protocol::qpack` — no second encoder lives here.
//!
//! ## Salamander obfuscation
//!
//! `obfs: salamander` wraps *every QUIC datagram* in the transport, keyed by
//! `obfs-password`. It is not a stream transform, so it is installed through
//! [`QuicClientTuning::salamander_key`] rather than applied to payloads here.
//!
//! ## Scope notes, kept honest
//!
//! * `up`/`down` Mbps only feed the `hysteria-cc-rx` hint (the protocol's only
//!   rate field on this path); `up` is accepted and ignored, as in the in-repo
//!   reference.
//! * `disable-mtu-discovery` is accepted and ignored: the transport uses a fixed
//!   1200-byte datagram size and has no DPLPMTUD. A warning is logged.
//! * `ports` (port hopping) is applied when a connection is *established* — a
//!   random port from the list is used for each new QUIC connection. Changing
//!   ports without reconnecting would need connection migration, which the
//!   transport deliberately does not implement; a warning says so.

use crate::core::config::OutboundConfig;
use crate::core::connection_tracker::{TrackedConnection, global_tracker};
use crate::core::error::{Error, Result};
use crate::core::outbound::{AsyncReadWrite, OutboundProxy, TargetAddr};
use crate::core::tls::yaml_value_to_string;
use crate::protocol::quic_client::{self, QuicClientTuning, QuicConnection, QuicRecv, QuicSend};
use bytes::Buf;
use corduit::protocol::qpack::{decode_block, encode_literal_fields};
use parking_lot::RwLock;
use std::collections::{BTreeMap, HashMap};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex;
use tokio::time::Instant;
use tracing::{debug, info, warn};

/// The Hysteria2 TCP request id (`0x401`), written as a QUIC varint.
const HY2_TCP_REQUEST_ID: u64 = 0x401;

/// HTTP/3 frame types this client cares about.
const H3_FRAME_HEADERS: u64 = 0x01;
/// HTTP/3 control stream type (RFC 9114 §6.2.1).
const H3_CONTROL_STREAM: u64 = 0x00;
/// `SETTINGS` frame type inside the control stream.
const H3_SETTINGS_FRAME: u64 = 0x04;
/// QPACK encoder / decoder stream types (RFC 9204 §4.2).
const H3_QPACK_ENCODER_STREAM: u64 = 0x02;
const H3_QPACK_DECODER_STREAM: u64 = 0x03;

/// Payload budget for one UDP datagram, leaving room for the message header.
const MAX_DATAGRAM_PAYLOAD: usize = 1100;
/// Fragments older than this are dropped instead of held forever.
const FRAGMENT_TTL: Duration = Duration::from_secs(10);
/// Cap for the optional message that follows a TCP status byte.
const MAX_RESPONSE_STRING: usize = 4096;
/// How long an authentication exchange may take.
const AUTH_DEADLINE: Duration = Duration::from_secs(15);
/// Padding carried by the auth request.
const AUTH_PADDING_ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";

/// Largest auth-response frame accepted (the answer is a few dozen bytes).
const MAX_AUTH_FRAME: usize = 16 * 1024;

#[derive(Debug, Clone, PartialEq, Default)]
pub enum ObfsType {
    #[default]
    None,
    Salamander(String),
}

#[derive(Debug, Clone)]
pub struct Hysteria2Config {
    pub server: String,
    pub port: u16,
    pub password: String,
    pub obfs: ObfsType,
    pub sni: Option<String>,
    pub skip_cert_verify: bool,
    pub alpn: Vec<String>,
    pub up_mbps: Option<u32>,
    pub down_mbps: Option<u32>,
    pub fingerprint: Option<String>,
    pub ports: Option<String>,
    pub hop_interval: Option<u32>,
    pub disable_mtu_discovery: bool,
}

impl Default for Hysteria2Config {
    fn default() -> Self {
        Self {
            server: String::new(),
            port: 443,
            password: String::new(),
            obfs: ObfsType::None,
            sni: None,
            skip_cert_verify: false,
            alpn: vec!["h3".to_string()],
            up_mbps: None,
            down_mbps: None,
            fingerprint: None,
            ports: None,
            hop_interval: None,
            disable_mtu_discovery: false,
        }
    }
}

/// A live, authenticated Hysteria2 session over one QUIC connection.
pub struct Hysteria2Connection {
    connection: Arc<QuicConnection>,
    password: String,
    authenticated: RwLock<bool>,
    /// The receive rate hint sent as `hysteria-cc-rx`.
    down_mbps: Option<u32>,
    /// Reassembly state for fragmented UDP relay messages.
    assembler: Mutex<FragAssembler>,
    /// HTTP/3 setup streams, held open for the life of the connection.
    ///
    /// Closing them early is legal (RFC 9114 allows a client to FIN its control
    /// stream after SETTINGS), but a server that waits for the QPACK streams
    /// before answering `/auth` would stall, and the in-repo reference keeps
    /// them open — so this does too.
    setup_streams: Mutex<Vec<QuicSend>>,
}

impl Hysteria2Connection {
    pub fn new(connection: Arc<QuicConnection>, password: String, down_mbps: Option<u32>) -> Self {
        Self {
            connection,
            password,
            authenticated: RwLock::new(false),
            down_mbps,
            assembler: Mutex::new(FragAssembler::new()),
            setup_streams: Mutex::new(Vec::new()),
        }
    }

    /// Authenticate over HTTP/3 (`POST /auth`), waiting for `:status 233`.
    pub async fn authenticate(&self) -> Result<()> {
        if *self.authenticated.read() {
            return Ok(());
        }

        // HTTP/3 setup streams: a real client opens the control stream, the
        // QPACK encoder stream and the QPACK decoder stream before issuing
        // requests, and some servers wait for them.
        let mut opened: Vec<QuicSend> = Vec::new();
        for stream_type in [
            H3_CONTROL_STREAM,
            H3_QPACK_ENCODER_STREAM,
            H3_QPACK_DECODER_STREAM,
        ] {
            match self.connection.open_uni().await {
                Ok(mut stream) => {
                    let mut setup = Vec::with_capacity(6);
                    write_varint(&mut setup, stream_type);
                    if stream_type == H3_CONTROL_STREAM {
                        write_varint(&mut setup, H3_SETTINGS_FRAME);
                        write_varint(&mut setup, 0);
                    }
                    // Best effort: a server that rejects the stream still
                    // answers the auth request, which is what decides.
                    if stream.write_all(&setup).await.is_ok() {
                        opened.push(stream);
                    }
                }
                Err(error) => {
                    debug!(%error, "HTTP/3 setup stream could not be opened");
                }
            }
        }
        *self.setup_streams.lock().await = opened;

        let (mut send, mut recv) = self.connection.open_bi().await?;

        let padding = random_padding();
        let rx_bps = self
            .down_mbps
            .map(|mbps| u64::from(mbps) * 1024 * 1024 / 8)
            .unwrap_or(0);

        let fields: Vec<(&[u8], Vec<u8>)> = vec![
            (b":method", b"POST".to_vec()),
            (b":scheme", b"https".to_vec()),
            (b":authority", b"hysteria".to_vec()),
            (b":path", b"/auth".to_vec()),
            (b"hysteria-auth", self.password.as_bytes().to_vec()),
            (b"hysteria-cc-rx", rx_bps.to_string().into_bytes()),
            (b"hysteria-padding", padding),
        ];
        let field_refs: Vec<(&[u8], &[u8])> = fields
            .iter()
            .map(|(name, value)| (*name, value.as_slice()))
            .collect();
        let qpack = encode_literal_fields(&field_refs);

        let mut msg = Vec::with_capacity(qpack.len() + 8);
        write_varint(&mut msg, H3_FRAME_HEADERS);
        write_varint(&mut msg, qpack.len() as u64);
        msg.extend_from_slice(&qpack);

        send.write_all(&msg)
            .await
            .map_err(|error| Error::network(format!("Failed to send auth request: {error}")))?;
        send.finish().await?;

        await_auth_response(&mut recv).await?;

        *self.authenticated.write() = true;
        debug!("Hysteria2 authentication completed");
        Ok(())
    }

    /// Open a TCP relay: send the `0x401` request and read the status byte.
    pub async fn open_tcp_stream(&self, target: &TargetAddr) -> Result<(QuicSend, QuicRecv)> {
        self.authenticate().await?;

        let (mut send, mut recv) = self.connection.open_bi().await?;

        let addr = encode_address(target);
        let mut msg = Vec::with_capacity(addr.len() + 8);
        write_varint(&mut msg, HY2_TCP_REQUEST_ID);
        write_varint(&mut msg, addr.len() as u64);
        msg.extend_from_slice(addr.as_bytes());
        // Padding length, then padding. A client that omits the padding length
        // leaves the server waiting for it, which looks exactly like a hang.
        write_varint(&mut msg, 0);

        send.write_all(&msg)
            .await
            .map_err(|error| Error::network(format!("Failed to send TCP request: {error}")))?;

        let status = read_tcp_response(&mut recv).await?;
        if status != 0 {
            return Err(Error::protocol(format!(
                "Hysteria2 TCP connect failed (status {status})"
            )));
        }

        debug!("Hysteria2 TCP stream opened for target: {target}");
        Ok((send, recv))
    }

    /// Send one UDP payload as (possibly fragmented) QUIC datagrams.
    pub async fn send_udp_packet(
        &self,
        session_id: u32,
        target: &TargetAddr,
        data: &[u8],
    ) -> Result<()> {
        self.authenticate().await?;

        let addr = encode_address(target);
        let header_len = 4 + 2 + 1 + 1 + varint_len(addr.len() as u64) + addr.len();
        let max_chunk = MAX_DATAGRAM_PAYLOAD.saturating_sub(header_len);
        if max_chunk == 0 {
            return Err(Error::protocol(
                "target address too long for a Hysteria2 datagram",
            ));
        }

        let packet_id: u16 = crate::crypto::random_u16();
        if data.len() <= max_chunk {
            let msg = write_udp_message(session_id, packet_id, 0, 1, &addr, data);
            self.connection
                .send_datagram(bytes::Bytes::from(msg))
                .await
                .map_err(|error| Error::network(format!("Failed to send UDP datagram: {error}")))?;
            debug!(
                "Hysteria2 UDP packet sent to {target} ({} bytes)",
                data.len()
            );
            return Ok(());
        }

        let frag_count = data.len().div_ceil(max_chunk);
        if frag_count > 255 {
            return Err(Error::protocol(format!(
                "UDP payload too large to fragment ({frag_count} fragments)"
            )));
        }
        for (frag_id, chunk) in data.chunks(max_chunk).enumerate() {
            let msg = write_udp_message(
                session_id,
                packet_id,
                frag_id as u8,
                frag_count as u8,
                &addr,
                chunk,
            );
            self.connection
                .send_datagram(bytes::Bytes::from(msg))
                .await
                .map_err(|error| Error::network(format!("Failed to send UDP fragment: {error}")))?;
        }
        debug!(
            "Hysteria2 UDP packet sent to {target} ({} bytes, {} fragments)",
            data.len(),
            frag_count
        );
        Ok(())
    }

    /// Receive the next complete UDP payload (reassembling fragments).
    pub async fn recv_udp_packet(&self) -> Result<(u32, TargetAddr, Vec<u8>)> {
        loop {
            let datagram = self.connection.recv_datagram().await.map_err(|error| {
                Error::network(format!("Failed to receive UDP datagram: {error}"))
            })?;

            let (session_id, packet_id, frag_id, frag_count, target, payload) =
                parse_udp_message(&datagram)?;

            if frag_count <= 1 {
                return Ok((session_id, target, payload));
            }

            let mut assembler = self.assembler.lock().await;
            if let Some((target, full)) =
                assembler.add(session_id, packet_id, frag_id, frag_count, target, payload)
            {
                return Ok((session_id, target, full));
            }
        }
    }

    pub fn is_closed(&self) -> bool {
        self.connection.is_closed()
    }

    pub fn close(&self) {
        self.connection.close();
    }

    #[allow(dead_code)]
    pub fn remote_address(&self) -> SocketAddr {
        self.connection.remote_address()
    }
}

/// Read the auth response until a `HEADERS` frame carries `:status 233`.
///
/// Split out of [`Hysteria2Connection::authenticate`] so the framing can be
/// tested without a server: this is the part that decides access, and "it sent
/// something" is not the same answer as "it sent 233".
async fn await_auth_response<R>(reader: &mut R) -> Result<()>
where
    R: AsyncRead + Unpin,
{
    let deadline = Instant::now() + AUTH_DEADLINE;
    loop {
        let (frame_type, payload) = read_h3_frame(reader, MAX_AUTH_FRAME, deadline).await?;
        if frame_type != H3_FRAME_HEADERS {
            // DATA / SETTINGS / other frames on the auth stream are ignored.
            continue;
        }

        let fields = decode_block(&payload)
            .map_err(|error| Error::protocol(format!("QPACK decode failed: {error}")))?;
        let mut status_ok = false;
        for (name, value) in &fields {
            if name.eq_ignore_ascii_case(b":status") {
                status_ok = value == b"233";
            }
        }
        if status_ok {
            return Ok(());
        }

        let detail: Vec<String> = fields
            .iter()
            .map(|(name, value)| {
                format!(
                    "{}: {}",
                    String::from_utf8_lossy(name),
                    String::from_utf8_lossy(value)
                )
            })
            .collect();
        return Err(Error::protocol(format!(
            "Hysteria2 authentication rejected (status != 233): {}",
            detail.join(", ")
        )));
    }
}

/// One in-flight fragmented UDP packet: `(fragment count, fragments, target,
/// received at)`.
type PendingFragment = (u8, BTreeMap<u8, Vec<u8>>, TargetAddr, Instant);

/// Incomplete packets held at once, across every session.
const MAX_PENDING_FRAGMENTS: usize = 64;

/// Reassembly buffer for fragmented UDP relay messages.
struct FragAssembler {
    /// `(session_id, packet_id)` -> pending fragment state.
    pending: HashMap<(u32, u16), PendingFragment>,
}

impl FragAssembler {
    fn new() -> Self {
        Self {
            pending: HashMap::new(),
        }
    }

    /// Drop expired entries, then the oldest ones until the map is back under
    /// the cap: a peer cannot make this grow without bound.
    fn prune(&mut self, now: Instant) {
        let cutoff = now - FRAGMENT_TTL;
        self.pending.retain(|_, (_, _, _, at)| *at > cutoff);

        while self.pending.len() >= MAX_PENDING_FRAGMENTS {
            let oldest = self
                .pending
                .iter()
                .min_by_key(|(_, (_, _, _, at))| *at)
                .map(|(key, _)| *key);
            match oldest {
                Some(key) => {
                    self.pending.remove(&key);
                }
                None => break,
            }
        }
    }

    /// Insert a fragment; returns `(target, reassembled payload)` when the whole
    /// packet has arrived.
    fn add(
        &mut self,
        session_id: u32,
        packet_id: u16,
        frag_id: u8,
        frag_count: u8,
        target: TargetAddr,
        payload: Vec<u8>,
    ) -> Option<(TargetAddr, Vec<u8>)> {
        let now = Instant::now();
        if self.pending.len() >= MAX_PENDING_FRAGMENTS {
            self.prune(now);
        }

        let key = (session_id, packet_id);
        let entry = self
            .pending
            .entry(key)
            .or_insert_with(|| (frag_count, BTreeMap::new(), target.clone(), now));
        entry.1.insert(frag_id, payload);
        entry.3 = now;

        if entry.1.len() >= usize::from(entry.0) {
            let (_, fragments, target, _) = self.pending.remove(&key)?;
            let mut full = Vec::new();
            for (_, chunk) in fragments {
                full.extend_from_slice(&chunk);
            }
            Some((target, full))
        } else {
            None
        }
    }
}

/// QUIC varint (RFC 9000 §16) — the length is implied by the top two bits.
fn write_varint(out: &mut Vec<u8>, value: u64) {
    match value {
        0..=63 => out.push(value as u8),
        64..=16_383 => {
            out.push(0x40 | ((value >> 8) as u8));
            out.push((value & 0xff) as u8);
        }
        16_384..=1_073_741_823 => {
            out.push(0x80 | ((value >> 24) as u8));
            out.push(((value >> 16) & 0xff) as u8);
            out.push(((value >> 8) & 0xff) as u8);
            out.push((value & 0xff) as u8);
        }
        _ => {
            out.push(0xc0 | ((value >> 56) as u8));
            for shift in (0..7).rev() {
                out.push(((value >> (shift * 8)) & 0xff) as u8);
            }
        }
    }
}

fn varint_len(value: u64) -> usize {
    match value {
        0..=63 => 1,
        64..=16_383 => 2,
        16_384..=1_073_741_823 => 4,
        _ => 8,
    }
}

/// Read one varint, bounded by `deadline`.
async fn read_varint<R>(reader: &mut R, deadline: Instant) -> Result<u64>
where
    R: AsyncRead + Unpin,
{
    let mut first = [0u8; 1];
    read_bounded(reader, &mut first, deadline).await?;
    let len = 1usize << (first[0] >> 6);
    let mut value = u64::from(first[0] & 0x3f);
    for _ in 1..len {
        let mut next = [0u8; 1];
        read_bounded(reader, &mut next, deadline).await?;
        value = (value << 8) | u64::from(next[0]);
    }
    Ok(value)
}

/// Read one HTTP/3 frame: `[frame_type varint][length varint][payload]`.
async fn read_h3_frame<R>(
    reader: &mut R,
    max_len: usize,
    deadline: Instant,
) -> Result<(u64, Vec<u8>)>
where
    R: AsyncRead + Unpin,
{
    let frame_type = read_varint(reader, deadline).await?;
    let len = read_varint(reader, deadline).await? as usize;
    if len > max_len {
        return Err(Error::protocol(format!(
            "HTTP/3 frame too large ({len} bytes)"
        )));
    }
    let mut payload = vec![0u8; len];
    read_bounded(reader, &mut payload, deadline).await?;
    Ok((frame_type, payload))
}

/// Read the Hysteria2 TCP response header; returns the status byte.
///
/// The optional message and padding are drained best-effort with a hard cap, so
/// a peer claiming a huge length field cannot make this block forever. Only the
/// status byte decides whether the relay is up.
async fn read_tcp_response<R>(reader: &mut R) -> Result<u8>
where
    R: AsyncRead + Unpin,
{
    let deadline = Instant::now() + AUTH_DEADLINE;
    let mut status = [0u8; 1];
    read_bounded(reader, &mut status, deadline)
        .await
        .map_err(|error| Error::network(format!("Failed to read TCP response: {error}")))?;
    let status = status[0];

    if let Ok(message_len) = read_varint(reader, deadline).await {
        let _ = skip_bounded(reader, message_len as usize, deadline).await;
        if let Ok(padding_len) = read_varint(reader, deadline).await {
            let _ = skip_bounded(reader, padding_len as usize, deadline).await;
        }
    }
    Ok(status)
}

/// Read and discard up to `total` bytes, never more than [`MAX_RESPONSE_STRING`].
async fn skip_bounded<R>(reader: &mut R, total: usize, deadline: Instant) -> Result<()>
where
    R: AsyncRead + Unpin,
{
    let mut remaining = total.min(MAX_RESPONSE_STRING);
    let mut buf = [0u8; 512];
    while remaining > 0 {
        let take = remaining.min(buf.len());
        read_bounded(reader, &mut buf[..take], deadline).await?;
        remaining -= take;
    }
    Ok(())
}

/// Read exactly `buf.len()` bytes, failing once `deadline` passes.
async fn read_bounded<R>(reader: &mut R, buf: &mut [u8], deadline: Instant) -> Result<()>
where
    R: AsyncRead + Unpin,
{
    match tokio::time::timeout_at(deadline, reader.read_exact(buf)).await {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(error)) => Err(Error::network(format!("read failed: {error}"))),
        Err(_) => Err(Error::network("read timed out".to_string())),
    }
}

/// `host:port` (bracketed IPv6), matching Go's `net.JoinHostPort`.
fn encode_address(target: &TargetAddr) -> String {
    match target {
        TargetAddr::Domain(domain, port) => format!("{domain}:{port}"),
        TargetAddr::Ip(addr) => addr.to_string(),
    }
}

fn parse_address(text: &str) -> Result<TargetAddr> {
    if let Some(rest) = text.strip_prefix('[') {
        let (ip, port_part) = rest
            .split_once(']')
            .ok_or_else(|| Error::protocol("Malformed bracketed address"))?;
        let port = port_part
            .strip_prefix(':')
            .ok_or_else(|| Error::protocol("Malformed bracketed address"))?;
        let ip: std::net::Ipv6Addr = ip
            .parse()
            .map_err(|_| Error::protocol("Invalid IPv6 address"))?;
        let port: u16 = port.parse().map_err(|_| Error::protocol("Invalid port"))?;
        Ok(TargetAddr::Ip(SocketAddr::V6(std::net::SocketAddrV6::new(
            ip, port, 0, 0,
        ))))
    } else {
        let (host, port) = text
            .rsplit_once(':')
            .ok_or_else(|| Error::protocol("Address has no port"))?;
        let port: u16 = port.parse().map_err(|_| Error::protocol("Invalid port"))?;
        if let Ok(ip) = host.parse::<std::net::Ipv4Addr>() {
            Ok(TargetAddr::Ip(SocketAddr::V4(std::net::SocketAddrV4::new(
                ip, port,
            ))))
        } else {
            Ok(TargetAddr::Domain(host.to_string(), port))
        }
    }
}

/// Encode one UDP relay message.
fn write_udp_message(
    session_id: u32,
    packet_id: u16,
    frag_id: u8,
    frag_count: u8,
    addr: &str,
    payload: &[u8],
) -> Vec<u8> {
    let mut full = Vec::with_capacity(addr.len() + payload.len() + 16);
    full.extend_from_slice(&session_id.to_be_bytes());
    full.extend_from_slice(&packet_id.to_be_bytes());
    full.push(frag_id);
    full.push(frag_count);
    write_varint(&mut full, addr.len() as u64);
    full.extend_from_slice(addr.as_bytes());
    full.extend_from_slice(payload);
    full
}

fn parse_udp_message(data: &[u8]) -> Result<(u32, u16, u8, u8, TargetAddr, Vec<u8>)> {
    if data.len() < 8 {
        return Err(Error::protocol("UDP message too short"));
    }
    let mut buf = data;
    let session_id = buf.get_u32();
    let packet_id = buf.get_u16();
    let frag_id = buf.get_u8();
    let frag_count = buf.get_u8();

    let (addr_len, rest) = read_varint_slice(buf)?;
    if addr_len as usize > rest.len() {
        return Err(Error::protocol("UDP address truncated"));
    }
    let addr = std::str::from_utf8(&rest[..addr_len as usize])
        .map_err(|_| Error::protocol("UDP address not UTF-8"))?;
    let target = parse_address(addr)?;
    let payload = rest[addr_len as usize..].to_vec();
    Ok((session_id, packet_id, frag_id, frag_count, target, payload))
}

/// Parse a QUIC varint from a byte slice, returning `(value, rest)`.
fn read_varint_slice(data: &[u8]) -> Result<(u64, &[u8])> {
    let first = *data
        .first()
        .ok_or_else(|| Error::protocol("Empty varint"))?;
    let len = 1usize << (first >> 6);
    if data.len() < len {
        return Err(Error::protocol("Truncated varint"));
    }
    let mut value = u64::from(first & 0x3f);
    for byte in &data[1..len] {
        value = (value << 8) | u64::from(*byte);
    }
    Ok((value, &data[len..]))
}

/// Random alphanumeric padding for the auth request.
fn random_padding() -> Vec<u8> {
    let len = 8 + (usize::from(crate::crypto::random_u8()) % 16);
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        out.push(
            AUTH_PADDING_ALPHABET
                [usize::from(crate::crypto::random_u8()) % AUTH_PADDING_ALPHABET.len()],
        );
    }
    out
}

/// Parse a Hysteria2 `ports` specification into the ports a connection may use.
///
/// Accepted forms: `443`, `20000-30000`, `443,8443`, and any comma-separated
/// mix. Ranges are expanded, so `1-65535` would allocate the whole port space —
/// the specification is user-supplied, and a typo must fail loudly rather than
/// become "the whole range silently".
fn parse_port_spec(spec: &str) -> Result<Vec<u16>> {
    let mut ports: Vec<u16> = Vec::new();
    for item in spec.split(',') {
        let item = item.trim();
        if item.is_empty() {
            continue;
        }
        match item.split_once('-') {
            Some((start, end)) => {
                let start: u16 = start
                    .trim()
                    .parse()
                    .map_err(|_| Error::config(format!("Invalid port range '{item}'")))?;
                let end: u16 = end
                    .trim()
                    .parse()
                    .map_err(|_| Error::config(format!("Invalid port range '{item}'")))?;
                if start > end {
                    return Err(Error::config(format!(
                        "Port range '{item}' starts above its end"
                    )));
                }
                if usize::from(end - start) > 1024 {
                    return Err(Error::config(format!(
                        "Port range '{item}' is wider than 1024 ports"
                    )));
                }
                ports.extend(start..=end);
            }
            None => {
                let port: u16 = item
                    .parse()
                    .map_err(|_| Error::config(format!("Invalid port '{item}'")))?;
                ports.push(port);
            }
        }
    }
    if ports.is_empty() {
        return Err(Error::config(format!("Port spec '{spec}' lists no ports")));
    }
    Ok(ports)
}

pub struct Hysteria2Outbound {
    config: OutboundConfig,
    hy2_config: Hysteria2Config,
    /// Ports to hop between, expanded from `ports`.
    hop_ports: Option<Vec<u16>>,
    connection: Mutex<Option<Arc<Hysteria2Connection>>>,
    /// The QUIC policy this outbound dials with, decided once at construction.
    quic_tuning: QuicClientTuning,
}

impl Hysteria2Outbound {
    pub fn new(config: OutboundConfig) -> Result<Self> {
        let server = config
            .server
            .as_ref()
            .ok_or_else(|| Error::config("Missing server address for Hysteria2"))?
            .clone();

        let port = config
            .port
            .ok_or_else(|| Error::config("Missing port for Hysteria2"))?;

        let password = config
            .options
            .get("password")
            .or_else(|| config.options.get("auth"))
            .map(yaml_value_to_string)
            .ok_or_else(|| Error::config("Missing password for Hysteria2"))?;

        let obfs = match config.options.get("obfs").map(yaml_value_to_string) {
            Some(kind) if kind.eq_ignore_ascii_case("salamander") => {
                let obfs_password = config
                    .options
                    .get("obfs-password")
                    .map(yaml_value_to_string)
                    .unwrap_or_default();
                if obfs_password.is_empty() {
                    return Err(Error::config(
                        "Hysteria2 obfs 'salamander' needs 'obfs-password'",
                    ));
                }
                ObfsType::Salamander(obfs_password)
            }
            Some(other) if !other.is_empty() => {
                return Err(Error::config(format!(
                    "Hysteria2 obfs '{other}' is not supported (salamander or nothing)"
                )));
            }
            _ => ObfsType::None,
        };

        let sni = config
            .options
            .get("sni")
            .map(yaml_value_to_string)
            .filter(|value| !value.is_empty());

        let skip_cert_verify = config
            .options
            .get("skip-cert-verify")
            .and_then(|value| value.as_bool())
            .unwrap_or(false);

        let alpn = config
            .options
            .get("alpn")
            .and_then(|value| value.as_sequence())
            .map(|seq| {
                seq.iter()
                    .filter_map(|item| item.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_else(|| vec!["h3".to_string()]);

        let up_mbps = config
            .options
            .get("up")
            .and_then(|value| value.as_u64())
            .map(|value| value as u32);

        let down_mbps = config
            .options
            .get("down")
            .and_then(|value| value.as_u64())
            .map(|value| value as u32);

        let fingerprint = config
            .options
            .get("fingerprint")
            .map(yaml_value_to_string)
            .filter(|value| !value.is_empty());

        let ports = config
            .options
            .get("ports")
            .map(yaml_value_to_string)
            .filter(|value| !value.is_empty());

        let hop_interval = config
            .options
            .get("hop-interval")
            .and_then(|value| value.as_u64())
            .map(|value| value as u32);

        let disable_mtu_discovery = config
            .options
            .get("disable-mtu-discovery")
            .and_then(|value| value.as_bool())
            .unwrap_or(false);
        if disable_mtu_discovery {
            warn!(
                outbound = %config.tag,
                "disable-mtu-discovery is ignored: the in-repo QUIC transport uses a fixed \
                 1200-byte datagram size and does not implement DPLPMTUD"
            );
        }

        let hop_ports = match &ports {
            Some(spec) => Some(parse_port_spec(spec).map_err(|error| {
                Error::config(format!("Hysteria2 outbound '{}': {error}", config.tag))
            })?),
            None => None,
        };
        if hop_ports.is_some() {
            warn!(
                outbound = %config.tag,
                "port hopping picks a random port per connection; switching ports inside a live \
                 connection needs QUIC connection migration, which the transport does not implement"
            );
        }

        // Salamander is a datagram-level obfuscation, so the key travels with
        // the QUIC policy instead of being applied to payloads here.
        let salamander_key = match &obfs {
            ObfsType::Salamander(key) => Some(key.as_bytes().to_vec()),
            ObfsType::None => None,
        };

        let quic_tuning = QuicClientTuning {
            alpn: alpn.clone(),
            skip_cert_verify,
            keep_alive: Some(Duration::from_secs(10)),
            salamander_key,
            ..Default::default()
        };

        let hy2_config = Hysteria2Config {
            server,
            port,
            password,
            obfs,
            sni,
            skip_cert_verify,
            alpn,
            up_mbps,
            down_mbps,
            fingerprint,
            ports,
            hop_interval,
            disable_mtu_discovery,
        };

        debug!(
            "Creating Hysteria2 outbound: server={}:{}, obfs={:?}, up={:?}Mbps, down={:?}Mbps",
            hy2_config.server,
            hy2_config.port,
            hy2_config.obfs,
            hy2_config.up_mbps,
            hy2_config.down_mbps
        );

        Ok(Self {
            config,
            hy2_config,
            hop_ports,
            connection: Mutex::new(None),
            quic_tuning,
        })
    }

    pub fn hy2_config(&self) -> &Hysteria2Config {
        &self.hy2_config
    }

    /// The port the next connection uses: the configured one, or a random pick
    /// from `ports` when port hopping is on.
    fn dial_port(&self) -> u16 {
        match &self.hop_ports {
            Some(ports) => {
                let index = usize::from(crate::crypto::random_u16()) % ports.len();
                ports[index]
            }
            None => self.hy2_config.port,
        }
    }

    async fn get_or_create_connection(&self) -> Result<Arc<Hysteria2Connection>> {
        let mut conn_guard = self.connection.lock().await;

        if let Some(connection) = conn_guard.as_ref()
            && !connection.is_closed()
        {
            return Ok(Arc::clone(connection));
        }

        let port = self.dial_port();
        let remote = quic_client::resolve(&self.hy2_config.server, port).await?;

        // A fronted deployment answers a certificate for `sni`, not for the
        // address it was dialled at.
        let server_name = self
            .hy2_config
            .sni
            .clone()
            .unwrap_or_else(|| self.hy2_config.server.clone());

        let connection = quic_client::connect(&self.quic_tuning, remote, &server_name).await?;
        debug!("Hysteria2 QUIC connection established to {remote}");

        let session = Arc::new(Hysteria2Connection::new(
            connection,
            self.hy2_config.password.clone(),
            self.hy2_config.down_mbps,
        ));

        session.authenticate().await?;
        *conn_guard = Some(Arc::clone(&session));
        Ok(session)
    }

    pub async fn relay_udp(&self, target: &TargetAddr, data: &[u8]) -> Result<Vec<u8>> {
        let connection = self.get_or_create_connection().await?;
        let session_id: u32 = crate::crypto::random_u32();

        connection.send_udp_packet(session_id, target, data).await?;

        let timeout = Duration::from_secs(30);
        let result = tokio::time::timeout(timeout, connection.recv_udp_packet())
            .await
            .map_err(|_| Error::network("UDP receive timeout"))?;

        let (_recv_session_id, _recv_target, payload) = result?;
        Ok(payload)
    }
}

#[async_trait::async_trait]
impl OutboundProxy for Hysteria2Outbound {
    async fn connect(&self) -> Result<()> {
        let _connection = self.get_or_create_connection().await?;
        info!(
            "Hysteria2 outbound '{}' connected to {}:{}",
            self.config.tag, self.hy2_config.server, self.hy2_config.port
        );
        Ok(())
    }

    async fn disconnect(&self) -> Result<()> {
        let connection = self.connection.lock().await.take();
        if let Some(connection) = connection {
            connection.close();
        }
        Ok(())
    }

    fn tag(&self) -> &str {
        &self.config.tag
    }

    fn server_addr(&self) -> Option<(String, u16)> {
        Some((self.hy2_config.server.clone(), self.hy2_config.port))
    }

    fn supports_udp(&self) -> bool {
        true
    }

    async fn relay_udp_packet(&self, target: &TargetAddr, data: &[u8]) -> Result<Vec<u8>> {
        self.relay_udp(target, data).await
    }

    async fn test_http_latency(&self, test_url: &str, timeout: Duration) -> Result<Duration> {
        use std::time::Instant as StdInstant;

        let url = url::Url::parse(test_url)
            .map_err(|error| Error::config(format!("Invalid test URL: {error}")))?;

        let host = url
            .host_str()
            .ok_or_else(|| Error::config("Test URL has no host"))?
            .to_string();
        let url_port = url
            .port()
            .unwrap_or(if url.scheme() == "https" { 443 } else { 80 });
        let path = if url.path().is_empty() {
            "/"
        } else {
            url.path()
        };

        let start = StdInstant::now();

        let connection = tokio::time::timeout(timeout, self.get_or_create_connection())
            .await
            .map_err(|_| Error::network("Connection timeout"))??;

        let target = TargetAddr::Domain(host.clone(), url_port);
        let (mut send, mut recv) = connection.open_tcp_stream(&target).await?;

        let request = format!(
            "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nUser-Agent: VeloGuard/1.0\r\n\r\n"
        );
        send.write_all(request.as_bytes())
            .await
            .map_err(|error| Error::network(format!("Failed to send HTTP request: {error}")))?;

        let response = tokio::time::timeout(timeout, async {
            let mut head = vec![0u8; 1024];
            let n = recv
                .read(&mut head)
                .await
                .map_err(|error| Error::network(format!("Failed to read response: {error}")))?;
            if n == 0 {
                return Err(Error::network("Empty response"));
            }
            if String::from_utf8_lossy(&head[..n]).starts_with("HTTP/") {
                Ok(())
            } else {
                Err(Error::network("Invalid HTTP response"))
            }
        })
        .await;

        match response {
            Ok(Ok(())) => {
                let elapsed = start.elapsed();
                info!("Hysteria2 latency test success: {}ms", elapsed.as_millis());
                Ok(elapsed)
            }
            Ok(Err(error)) => {
                warn!("Hysteria2 latency test failed: {error}");
                Err(error)
            }
            Err(_) => {
                warn!("Hysteria2 latency test timeout");
                Err(Error::network("Response timeout"))
            }
        }
    }

    async fn relay_tcp(&self, inbound: Box<dyn AsyncReadWrite>, target: TargetAddr) -> Result<()> {
        self.relay_tcp_with_connection(inbound, target, None).await
    }

    async fn relay_tcp_with_connection(
        &self,
        inbound: Box<dyn AsyncReadWrite>,
        target: TargetAddr,
        connection: Option<Arc<TrackedConnection>>,
    ) -> Result<()> {
        let session = self.get_or_create_connection().await?;
        let (mut send, mut recv) = session.open_tcp_stream(&target).await?;

        debug!(
            "Hysteria2: relaying TCP to {} via {}:{}",
            target, self.hy2_config.server, self.hy2_config.port
        );

        let tracker = global_tracker();
        let (mut client_reader, mut client_writer) = tokio::io::split(inbound);

        let upload_tracker = connection.clone();
        let download_tracker = connection.clone();

        let client_to_remote = async {
            let mut buf = vec![0u8; 16 * 1024];
            loop {
                let n = client_reader.read(&mut buf).await.map_err(|error| {
                    Error::network(format!("Failed to read from inbound: {error}"))
                })?;
                if n == 0 {
                    break;
                }
                send.write_all(&buf[..n]).await.map_err(|error| {
                    Error::network(format!("Failed to write to Hysteria2: {error}"))
                })?;

                tracker.add_global_upload(n as u64);
                if let Some(connection) = &upload_tracker {
                    connection.add_upload(n as u64);
                }
            }
            send.finish().await.ok();
            Ok::<(), Error>(())
        };

        let remote_to_client = async {
            let mut buf = vec![0u8; 16 * 1024];
            loop {
                match recv.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => {
                        client_writer.write_all(&buf[..n]).await.map_err(|error| {
                            Error::network(format!("Failed to write to inbound: {error}"))
                        })?;

                        tracker.add_global_download(n as u64);
                        if let Some(connection) = &download_tracker {
                            connection.add_download(n as u64);
                        }
                    }
                    Err(error) => {
                        let message = error.to_string();
                        if message.contains("reset") || message.contains("closed") {
                            break;
                        }
                        return Err(Error::network(format!(
                            "Failed to read from Hysteria2: {error}"
                        )));
                    }
                }
            }
            client_writer.shutdown().await.ok();
            Ok::<(), Error>(())
        };

        match tokio::try_join!(client_to_remote, remote_to_client) {
            Ok(_) => Ok(()),
            Err(error) => {
                let message = error.to_string();
                if message.contains("connection")
                    || message.contains("reset")
                    || message.contains("broken")
                {
                    Ok(())
                } else {
                    Err(error)
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[test]
    fn obfs_type_defaults_to_none() {
        assert_eq!(ObfsType::default(), ObfsType::None);
    }

    #[test]
    fn hysteria2_config_defaults_are_the_protocol_defaults() {
        let config = Hysteria2Config::default();
        assert_eq!(config.port, 443);
        assert_eq!(config.alpn, vec!["h3".to_string()]);
        assert!(!config.skip_cert_verify);
        assert!(config.up_mbps.is_none());
        assert!(config.down_mbps.is_none());
    }

    #[test]
    fn varint_roundtrip_covers_every_length_class() {
        for value in [
            0u64,
            37,
            63,
            64,
            16_383,
            16_384,
            1_073_741_823,
            1_073_741_824,
            u64::from(u32::MAX) + 7,
        ] {
            let mut buf = Vec::new();
            write_varint(&mut buf, value);
            assert_eq!(buf.len(), varint_len(value), "encoded length of {value}");
            let (decoded, rest) = read_varint_slice(&buf).expect("varint");
            assert_eq!(decoded, value);
            assert!(rest.is_empty());
        }
    }

    #[test]
    fn addresses_roundtrip_as_host_port_strings() {
        let cases = [
            TargetAddr::Domain("example.com".to_string(), 443),
            TargetAddr::Ip("192.168.1.1:8080".parse().expect("ipv4")),
            TargetAddr::Ip("[::1]:8443".parse().expect("ipv6")),
        ];
        for target in cases {
            let encoded = encode_address(&target);
            let decoded = parse_address(&encoded).expect("parsed");
            assert_eq!(decoded, target);
        }
    }

    #[test]
    fn address_parsing_rejects_garbage() {
        assert!(parse_address("example.com").is_err(), "no port");
        assert!(parse_address("example.com:notaport").is_err());
        assert!(parse_address("[::1:443").is_err(), "unclosed bracket");
    }

    #[test]
    fn udp_message_roundtrip() {
        let msg = write_udp_message(0xdead_beef, 0x1234, 1, 3, "example.com:53", b"payload");
        let (session, packet, frag_id, frag_count, target, payload) =
            parse_udp_message(&msg).expect("parsed");
        assert_eq!(session, 0xdead_beef);
        assert_eq!(packet, 0x1234);
        assert_eq!(frag_id, 1);
        assert_eq!(frag_count, 3);
        assert_eq!(target, TargetAddr::Domain("example.com".to_string(), 53));
        assert_eq!(payload, b"payload");
    }

    #[test]
    fn udp_message_rejects_short_and_truncated_input() {
        assert!(parse_udp_message(&[0u8; 4]).is_err());
        let mut msg = write_udp_message(1, 2, 0, 1, "example.com:53", b"x");
        msg.truncate(11);
        // A truncated address must not be read as a shorter one.
        assert!(parse_udp_message(&msg).is_err());
    }

    #[test]
    fn fragment_assembler_reassembles_in_order() {
        let mut assembler = FragAssembler::new();
        let target = TargetAddr::Domain("example.com".to_string(), 53);
        assert!(
            assembler
                .add(7, 42, 1, 3, target.clone(), b"bb".to_vec())
                .is_none()
        );
        assert!(
            assembler
                .add(7, 42, 0, 3, target.clone(), b"aa".to_vec())
                .is_none()
        );
        let (target_out, payload) = assembler
            .add(7, 42, 2, 3, target.clone(), b"cc".to_vec())
            .expect("complete");
        assert_eq!(target_out, target);
        assert_eq!(payload, b"aabbcc");
    }

    #[test]
    fn fragment_assembler_drops_the_oldest_when_the_cap_is_reached() {
        let mut assembler = FragAssembler::new();
        let target = TargetAddr::Domain("example.com".to_string(), 53);
        assembler.add(1, 1, 0, 2, target.clone(), b"first".to_vec());
        // Force the entry to look old, then add enough new entries to trigger
        // both prune paths (expired, then oldest-first).
        for entry in assembler.pending.values_mut() {
            entry.3 = Instant::now() - (FRAGMENT_TTL + Duration::from_secs(1));
        }
        for id in 0..200u16 {
            assembler.add(2, id, 0, 2, target.clone(), b"x".to_vec());
        }
        assert!(
            assembler.pending.len() <= MAX_PENDING_FRAGMENTS,
            "the buffer must stay bounded, got {}",
            assembler.pending.len()
        );
    }

    #[test]
    fn port_spec_parsing_expands_ranges() {
        assert_eq!(parse_port_spec("443").expect("single"), vec![443]);
        assert_eq!(parse_port_spec("80,443").expect("list"), vec![80, 443]);
        assert_eq!(
            parse_port_spec("20000-20003").expect("range"),
            vec![20000, 20001, 20002, 20003]
        );
        assert_eq!(
            parse_port_spec("443, 20000-20002").expect("mixed"),
            vec![443, 20000, 20001, 20002]
        );
    }

    #[test]
    fn port_spec_parsing_fails_closed() {
        assert!(parse_port_spec("").is_err());
        assert!(parse_port_spec("abc").is_err());
        assert!(parse_port_spec("30000-20000").is_err(), "reversed range");
        assert!(
            parse_port_spec("1-65535").is_err(),
            "a range wider than the cap must not silently expand"
        );
    }

    #[test]
    fn outbound_reports_its_configured_endpoint() {
        use crate::core::config::OutboundType;
        use std::collections::HashMap;

        let mut options = HashMap::new();
        options.insert(
            "password".to_string(),
            serde_yaml::Value::String("secret".to_string()),
        );
        let outbound = Hysteria2Outbound::new(OutboundConfig {
            outbound_type: OutboundType::Hysteria2,
            tag: "hy2".to_string(),
            server: Some("example.com".to_string()),
            port: Some(8443),
            options,
        })
        .expect("outbound");

        assert_eq!(
            outbound.server_addr(),
            Some(("example.com".to_string(), 8443))
        );
        assert!(outbound.supports_udp());
        assert_eq!(outbound.hy2_config().port, 8443);
    }

    #[test]
    fn salamander_without_a_password_fails_closed() {
        use crate::core::config::OutboundType;
        use std::collections::HashMap;

        let mut options = HashMap::new();
        options.insert(
            "password".to_string(),
            serde_yaml::Value::String("secret".to_string()),
        );
        options.insert(
            "obfs".to_string(),
            serde_yaml::Value::String("salamander".to_string()),
        );
        let error = match Hysteria2Outbound::new(OutboundConfig {
            outbound_type: OutboundType::Hysteria2,
            tag: "hy2".to_string(),
            server: Some("example.com".to_string()),
            port: Some(8443),
            options,
        }) {
            Ok(_) => panic!("salamander needs a key"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("obfs-password"), "{error}");
    }

    #[tokio::test]
    async fn auth_response_requires_status_233() {
        // Build the response a server sends on success: a HEADERS frame whose
        // QPACK block carries `:status 233`.
        let qpack = encode_literal_fields(&[(b":status", b"233".as_slice())]);
        let mut frame = Vec::new();
        write_varint(&mut frame, H3_FRAME_HEADERS);
        write_varint(&mut frame, qpack.len() as u64);
        frame.extend_from_slice(&qpack);

        let (mut client, mut server) = tokio::io::duplex(4096);
        client.write_all(&frame).await.expect("write");
        drop(client);

        await_auth_response(&mut server)
            .await
            .expect("233 accepted");
    }

    #[tokio::test]
    async fn auth_response_rejects_other_statuses() {
        let qpack = encode_literal_fields(&[(b":status", b"404".as_slice())]);
        let mut frame = Vec::new();
        write_varint(&mut frame, H3_FRAME_HEADERS);
        write_varint(&mut frame, qpack.len() as u64);
        frame.extend_from_slice(&qpack);

        let (mut client, mut server) = tokio::io::duplex(4096);
        client.write_all(&frame).await.expect("write");
        drop(client);

        let error = await_auth_response(&mut server)
            .await
            .expect_err("404 must not authenticate");
        assert!(error.to_string().contains("status != 233"), "{error}");
    }

    #[tokio::test]
    async fn auth_response_skips_other_frames() {
        // A SETTINGS frame then the HEADERS answer: only the latter decides.
        let mut stream = Vec::new();
        write_varint(&mut stream, H3_SETTINGS_FRAME);
        write_varint(&mut stream, 0);
        let qpack = encode_literal_fields(&[(b":status", b"233".as_slice())]);
        write_varint(&mut stream, H3_FRAME_HEADERS);
        write_varint(&mut stream, qpack.len() as u64);
        stream.extend_from_slice(&qpack);

        let (mut client, mut server) = tokio::io::duplex(4096);
        client.write_all(&stream).await.expect("write");
        drop(client);

        await_auth_response(&mut server)
            .await
            .expect("233 accepted");
    }

    #[tokio::test]
    async fn tcp_response_reads_the_status_and_drains_the_rest() {
        let mut stream = Vec::new();
        stream.push(0u8); // status
        write_varint(&mut stream, 5);
        stream.extend_from_slice(b"hello");
        write_varint(&mut stream, 3);
        stream.extend_from_slice(b"pad");

        let (mut client, mut server) = tokio::io::duplex(4096);
        client.write_all(&stream).await.expect("write");
        drop(client);

        let status = read_tcp_response(&mut server).await.expect("status");
        assert_eq!(status, 0);
    }

    #[tokio::test]
    async fn tcp_response_reports_a_failure_status() {
        let (mut client, mut server) = tokio::io::duplex(4096);
        client.write_all(&[0x03]).await.expect("write");
        drop(client);

        let status = read_tcp_response(&mut server).await.expect("status");
        assert_eq!(status, 3);
    }
}
