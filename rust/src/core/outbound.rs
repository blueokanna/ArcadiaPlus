use crate::core::config::{Config, OutboundConfig, OutboundType};
use crate::core::error::{Error, Result};
use parking_lot::RwLock as ParkingRwLock;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::RwLock;
use tokio_util::sync::CancellationToken;

mod direct;
mod group;
mod http;
mod hysteria2;
mod reject;
mod shadowsocks;
mod socks5;
mod trojan;
mod tuic;
mod vless;
mod vmess;
mod wireguard;

pub use direct::DirectOutbound;
pub use direct::relay_bidirectional_with_connection;
pub use group::{DIRECT_TAG, GroupMode, GroupOutbound, REJECT_TAG};
pub use http::HttpOutbound;
pub use hysteria2::Hysteria2Outbound;
pub use reject::RejectOutbound;
pub use shadowsocks::ShadowsocksOutbound;
pub use socks5::Socks5Outbound;
pub use trojan::TrojanOutbound;
pub use tuic::TuicOutbound;
pub use vless::VlessOutbound;
pub use vmess::VmessOutbound;
pub use wireguard::WireguardOutbound;

static GLOBAL_SELECTOR_SELECTIONS: OnceLock<ParkingRwLock<HashMap<String, String>>> =
    OnceLock::new();

pub fn get_global_selector_selections() -> &'static ParkingRwLock<HashMap<String, String>> {
    GLOBAL_SELECTOR_SELECTIONS.get_or_init(|| ParkingRwLock::new(HashMap::new()))
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TargetAddr {
    Domain(String, u16),
    Ip(std::net::SocketAddr),
}

impl std::fmt::Display for TargetAddr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TargetAddr::Domain(domain, port) => write!(f, "{}:{}", domain, port),
            TargetAddr::Ip(addr) => write!(f, "{}", addr),
        }
    }
}

impl TargetAddr {
    pub fn new_domain(domain: String, port: u16) -> Self {
        TargetAddr::Domain(domain, port)
    }

    pub fn new_ip(addr: std::net::SocketAddr) -> Self {
        TargetAddr::Ip(addr)
    }

    pub fn port(&self) -> u16 {
        match self {
            TargetAddr::Domain(_, port) => *port,
            TargetAddr::Ip(addr) => addr.port(),
        }
    }

    pub fn host(&self) -> String {
        match self {
            TargetAddr::Domain(domain, _) => domain.clone(),
            TargetAddr::Ip(addr) => addr.ip().to_string(),
        }
    }
}

impl From<TargetAddr> for crate::protocol::Address {
    fn from(target: TargetAddr) -> Self {
        match target {
            TargetAddr::Domain(domain, port) => crate::protocol::Address::Domain(domain, port),
            TargetAddr::Ip(addr) => crate::protocol::Address::from_socket_addr(addr),
        }
    }
}

impl From<&TargetAddr> for crate::protocol::Address {
    fn from(target: &TargetAddr) -> Self {
        match target {
            TargetAddr::Domain(domain, port) => {
                crate::protocol::Address::Domain(domain.clone(), *port)
            }
            TargetAddr::Ip(addr) => crate::protocol::Address::from_socket_addr(*addr),
        }
    }
}

impl From<crate::protocol::Address> for TargetAddr {
    fn from(addr: crate::protocol::Address) -> Self {
        match addr {
            crate::protocol::Address::Domain(domain, port) => TargetAddr::Domain(domain, port),
            crate::protocol::Address::Ipv4(ip, port) => TargetAddr::Ip(std::net::SocketAddr::V4(
                std::net::SocketAddrV4::new(ip, port),
            )),
            crate::protocol::Address::Ipv6(ip, port) => TargetAddr::Ip(std::net::SocketAddr::V6(
                std::net::SocketAddrV6::new(ip, port, 0, 0),
            )),
        }
    }
}

pub type ProxyRegistry = Arc<RwLock<HashMap<String, Arc<dyn OutboundProxy>>>>;

pub struct OutboundManager {
    config: Arc<RwLock<Config>>,
    proxies: ProxyRegistry,
    /// Kept behind a synchronous lock so `start` / `stop` / `reload` can swap
    /// the generation while the manager is shared as `Arc<OutboundManager>`.
    proxy_list: ParkingRwLock<Vec<Arc<dyn OutboundProxy>>>,
    /// Cancelled on `stop()`; every health-check generation gets a fresh token.
    shutdown: ParkingRwLock<CancellationToken>,
    started: AtomicBool,
}

#[async_trait::async_trait]
pub trait OutboundProxy: Send + Sync {
    async fn connect(&self) -> Result<()>;

    async fn disconnect(&self) -> Result<()>;

    fn tag(&self) -> &str;

    fn server_addr(&self) -> Option<(String, u16)> {
        None
    }

    fn supports_udp(&self) -> bool {
        false
    }

    async fn relay_tcp(&self, inbound: Box<dyn AsyncReadWrite>, target: TargetAddr) -> Result<()>;

    async fn relay_tcp_with_connection(
        &self,
        inbound: Box<dyn AsyncReadWrite>,
        target: TargetAddr,
        connection: Option<std::sync::Arc<crate::core::connection_tracker::TrackedConnection>>,
    ) -> Result<()> {
        let _ = connection;
        self.relay_tcp(inbound, target).await
    }

    async fn relay_udp_packet(&self, target: &TargetAddr, data: &[u8]) -> Result<Vec<u8>> {
        let _ = (target, data);
        Err(Error::protocol(format!(
            "UDP relay not supported by outbound '{}'",
            self.tag()
        )))
    }

    async fn test_http_latency(
        &self,
        test_url: &str,
        timeout: std::time::Duration,
    ) -> Result<std::time::Duration>;

    /// For proxy groups: the member a new connection would go through.
    ///
    /// `None` means the outbound is a leaf and terminates the resolution walk.
    fn group_pick(&self) -> Option<String> {
        None
    }

    /// Validate a manual member selection before it is persisted. Leaf
    /// outbounds accept nothing (they have no members).
    fn validate_selection(&self, tag: &str) -> Result<()> {
        Err(Error::config(format!(
            "Outbound '{}' is not a proxy group and cannot select '{}'",
            self.tag(),
            tag
        )))
    }

    /// Refresh state that must be readable synchronously (see
    /// [`OutboundProxy::server_addr`]). Leaf outbounds have nothing to do.
    async fn refresh_leaf(&self) {}

    /// Spawn periodic health checks, if this outbound has any. Groups that
    /// need probing (url-test, fallback) override this; everything else keeps
    /// the no-op default.
    fn spawn_health_checks(self: Arc<Self>, _shutdown: CancellationToken) {}

    /// Lastobserved health of the member a group would use now:`(alive,
    /// latency)`. Leaf outbounds return `None` (they are alive by definition
    /// until a connection says otherwise).
    fn health_snapshot(&self) -> Option<(bool, Option<std::time::Duration>)> {
        None
    }
}

pub trait AsyncReadWrite: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> AsyncReadWrite for T {}

impl OutboundManager {
    pub async fn new(config: Arc<RwLock<Config>>) -> Result<Self> {
        let proxies: ProxyRegistry = Arc::new(RwLock::new(HashMap::new()));
        let (registry, proxy_list) = Self::build(config.clone()).await?;
        *proxies.write().await = registry;

        Ok(Self {
            config,
            proxies,
            proxy_list: ParkingRwLock::new(proxy_list),
            shutdown: ParkingRwLock::new(CancellationToken::new()),
            started: AtomicBool::new(false),
        })
    }

    /// Build the proxy registry from the current configuration.
    ///
    /// Leaf outbounds are created first so that groups can resolve their
    /// members through the shared registry. The same routine backs both the
    /// initial construction and [`OutboundManager::reload`], so a reloaded
    /// configuration behaves exactly like a fresh start.
    async fn build(
        config: Arc<RwLock<Config>>,
    ) -> Result<(
        HashMap<String, Arc<dyn OutboundProxy>>,
        Vec<Arc<dyn OutboundProxy>>,
    )> {
        let proxies: ProxyRegistry = Arc::new(RwLock::new(HashMap::new()));
        let mut proxy_list: Vec<Arc<dyn OutboundProxy>> = Vec::new();
        let mut proxy_group_configs: Vec<OutboundConfig> = Vec::new();

        {
            let config_read = config.read().await;
            for outbound_config in &config_read.outbounds {
                let proxy: Option<Arc<dyn OutboundProxy>> = match outbound_config.outbound_type {
                    OutboundType::Direct => {
                        Some(Arc::new(DirectOutbound::new(outbound_config.clone())))
                    }
                    OutboundType::Reject => {
                        Some(Arc::new(RejectOutbound::new(outbound_config.clone())))
                    }
                    OutboundType::Socks5 => {
                        Some(Arc::new(Socks5Outbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Http => {
                        Some(Arc::new(HttpOutbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Shadowsocks => {
                        Some(Arc::new(ShadowsocksOutbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Vmess => {
                        Some(Arc::new(VmessOutbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Vless => {
                        Some(Arc::new(VlessOutbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Trojan => {
                        Some(Arc::new(TrojanOutbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Wireguard => {
                        Some(Arc::new(WireguardOutbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Tuic => {
                        Some(Arc::new(TuicOutbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Hysteria2 => {
                        Some(Arc::new(Hysteria2Outbound::new(outbound_config.clone())?))
                    }
                    OutboundType::Quic => {
                        return Err(Error::config(format!(
                            "QUIC outbound '{}' is not implemented; refusing unsafe direct fallback",
                            outbound_config.tag
                        )));
                    }
                    OutboundType::Selector
                    | OutboundType::Urltest
                    | OutboundType::Fallback
                    | OutboundType::Loadbalance
                    | OutboundType::Relay => {
                        proxy_group_configs.push(outbound_config.clone());
                        None
                    }
                };

                if let Some(p) = proxy {
                    let tag = p.tag().to_string();
                    proxy_list.push(p.clone());
                    proxies.write().await.insert(tag, p);
                }
            }
        }

        // Second pass: create proxy groups with access to the registry
        for group_config in proxy_group_configs {
            let proxy = Arc::new(GroupOutbound::new(group_config, proxies.clone())?);
            let tag = proxy.tag().to_string();
            proxy_list.push(proxy.clone());
            proxies.write().await.insert(tag, proxy);
        }

        let registry = proxies.read().await.clone();
        Ok((registry, proxy_list))
    }

    pub async fn start(&self) -> Result<()> {
        // Don't pre-connect outbounds on startup - this makes startup much faster
        // Connections will be established on-demand when traffic flows through
        let proxies = self.proxy_list.read().clone();

        // Proxy groups expose their resolved server through a cheap synchronous
        // snapshot; fill it once so the UI can show the right endpoint before
        // the first connection arrives.
        for proxy in &proxies {
            proxy.refresh_leaf().await;
        }
        self.spawn_health_checks(&proxies);

        tracing::info!(
            "OutboundManager started with {} proxies (lazy connection mode)",
            proxies.len()
        );
        Ok(())
    }

    fn spawn_health_checks(&self, proxies: &[Arc<dyn OutboundProxy>]) {
        if self.started.swap(true, Ordering::SeqCst) {
            // Already watching this generation; nothing to spawn.
            return;
        }
        let token = self.shutdown.read().clone();
        for proxy in proxies {
            proxy.clone().spawn_health_checks(token.clone());
        }
    }

    pub async fn stop(&self) -> Result<()> {
        self.shutdown.write().cancel();
        self.started.store(false, Ordering::SeqCst);
        // Bind before the loop: a parking_lot guard in the loop head would be
        // held across the await below and make the future non-`Send`.
        let proxies = self.proxy_list.read().clone();
        for proxy in proxies {
            proxy.disconnect().await?;
        }
        Ok(())
    }

    /// Rebuild every outbound and proxy group from the configuration that the
    /// manager was created (or last reloaded) with.
    ///
    /// The old health-check generation is cancelled first so probing stops
    /// against proxies that are about to be dropped.
    pub async fn reload(&self) -> Result<()> {
        let (registry, proxy_list) = Self::build(self.config.clone()).await?;

        self.shutdown.write().cancel();
        *self.shutdown.write() = CancellationToken::new();
        self.started.store(false, Ordering::SeqCst);

        *self.proxies.write().await = registry;
        *self.proxy_list.write() = proxy_list;

        let proxies = self.proxy_list.read().clone();
        for proxy in &proxies {
            proxy.refresh_leaf().await;
        }
        self.spawn_health_checks(&proxies);
        tracing::info!("OutboundManager reloaded {} proxies", proxies.len());
        Ok(())
    }

    /// Get a proxy by tag
    pub fn get_proxy(&self, tag: &str) -> Option<Arc<dyn OutboundProxy>> {
        // Use blocking read since this is called from sync context
        // In production, consider using try_read or making this async
        if let Ok(proxies) = self.proxies.try_read() {
            proxies.get(tag).cloned()
        } else {
            None
        }
    }

    /// Get a proxy by tag (async version)
    pub async fn get_proxy_async(&self, tag: &str) -> Option<Arc<dyn OutboundProxy>> {
        self.proxies.read().await.get(tag).cloned()
    }

    /// Get all proxy tags
    pub fn get_all_tags(&self) -> Vec<String> {
        self.proxy_list
            .read()
            .iter()
            .map(|p| p.tag().to_string())
            .collect()
    }

    /// Get config
    pub fn config(&self) -> Arc<RwLock<Config>> {
        self.config.clone()
    }

    /// Get proxy registry (for proxy groups)
    pub fn registry(&self) -> ProxyRegistry {
        self.proxies.clone()
    }

    /// Set the selected proxy in a selector group
    pub async fn set_selector_proxy(&self, group_tag: &str, proxy_tag: &str) -> Result<()> {
        // Clone out of the guard first: `refresh_leaf` resolves through the
        // registry and must not be called while this guard is held.
        let group = self.proxies.read().await.get(group_tag).cloned();
        let Some(group) = group else {
            return Err(Error::config(format!(
                "Proxy group '{}' not found",
                group_tag
            )));
        };

        // Validate against the group's member list before persisting anything.
        group.validate_selection(proxy_tag)?;

        get_global_selector_selections()
            .write()
            .insert(group_tag.to_string(), proxy_tag.to_string());
        group.refresh_leaf().await;

        tracing::info!("Selector '{}' selection set to '{}'", group_tag, proxy_tag);
        Ok(())
    }

    /// Get the selected proxy in a selector group
    pub fn get_selector_proxy(&self, group_tag: &str) -> Option<String> {
        let selections = get_global_selector_selections();
        selections.read().get(group_tag).cloned()
    }
}
