//! The HTTP proxy inbound.
//!
//! One listener, two jobs: terminate `CONNECT` into a byte tunnel, and forward
//! ordinary proxy requests. Both are framed by
//! [`crate::protocol::h1_server`] — this crate's own HTTP/1.1 core over
//! `courierust_h1` — and forwarded by
//! [`crate::core::inbound::http_forward`], which the mixed inbound uses too, so
//! the two inbounds cannot answer the same request differently.
//!
//! ## Why the loop, and what it guarantees
//!
//! A client connection is a sequence of requests (keep-alive), so the handler
//! is a loop over [`H1Connection::read_request`]. The loop ends when the client
//! closes, when the read fails, or when the answer said `Connection: close` —
//! never because an individual request failed. A request that cannot be routed
//! is *answered* (`400`/`502`); a proxy that answers errors by hanging up makes
//! every client bug look like a network bug.
//!
//! ## Tunnels start where the request ended
//!
//! The bytes a client sends right after a `CONNECT` head (a `ClientHello`, for
//! instance) may already be in the server's read buffer. The tunnel therefore
//! relays a [`PrefixedStream`]: those bytes first, then the socket. Nothing is
//! discarded, nothing is reordered, and the client cannot detect a delay
//! between its `CONNECT` and the first tunnelled byte.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::net::TcpStream;
use tokio_util::sync::CancellationToken;

use crate::core::config::InboundConfig;
use crate::core::error::Result;
use crate::core::inbound::auth::AuthStore;
use crate::core::inbound::http_forward::{self, Forwarded};
use crate::core::inbound::{InboundListener, bind_tcp_listener};
use crate::core::outbound::OutboundManager;
use crate::core::routing::Router;
use crate::protocol::h1_server::{
    DEFAULT_MAX_BODY_LEN, DEFAULT_MAX_HEAD_LEN, H1Connection, Response,
};

/// HTTP proxy inbound listener
pub struct HttpInbound {
    config: InboundConfig,
    router: Arc<Router>,
    outbound_manager: Arc<OutboundManager>,
    /// Credentials the configuration asks clients to present.
    auth: Arc<AuthStore>,
    cancel_token: CancellationToken,
    running: Arc<AtomicBool>,
}

#[async_trait::async_trait]
impl InboundListener for HttpInbound {
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

impl HttpInbound {
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
                "HTTP inbound already running on {}:{}",
                self.config.listen,
                self.config.port
            );
            return Ok(());
        }

        let (listener, addr) = bind_tcp_listener(&self.config.listen, self.config.port, "HTTP")?;

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
                        tracing::info!("HTTP inbound on {} shutting down", addr);
                        break;
                    }
                    result = listener.accept() => {
                        match result {
                            Ok((stream, peer_addr)) => {
                                // Accepted sockets inherit the listener's
                                // non-blocking mode but keep Nagle on; a proxy
                                // that batches a response head with the first
                                // body byte is slower for no benefit.
                                let _ = stream.set_nodelay(true);
                                let router = Arc::clone(&router);
                                let outbound_manager = Arc::clone(&outbound_manager);
                                let auth = Arc::clone(&auth);
                                tokio::spawn(async move {
                                    if let Err(err) = Self::handle_connection(stream, peer_addr, router, outbound_manager, auth).await {
                                        tracing::debug!("HTTP connection error from {}: {}", peer_addr, err);
                                    }
                                });
                            }
                            Err(e) => {
                                tracing::error!("HTTP accept error: {}", e);
                            }
                        }
                    }
                }
            }
            running.store(false, Ordering::Relaxed);
            tracing::info!("HTTP inbound on {} stopped", addr);
        });

        tracing::info!("HTTP inbound listening on {}", addr);
        Ok(())
    }

    async fn stop_listener(&self) -> Result<()> {
        tracing::info!(
            "Stopping HTTP inbound on {}:{}",
            self.config.listen,
            self.config.port
        );
        self.cancel_token.cancel();

        // Wait for graceful shutdown
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
        let mut connection =
            H1Connection::with_limits(stream, DEFAULT_MAX_HEAD_LEN, DEFAULT_MAX_BODY_LEN);

        loop {
            let request = match connection.read_request().await {
                Ok(Some(request)) => request,
                // A clean close between requests is how keep-alive ends.
                Ok(None) => break,
                Err(error) => {
                    tracing::debug!("HTTP inbound read error from {peer_addr}: {error}");
                    break;
                }
            };

            let keep_alive = request.keep_alive();

            // Enforce the configured credentials. Without this the inbound is
            // an open proxy for anyone who can reach the port.
            if !auth.check_proxy_authorization(request.header("proxy-authorization")) {
                tracing::debug!("HTTP inbound rejected unauthenticated client {peer_addr}");
                let mut response = Response::text(407, "Proxy authentication required");
                response.set_header("Proxy-Authenticate", auth.proxy_authenticate_value());
                response.close = !keep_alive;
                if let Err(error) = connection.write_response(&response).await {
                    tracing::debug!("HTTP inbound write error to {peer_addr}: {error}");
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
                    // The connection becomes a raw pipe; there is no "next
                    // request" after a successful CONNECT. The relay lives in
                    // `http_forward` so the mixed inbound tunnels identically.
                    return http_forward::open_tunnel(connection, tunnel, "http").await;
                }
                Forwarded::Response(response) => {
                    let close = response.close || !keep_alive;
                    if let Err(error) = connection.write_response(&response).await {
                        tracing::debug!("HTTP inbound write error to {peer_addr}: {error}");
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
}
