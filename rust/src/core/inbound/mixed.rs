//! The mixed inbound: HTTP and SOCKS5 on one port.
//!
//! A client tells the two apart in its first byte — `0x05` is a SOCKS5 version
//! byte and nothing else can be — so the listener peeks instead of guessing, and
//! a single port can serve browsers configured as SOCKS5 *and* as HTTP proxies.
//!
//! The HTTP half is framed by [`crate::protocol::h1_server`] and forwarded by
//! [`crate::core::inbound::http_forward`]: the same code the HTTP inbound runs,
//! so `CONNECT` and plain proxy requests behave identically on both ports
//! instead of being two implementations that age apart. The SOCKS5 half
//! (greeting, request, `CONNECT`, reply) stays here: its framing is four bytes
//! of its own protocol, not HTTP.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_util::sync::CancellationToken;

use crate::core::config::InboundConfig;
use crate::core::connection_tracker::{TrackedConnection, global_tracker};
use crate::core::error::{Error, Result};
use crate::core::inbound::auth::{AuthStore, Socks5Greeting};
use crate::core::inbound::http_forward::{self, Forwarded};
use crate::core::inbound::{InboundListener, bind_tcp_listener};
use crate::core::outbound::{OutboundManager, TargetAddr};
use crate::core::routing::Router;
use crate::protocol::h1_server::{
    DEFAULT_MAX_BODY_LEN, DEFAULT_MAX_HEAD_LEN, H1Connection, Response,
};

/// Mixed HTTP/SOCKS5 proxy inbound listener
/// Automatically detects protocol based on first byte
pub struct MixedInbound {
    config: InboundConfig,
    router: Arc<Router>,
    outbound_manager: Arc<OutboundManager>,
    /// Credentials the configuration asks clients to present.
    auth: Arc<AuthStore>,
    cancel_token: CancellationToken,
    running: Arc<AtomicBool>,
}

// SOCKS5 constants
const SOCKS5_VERSION: u8 = 0x05;
const SOCKS5_CMD_CONNECT: u8 = 0x01;
const SOCKS5_ADDR_IPV4: u8 = 0x01;
const SOCKS5_ADDR_DOMAIN: u8 = 0x03;
const SOCKS5_ADDR_IPV6: u8 = 0x04;

#[async_trait::async_trait]
impl InboundListener for MixedInbound {
    async fn start(&self) -> Result<()> {
        self.start_listener().await
    }

    async fn stop(&self) -> Result<()> {
        self.stop_listener().await
    }

    fn tag(&self) -> &str {
        &self.config.tag
    }
}

impl MixedInbound {
    pub fn new(
        config: InboundConfig,
        router: Arc<Router>,
        outbound_manager: Arc<OutboundManager>,
        auth: AuthStore,
    ) -> Self {
        Self {
            config,
            router,
            outbound_manager,
            auth: Arc::new(auth),
            cancel_token: CancellationToken::new(),
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    async fn start_listener(&self) -> Result<()> {
        if self.running.load(Ordering::Relaxed) {
            tracing::warn!(
                "Mixed inbound already running on {}:{}",
                self.config.listen,
                self.config.port
            );
            return Ok(());
        }

        let (listener, addr) = bind_tcp_listener(&self.config.listen, self.config.port, "Mixed")?;

        let router = Arc::clone(&self.router);
        let outbound_manager = Arc::clone(&self.outbound_manager);
        let auth = Arc::clone(&self.auth);
        let cancel_token = self.cancel_token.clone();
        let running = Arc::clone(&self.running);

        running.store(true, Ordering::Relaxed);

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = cancel_token.cancelled() => {
                        tracing::info!("Mixed inbound on {} shutting down", addr);
                        break;
                    }
                    result = listener.accept() => {
                        match result {
                            Ok((stream, peer_addr)) => {
                                let _ = stream.set_nodelay(true);
                                let router = Arc::clone(&router);
                                let outbound_manager = Arc::clone(&outbound_manager);
                                let auth = Arc::clone(&auth);
                                tokio::spawn(async move {
                                    if let Err(err) = Self::handle_connection(stream, peer_addr, router, outbound_manager, auth).await {
                                        tracing::debug!("Mixed connection error from {}: {}", peer_addr, err);
                                    }
                                });
                            }
                            Err(e) => {
                                tracing::error!("Mixed accept error: {}", e);
                            }
                        }
                    }
                }
            }
            running.store(false, Ordering::Relaxed);
            tracing::info!("Mixed inbound on {} stopped", addr);
        });

        tracing::info!("Mixed inbound (HTTP/SOCKS5) listening on {}", addr);
        Ok(())
    }

    async fn stop_listener(&self) -> Result<()> {
        tracing::info!(
            "Stopping Mixed inbound on {}:{}",
            self.config.listen,
            self.config.port
        );
        self.cancel_token.cancel();

        let mut attempts = 0;
        while self.running.load(Ordering::Relaxed) && attempts < 50 {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            attempts += 1;
        }

        Ok(())
    }

    async fn handle_connection(
        stream: TcpStream,
        peer_addr: SocketAddr,
        router: Arc<Router>,
        outbound_manager: Arc<OutboundManager>,
        auth: Arc<AuthStore>,
    ) -> Result<()> {
        // Peek at first byte to detect protocol
        let mut peek_buf = [0u8; 1];
        stream.peek(&mut peek_buf).await.map_err(|e| {
            Error::network(format!(
                "Failed to peek connection from {}: {}",
                peer_addr, e
            ))
        })?;

        let first_byte = peek_buf[0];

        if first_byte == SOCKS5_VERSION {
            // SOCKS5 protocol
            tracing::debug!("Detected SOCKS5 protocol from {}", peer_addr);
            Self::handle_socks5(stream, peer_addr, router, outbound_manager, auth).await
        } else {
            // Assume HTTP protocol
            tracing::debug!("Detected HTTP protocol from {}", peer_addr);
            Self::handle_http(stream, peer_addr, router, outbound_manager, auth).await
        }
    }

    // ============== HTTP Handling ==============

    async fn handle_http(
        stream: TcpStream,
        peer_addr: SocketAddr,
        router: Arc<Router>,
        outbound_manager: Arc<OutboundManager>,
        auth: Arc<AuthStore>,
    ) -> Result<()> {
        let mut connection =
            H1Connection::with_limits(stream, DEFAULT_MAX_HEAD_LEN, DEFAULT_MAX_BODY_LEN);

        loop {
            let request = match connection.read_request().await {
                Ok(Some(request)) => request,
                Ok(None) => break,
                Err(error) => {
                    tracing::debug!("Mixed inbound read error from {peer_addr}: {error}");
                    break;
                }
            };

            let keep_alive = request.keep_alive();

            // Enforce the configured credentials on the HTTP half too: the
            // two protocols share a port but not a security story.
            if !auth.check_proxy_authorization(request.header("proxy-authorization")) {
                tracing::debug!("Mixed inbound rejected unauthenticated client {peer_addr}");
                let mut response = Response::text(407, "Proxy authentication required");
                response.set_header("Proxy-Authenticate", auth.proxy_authenticate_value());
                response.close = !keep_alive;
                if let Err(error) = connection.write_response(&response).await {
                    tracing::debug!("Mixed inbound write error to {peer_addr}: {error}");
                    break;
                }
                if !keep_alive {
                    break;
                }
                continue;
            }

            match http_forward::forward(
                &request,
                &router,
                &outbound_manager,
                DEFAULT_MAX_BODY_LEN,
            )
            .await
            {
                Forwarded::Tunnel(tunnel) => {
                    return http_forward::open_tunnel(connection, tunnel, "mixed").await;
                }
                Forwarded::Response(response) => {
                    let close = response.close || !keep_alive;
                    if let Err(error) = connection.write_response(&response).await {
                        tracing::debug!("Mixed inbound write error to {peer_addr}: {error}");
                        break;
                    }
                    if close {
                        break;
                    }
                }
            }
        }

        Ok(())
    }

    // ============== SOCKS5 Handling ==============

    async fn handle_socks5(
        mut stream: TcpStream,
        peer_addr: SocketAddr,
        router: Arc<Router>,
        outbound_manager: Arc<OutboundManager>,
        auth: Arc<AuthStore>,
    ) -> Result<()> {
        // Greeting + credential sub-negotiation are shared with the SOCKS5
        // inbound so both ports enforce the same credentials.
        match auth.socks5_greeting(&mut stream).await? {
            Socks5Greeting::Accepted => {}
            Socks5Greeting::NoAcceptableMethod => {
                return Err(Error::protocol("No acceptable SOCKS5 auth methods"));
            }
            Socks5Greeting::NotSocks5 => {
                return Err(Error::protocol(format!(
                    "Invalid SOCKS version from {peer_addr}"
                )));
            }
        }

        // Read connection request
        let mut request = [0u8; 4];
        stream
            .read_exact(&mut request)
            .await
            .map_err(|e| Error::protocol(format!("Failed to read SOCKS5 request: {}", e)))?;

        let version = request[0];
        let cmd = request[1];
        let atyp = request[3];

        if version != SOCKS5_VERSION {
            return Err(Error::protocol("Invalid SOCKS5 version in request"));
        }

        if cmd != SOCKS5_CMD_CONNECT {
            // Only support CONNECT command
            Self::send_socks5_error(&mut stream, 0x07).await; // Command not supported
            return Err(Error::protocol(format!(
                "Unsupported SOCKS5 command: {}",
                cmd
            )));
        }

        // Parse destination address
        let target =
            match atyp {
                SOCKS5_ADDR_IPV4 => {
                    let mut addr = [0u8; 4];
                    stream.read_exact(&mut addr).await.map_err(|e| {
                        Error::protocol(format!("Failed to read IPv4 address: {}", e))
                    })?;
                    let ip = Ipv4Addr::new(addr[0], addr[1], addr[2], addr[3]);
                    let mut port_buf = [0u8; 2];
                    stream
                        .read_exact(&mut port_buf)
                        .await
                        .map_err(|e| Error::protocol(format!("Failed to read port: {}", e)))?;
                    let port = u16::from_be_bytes(port_buf);
                    TargetAddr::Ip(SocketAddr::new(IpAddr::V4(ip), port))
                }
                SOCKS5_ADDR_DOMAIN => {
                    let mut len = [0u8; 1];
                    stream.read_exact(&mut len).await.map_err(|e| {
                        Error::protocol(format!("Failed to read domain length: {}", e))
                    })?;
                    let mut domain = vec![0u8; len[0] as usize];
                    stream
                        .read_exact(&mut domain)
                        .await
                        .map_err(|e| Error::protocol(format!("Failed to read domain: {}", e)))?;
                    let domain = String::from_utf8(domain)
                        .map_err(|_| Error::protocol("Invalid domain encoding"))?;
                    let mut port_buf = [0u8; 2];
                    stream
                        .read_exact(&mut port_buf)
                        .await
                        .map_err(|e| Error::protocol(format!("Failed to read port: {}", e)))?;
                    let port = u16::from_be_bytes(port_buf);
                    TargetAddr::Domain(domain, port)
                }
                SOCKS5_ADDR_IPV6 => {
                    let mut addr = [0u8; 16];
                    stream.read_exact(&mut addr).await.map_err(|e| {
                        Error::protocol(format!("Failed to read IPv6 address: {}", e))
                    })?;
                    let ip = Ipv6Addr::from(addr);
                    let mut port_buf = [0u8; 2];
                    stream
                        .read_exact(&mut port_buf)
                        .await
                        .map_err(|e| Error::protocol(format!("Failed to read port: {}", e)))?;
                    let port = u16::from_be_bytes(port_buf);
                    TargetAddr::Ip(SocketAddr::new(IpAddr::V6(ip), port))
                }
                _ => {
                    Self::send_socks5_error(&mut stream, 0x08).await; // Address type not supported
                    return Err(Error::protocol(format!(
                        "Unsupported address type: {}",
                        atyp
                    )));
                }
            };

        // Route the connection
        let outbound_tag = router
            .match_outbound(Some(&target.host()), None, Some(target.port()), None)
            .await;

        tracing::info!("SOCKS5 {} -> {} (from {})", target, outbound_tag, peer_addr);

        // Get the outbound proxy
        let outbound = match outbound_manager.get_proxy(&outbound_tag) {
            Some(proxy) => proxy,
            None => {
                tracing::error!("Outbound '{}' not found", outbound_tag);
                Self::send_socks5_error(&mut stream, 0x01).await; // General failure
                return Err(Error::config(format!(
                    "Outbound '{}' not found",
                    outbound_tag
                )));
            }
        };

        // Send success response first (with dummy bind address)
        // We don't know the actual bind address yet since we're using outbound proxy
        let dummy_addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(0, 0, 0, 0)), 0);
        Self::send_socks5_success(&mut stream, dummy_addr).await?;

        // Try to resolve the destination IP for display
        let destination_ip = match &target {
            TargetAddr::Ip(addr) => Some(addr.ip().to_string()),
            TargetAddr::Domain(domain, _) => {
                tokio::net::lookup_host(format!("{}:{}", domain, target.port()))
                    .await
                    .ok()
                    .and_then(|mut addrs| addrs.next())
                    .map(|addr| addr.ip().to_string())
            }
        };

        // Track the connection with IP address
        let tracked_conn = TrackedConnection::new_with_ip(
            "mixed".to_string(),
            outbound_tag.clone(),
            target.host(),
            destination_ip,
            target.port(),
            "SOCKS5".to_string(),
            "tcp".to_string(),
            "SOCKS5".to_string(),
            target.to_string(),
        );
        let tracker = global_tracker();
        let tracked = tracker.track(tracked_conn);
        let conn_arc = Arc::clone(&tracked);

        // Relay data through the outbound proxy with connection tracking
        if let Err(e) = outbound
            .relay_tcp_with_connection(Box::new(stream), target.clone(), Some(conn_arc))
            .await
        {
            tracing::debug!(
                "SOCKS5 relay error via '{}' to {}: {}",
                outbound.tag(),
                target,
                e
            );
        }

        // Untrack the connection
        tracker.untrack(&tracked.id);

        Ok(())
    }

    async fn send_socks5_error(stream: &mut TcpStream, error_code: u8) {
        let response = [
            SOCKS5_VERSION,
            error_code,
            0x00, // Reserved
            SOCKS5_ADDR_IPV4,
            0,
            0,
            0,
            0, // Bind address
            0,
            0, // Bind port
        ];
        let _ = stream.write_all(&response).await;
    }

    async fn send_socks5_success(stream: &mut TcpStream, addr: SocketAddr) -> Result<()> {
        let mut response = vec![SOCKS5_VERSION, 0x00, 0x00]; // Success

        match addr.ip() {
            IpAddr::V4(ip) => {
                response.push(SOCKS5_ADDR_IPV4);
                response.extend_from_slice(&ip.octets());
            }
            IpAddr::V6(ip) => {
                response.push(SOCKS5_ADDR_IPV6);
                response.extend_from_slice(&ip.octets());
            }
        }

        response.extend_from_slice(&addr.port().to_be_bytes());

        stream
            .write_all(&response)
            .await
            .map_err(|e| Error::network(format!("Failed to send SOCKS5 response: {}", e)))?;

        Ok(())
    }
}
