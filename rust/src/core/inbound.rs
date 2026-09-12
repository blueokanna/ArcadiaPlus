use crate::core::config::{Config, InboundType};
use crate::core::error::{Error, Result};
use crate::core::outbound::OutboundManager;
use crate::core::routing::Router;
use parking_lot::RwLock as ParkingRwLock;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::RwLock;

pub mod auth;
mod http;
mod http_forward;
mod mixed;
mod socks5;

pub use auth::AuthStore;
use http::HttpInbound;
use mixed::MixedInbound;
use socks5::Socks5Inbound;

fn parse_listen_addr(listen: &str, port: u16) -> Result<SocketAddr> {
    let listen = listen.trim();
    let host = listen
        .strip_prefix('[')
        .and_then(|value| value.strip_suffix(']'))
        .unwrap_or(listen);
    let ip = host.parse::<IpAddr>().map_err(|error| {
        Error::config_with_source(format!("Invalid inbound listen address '{listen}'"), error)
    })?;
    Ok(SocketAddr::new(ip, port))
}

fn bind_tcp_listener(listen: &str, port: u16, name: &str) -> Result<(TcpListener, SocketAddr)> {
    let addr = parse_listen_addr(listen, port)?;
    let socket = socket2::Socket::new(
        socket2::Domain::for_address(addr),
        socket2::Type::STREAM,
        Some(socket2::Protocol::TCP),
    )
    .map_err(|error| Error::network(format!("Failed to create {name} socket: {error}")))?;

    socket
        .set_reuse_address(true)
        .map_err(|error| Error::network(format!("Failed to set SO_REUSEADDR: {error}")))?;

    // A wildcard IPv6 listener must also accept the IPv4 loopback traffic used
    // by system-proxy and TUN clients. Explicitly request a dual-stack socket.
    if addr.ip().is_ipv6() && addr.ip().is_unspecified() {
        socket.set_only_v6(false).map_err(|error| {
            Error::network(format!(
                "Failed to enable dual-stack {name} listener: {error}"
            ))
        })?;
    }

    socket
        .set_nonblocking(true)
        .map_err(|error| Error::network(format!("Failed to set non-blocking: {error}")))?;
    socket.bind(&addr.into()).map_err(|error| {
        Error::network(format!("Failed to bind {name} listener to {addr}: {error}"))
    })?;
    socket
        .listen(1024)
        .map_err(|error| Error::network(format!("Failed to listen on {addr}: {error}")))?;

    let listener = TcpListener::from_std(socket.into())
        .map_err(|error| Error::network(format!("Failed to create {name} TcpListener: {error}")))?;
    Ok((listener, addr))
}

/// Inbound connection manager
pub struct InboundManager {
    config: Arc<RwLock<Config>>,
    router: Arc<Router>,
    outbound_manager: Arc<OutboundManager>,
    /// Behind a synchronous lock so `reload` can swap a whole generation
    /// while the manager itself is shared immutably.
    listeners: ParkingRwLock<Vec<Arc<dyn InboundListener>>>,
}

#[async_trait::async_trait]
pub trait InboundListener: Send + Sync {
    async fn start(&self) -> Result<()>;
    async fn stop(&self) -> Result<()>;
    fn tag(&self) -> &str;
}

impl InboundManager {
    pub async fn new(
        config: Arc<RwLock<Config>>,
        router: Arc<Router>,
        outbound_manager: Arc<OutboundManager>,
    ) -> Result<Self> {
        let listeners = Self::build(&config, &router, &outbound_manager).await?;
        Ok(Self {
            config,
            router,
            outbound_manager,
            listeners: ParkingRwLock::new(listeners),
        })
    }

    /// Build one listener per configured inbound, each with the credentials it
    /// must enforce (global `authentication` plus inbound-level username).
    async fn build(
        config: &Arc<RwLock<Config>>,
        router: &Arc<Router>,
        outbound_manager: &Arc<OutboundManager>,
    ) -> Result<Vec<Arc<dyn InboundListener>>> {
        let mut listeners: Vec<Arc<dyn InboundListener>> = Vec::new();

        let config_read = config.read().await;
        for inbound_config in &config_read.inbounds {
            let auth = AuthStore::from_config(
                config_read.general.authentication.as_deref(),
                inbound_config,
            );
            let listener: Arc<dyn InboundListener> = match inbound_config.inbound_type {
                InboundType::Http => Arc::new(HttpInbound::new(
                    inbound_config.clone(),
                    Arc::clone(router),
                    Arc::clone(outbound_manager),
                    auth,
                )),
                InboundType::Socks5 => Arc::new(Socks5Inbound::new(
                    inbound_config.clone(),
                    Arc::clone(router),
                    Arc::clone(outbound_manager),
                    auth,
                )),
                // Mixed supports both HTTP and SOCKS5 with auto-detection
                InboundType::Mixed => Arc::new(MixedInbound::new(
                    inbound_config.clone(),
                    Arc::clone(router),
                    Arc::clone(outbound_manager),
                    auth,
                )),
                _ => {
                    tracing::warn!(
                        "Unsupported inbound type: {:?}",
                        inbound_config.inbound_type
                    );
                    continue;
                }
            };
            listeners.push(listener);
        }

        Ok(listeners)
    }

    pub async fn start(&self) -> Result<()> {
        let listeners = self.listeners.read().clone();
        for listener in listeners {
            listener.start().await?;
        }
        Ok(())
    }

    pub async fn stop(&self) -> Result<()> {
        let listeners = self.listeners.read().clone();
        for listener in listeners {
            listener.stop().await?;
        }
        Ok(())
    }

    /// Rebuild every listener from the current configuration.
    ///
    /// The previous generation is stopped before the new one binds, otherwise
    /// the replacement would fail with `EADDRINUSE` on every port.
    pub async fn reload(&self) -> Result<()> {
        let previous = {
            let mut listeners = self.listeners.write();
            std::mem::take(&mut *listeners)
        };
        for listener in &previous {
            if let Err(error) = listener.stop().await {
                tracing::warn!(tag = %listener.tag(), %error, "failed to stop inbound during reload");
            }
        }
        drop(previous);

        let fresh = Self::build(&self.config, &self.router, &self.outbound_manager).await?;
        for listener in &fresh {
            listener.start().await?;
        }

        let count = fresh.len();
        *self.listeners.write() = fresh;
        tracing::info!("InboundManager reloaded {count} listeners");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::parse_listen_addr;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

    #[test]
    fn parses_ipv4_listen_address() {
        assert_eq!(
            parse_listen_addr("127.0.0.1", 7890).unwrap(),
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 7890)
        );
    }

    #[test]
    fn parses_bracketed_and_unbracketed_ipv6_listen_addresses() {
        let expected = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 7890);
        assert_eq!(parse_listen_addr("::1", 7890).unwrap(), expected);
        assert_eq!(parse_listen_addr("[::1]", 7890).unwrap(), expected);
    }

    #[test]
    fn rejects_non_ip_listen_address() {
        assert!(parse_listen_addr("localhost", 7890).is_err());
    }
}
