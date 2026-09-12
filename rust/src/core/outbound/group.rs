//! Proxy groups: `select`, `url-test`, `fallback` and `load-balance`.
//!
//! Every group kind the configuration understands is implemented here, because
//! they share almost all of their machinery (member list, health bookkeeping,
//! nested-group resolution, leaf snapshot) and differ only in *how a member is
//! picked*:
//!
//! | group          | how the member is picked                                   |
//! |----------------|------------------------------------------------------------|
//! | `select`       | the tag the user selected (or `DIRECT` / `REJECT`)          |
//! | `url-test`     | lowest latency, re-measured on `interval` (with `tolerance`) |
//! | `fallback`     | first member in configured order that answers health probes |
//! | `load-balance` | per connection: round-robin / random / consistent hashing   |
//!
//! `relay` groups are accepted only with a single hop: real proxy chaining
//! needs an outbound "dial through me" primitive (each protocol handshake must
//! run over a stream that is itself forwarded by the previous hop) which the
//! [`OutboundProxy`] trait deliberately does not expose yet, so a multi-hop
//! chain is rejected at construction time instead of silently behaving like a
//! selector.
//!
//! ## Why the leaf snapshot exists
//!
//! [`OutboundProxy::server_addr`] is a synchronous call used by the UI thread
//! (see `get_proxies`). Reading the async registry from a sync context would
//! require `blocking_read()`, which panics inside the Tokio runtime, so groups
//! keep a small synchronous snapshot (`leaf_addr` / `leaf_udp`) that is
//! refreshed whenever a member is resolved.

use crate::core::config::{OutboundConfig, OutboundType};
use crate::core::error::{Error, Result};
use crate::core::outbound::{
    AsyncReadWrite, DirectOutbound, OutboundProxy, ProxyRegistry, RejectOutbound, TargetAddr,
    get_global_selector_selections,
};
use futures::stream::{self, StreamExt};
use parking_lot::RwLock as ParkingRwLock;
use serde_yaml::Value as Yaml;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

/// Tag of the built-in direct outbound.
pub const DIRECT_TAG: &str = "DIRECT";
/// Tag of the built-in reject outbound.
pub const REJECT_TAG: &str = "REJECT";

/// Default probe target, identical to the one Clash uses for url-test groups.
const DEFAULT_TEST_URL: &str = "http://www.gstatic.com/generate_204";
/// Default probe period when `interval` is not configured.
const DEFAULT_INTERVAL_SECS: u64 = 300;
/// Default latency improvement (ms) required before url-test switches members.
const DEFAULT_TOLERANCE_MS: u64 = 50;
/// Per-probe timeout when neither `timeout` nor `interval` is configured.
const DEFAULT_PROBE_TIMEOUT_SECS: u64 = 5;
/// Members probed in parallel.
const PROBE_CONCURRENCY: usize = 4;
/// Hard limit for nested group resolution.
const MAX_HOPS: usize = 32;
/// Options that this implementation knowingly does not honour; they are
/// reported once per group instead of being ignored silently.
const UNSUPPORTED_OPTIONS: [&str; 7] = [
    "filter",
    "exclude-filter",
    "use",
    "icon",
    "lazy",
    "expected-status",
    "disable-udp",
];

/// How a group chooses the member a new connection goes through.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupMode {
    /// Manual selection, `OutboundType::Selector` (and single-hop `Relay`).
    Select,
    /// Automatic: lowest measured latency.
    Urltest,
    /// Automatic: first member that passes its health probe.
    Fallback,
    /// Automatic: spread connections over the members.
    Loadbalance,
}

/// Load-balance strategies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LbStrategy {
    RoundRobin,
    Random,
    /// Same destination host always lands on the same member (FNV-1a of the
    /// host over the current member set).
    ConsistentHashing,
}

/// Health bookkeeping for one member.
#[derive(Debug, Clone)]
struct MemberHealth {
    alive: bool,
    latency: Option<Duration>,
    last_check: Option<Instant>,
    failures: u32,
}

impl Default for MemberHealth {
    fn default() -> Self {
        Self {
            alive: true,
            latency: None,
            last_check: None,
            failures: 0,
        }
    }
}

/// A proxy group (`select` / `url-test` / `fallback` / `load-balance`).
pub struct GroupOutbound {
    config: OutboundConfig,
    mode: GroupMode,
    members: Vec<String>,
    registry: ProxyRegistry,
    /// Fallback member when nothing was selected / measured yet.
    default_selected: String,
    /// Member health, written by the prober and by relay outcomes.
    health: ParkingRwLock<HashMap<String, MemberHealth>>,
    /// Cursor for round-robin load balancing (also used by hashing fallbacks).
    cursor: AtomicUsize,
    /// Synchronous snapshot of the resolved leaf, for `server_addr()`.
    leaf_addr: ParkingRwLock<Option<(String, u16)>>,
    /// Synchronous snapshot of the resolved leaf's UDP support.
    leaf_udp: AtomicBool,
    // Probing / selection options.
    test_url: String,
    interval: Duration,
    tolerance: Duration,
    probe_timeout: Duration,
    strategy: LbStrategy,
}

impl GroupOutbound {
    pub fn new(config: OutboundConfig, registry: ProxyRegistry) -> Result<Self> {
        let mode = match config.outbound_type {
            OutboundType::Selector | OutboundType::Relay => GroupMode::Select,
            OutboundType::Urltest => GroupMode::Urltest,
            OutboundType::Fallback => GroupMode::Fallback,
            OutboundType::Loadbalance => GroupMode::Loadbalance,
            other => {
                return Err(Error::config(format!(
                    "Outbound '{}' is {:?}, not a proxy group",
                    config.tag, other
                )));
            }
        };

        let members = Self::parse_members(&config);
        if config.outbound_type == OutboundType::Relay && members.len() > 1 {
            return Err(Error::config(format!(
                "Relay group '{}' lists {} hops but proxy chaining is unavailable: \
                 an outbound can only forward an inbound stream, it cannot dial one \
                 through another hop yet. Use a single hop, a selector, or an external chain.",
                config.tag,
                members.len()
            )));
        }

        let unsupported: Vec<&str> = UNSUPPORTED_OPTIONS
            .iter()
            .copied()
            .filter(|key| config.options.contains_key(*key))
            .collect();
        if !unsupported.is_empty() {
            warn!(
                group = %config.tag,
                options = ?unsupported,
                "proxy group options are not supported by this build and will be ignored"
            );
        }

        let test_url = opt_str(&config.options, "url").unwrap_or_else(|| DEFAULT_TEST_URL.to_string());
        let interval_secs = opt_u64(&config.options, "interval").unwrap_or(DEFAULT_INTERVAL_SECS);
        let tolerance_ms = opt_u64(&config.options, "tolerance").unwrap_or(DEFAULT_TOLERANCE_MS);
        let probe_timeout_secs = opt_u64(&config.options, "timeout")
            .filter(|secs| *secs > 0)
            .unwrap_or_else(|| {
                if interval_secs > 0 {
                    interval_secs.min(DEFAULT_PROBE_TIMEOUT_SECS)
                } else {
                    DEFAULT_PROBE_TIMEOUT_SECS
                }
            });
        let strategy = Self::parse_strategy(&config)?;

        let default_selected = members
            .first()
            .cloned()
            .unwrap_or_else(|| DIRECT_TAG.to_string());

        info!(
            group = %config.tag,
            mode = ?mode,
            members = ?members,
            default = %default_selected,
            "proxy group created"
        );

        Ok(Self {
            config,
            mode,
            members,
            registry,
            default_selected,
            health: ParkingRwLock::new(HashMap::new()),
            cursor: AtomicUsize::new(0),
            leaf_addr: ParkingRwLock::new(None),
            leaf_udp: AtomicBool::new(false),
            test_url,
            interval: Duration::from_secs(interval_secs),
            tolerance: Duration::from_millis(tolerance_ms),
            probe_timeout: Duration::from_secs(probe_timeout_secs),
            strategy,
        })
    }

    /// Members listed in `outbounds` (sequence) or as a JSON/YAML list string.
    fn parse_members(config: &OutboundConfig) -> Vec<String> {
        let raw = config
            .options
            .get("outbounds")
            .or_else(|| config.options.get("proxies"));
        let Some(raw) = raw else {
            warn!(
                group = %config.tag,
                keys = ?config.options.keys().collect::<Vec<_>>(),
                "proxy group has no 'outbounds' member list"
            );
            return Vec::new();
        };

        match raw {
            Yaml::Sequence(items) => items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_owned))
                .collect(),
            Yaml::String(encoded) => nextjson::from_str::<Vec<String>>(encoded)
                .map_err(|err| {
                    warn!(group = %config.tag, %err, "member list is not valid JSON");
                    err
                })
                .unwrap_or_default(),
            other => {
                warn!(group = %config.tag, kind = ?other, "member list has unsupported shape");
                Vec::new()
            }
        }
    }

    fn parse_strategy(config: &OutboundConfig) -> Result<LbStrategy> {
        let Some(raw) = opt_str(&config.options, "strategy") else {
            return Ok(LbStrategy::RoundRobin);
        };
        match raw.to_ascii_lowercase().as_str() {
            "round-robin" | "roundrobin" | "rr" => Ok(LbStrategy::RoundRobin),
            "random" => Ok(LbStrategy::Random),
            "consistent-hashing" | "consistent_hashing" | "consistenthashing" | "hash" => {
                Ok(LbStrategy::ConsistentHashing)
            }
            other => Err(Error::config(format!(
                "Load-balance group '{}' uses unknown strategy '{}' (expected round-robin, random or consistent-hashing)",
                config.tag, other
            ))),
        }
    }

    /// Currently selected member (manual selection / last automatic switch).
    pub fn get_selected(&self) -> String {
        get_global_selector_selections()
            .read()
            .get(&self.config.tag)
            .cloned()
            .unwrap_or_else(|| self.default_selected.clone())
    }

    /// Manual selection; rejects tags that are neither members nor built-ins.
    pub fn set_selected(&self, tag: &str) -> Result<()> {
        self.validate_selection(tag)?;
        get_global_selector_selections()
            .write()
            .insert(self.config.tag.clone(), tag.to_string());
        info!(group = %self.config.tag, selected = %tag, "proxy group selection changed");
        Ok(())
    }

    /// Members of the group.
    pub fn members(&self) -> &[String] {
        &self.members
    }

    fn accepts(&self, tag: &str) -> bool {
        self.members.iter().any(|member| member == tag) || is_builtin(tag)
    }

    /// Member a new connection is sent through (advances the round-robin cursor).
    fn pick_member(&self, target: Option<&TargetAddr>) -> String {
        match self.mode {
            GroupMode::Select => self.manual_selection(),
            GroupMode::Urltest => self.pick_fastest(),
            GroupMode::Fallback => self.pick_first_healthy(),
            GroupMode::Loadbalance => self.pick_balanced(target),
        }
    }

    fn manual_selection(&self) -> String {
        let selected = self.get_selected();
        if self.accepts(&selected) {
            selected
        } else {
            warn!(
                group = %self.config.tag,
                selected = %selected,
                "selected member is no longer part of the group, falling back to '{}'",
                self.default_selected
            );
            self.default_selected.clone()
        }
    }

    /// Fastest member with a measurement; unmeasured groups keep their selection.
    fn pick_fastest(&self) -> String {
        let best = {
            let health = self.health.read();
            let mut best: Option<(String, Duration)> = None;
            for member in &self.members {
                let Some(state) = health.get(member) else {
                    continue;
                };
                if !state.alive {
                    continue;
                }
                let Some(latency) = state.latency else {
                    continue;
                };
                if best.as_ref().is_none_or(|(_, current)| latency < *current) {
                    best = Some((member.clone(), latency));
                }
            }
            best
        };

        match best {
            Some((tag, _)) => tag,
            None => {
                // Nothing measured yet: honour the current/default selection.
                let current = self.get_selected();
                if self.members.iter().any(|member| member == &current) {
                    current
                } else {
                    self.default_selected.clone()
                }
            }
        }
    }

    /// First member that is not known to be down.
    fn pick_first_healthy(&self) -> String {
        let health = self.health.read();
        for member in &self.members {
            match health.get(member) {
                Some(state) if !state.alive => continue,
                _ => return member.clone(),
            }
        }
        drop(health);
        self.default_selected.clone()
    }

    fn pick_balanced(&self, target: Option<&TargetAddr>) -> String {
        let alive: Vec<String> = self
            .members
            .iter()
            .filter(|member| self.is_usable(member))
            .cloned()
            .collect();
        let pool = if alive.is_empty() {
            self.members.clone()
        } else {
            alive
        };
        if pool.is_empty() {
            return self.default_selected.clone();
        }

        let index = match self.strategy {
            LbStrategy::RoundRobin => self.cursor.fetch_add(1, Ordering::Relaxed) % pool.len(),
            LbStrategy::Random => (entropy() % pool.len() as u64) as usize,
            LbStrategy::ConsistentHashing => match target.map(TargetAddr::host) {
                Some(host) if !host.is_empty() => (fnv1a(host.as_bytes()) % pool.len() as u64) as usize,
                _ => self.cursor.fetch_add(1, Ordering::Relaxed) % pool.len(),
            },
        };
        pool.get(index)
            .cloned()
            .unwrap_or_else(|| self.default_selected.clone())
    }

    fn is_usable(&self, member: &str) -> bool {
        match self.health.read().get(member) {
            Some(state) => state.alive,
            None => true,
        }
    }

    fn latency_of(&self, member: &str) -> Option<Duration> {
        self.health.read().get(member).and_then(|state| state.latency)
    }

    fn note_latency(&self, member: &str, latency: Duration) {
        let mut health = self.health.write();
        let entry = health.entry(member.to_string()).or_default();
        entry.alive = true;
        entry.latency = Some(latency);
        entry.last_check = Some(Instant::now());
        entry.failures = 0;
    }

    fn note_failure(&self, member: &str) {
        let mut health = self.health.write();
        let entry = health.entry(member.to_string()).or_default();
        entry.alive = false;
        entry.failures = entry.failures.saturating_add(1);
        entry.last_check = Some(Instant::now());
    }

    fn note_success(&self, member: &str) {
        let mut health = self.health.write();
        let entry = health.entry(member.to_string()).or_default();
        entry.alive = true;
        entry.failures = 0;
    }

    /// Look up a member, falling back to the built-in `DIRECT` / `REJECT` leafs.
    async fn find_proxy(&self, tag: &str) -> Option<Arc<dyn OutboundProxy>> {
        if let Some(proxy) = self.registry.read().await.get(tag).cloned() {
            return Some(proxy);
        }
        builtin_outbound(tag)
    }

    /// Walk nested groups from an explicit first hop down to a leaf outbound.
    async fn resolve_from(&self, first_hop: &str) -> Result<Arc<dyn OutboundProxy>> {
        let mut tag = first_hop.to_string();
        let mut seen: HashSet<String> = HashSet::new();
        seen.insert(self.config.tag.clone());

        for _ in 0..MAX_HOPS {
            if !seen.insert(tag.clone()) {
                return Err(Error::config(format!(
                    "Proxy group '{}' resolves through '{}' twice (selection loop)",
                    self.config.tag, tag
                )));
            }
            let proxy = self.find_proxy(&tag).await.ok_or_else(|| {
                Error::config(format!(
                    "Outbound '{}' referenced by group '{}' is not defined",
                    tag, self.config.tag
                ))
            })?;

            match proxy.group_pick() {
                Some(next) => tag = next,
                None => {
                    *self.leaf_addr.write() = proxy.server_addr();
                    self.leaf_udp.store(proxy.supports_udp(), Ordering::Relaxed);
                    return Ok(proxy);
                }
            }
        }

        Err(Error::config(format!(
            "Proxy group '{}' resolves through more than {} nested groups",
            self.config.tag, MAX_HOPS
        )))
    }

    /// Resolve the member that would be used right now.
    async fn resolve_leaf(&self) -> Result<Arc<dyn OutboundProxy>> {
        let first_hop = self.pick_member(None);
        self.resolve_from(&first_hop).await
    }

    /// Probe every member once and store the result.
    async fn probe_members(&self) {
        let members: Vec<(String, Arc<dyn OutboundProxy>)> = {
            let registry = self.registry.read().await;
            self.members
                .iter()
                .filter_map(|tag| {
                    registry
                        .get(tag)
                        .map(|proxy| (tag.clone(), Arc::clone(proxy)))
                })
                .collect()
        };

        if members.is_empty() {
            debug!(group = %self.config.tag, "no probed members are currently defined");
            return;
        }

        let group = self.config.tag.clone();
        let test_url = self.test_url.clone();
        let probe_timeout = self.probe_timeout;
        stream::iter(members)
            .for_each_concurrent(PROBE_CONCURRENCY, |(tag, proxy)| {
                let group = group.clone();
                let test_url = test_url.clone();
                async move {
                    match tokio::time::timeout(
                        probe_timeout,
                        proxy.test_http_latency(&test_url, probe_timeout),
                    )
                    .await
                    {
                        Ok(Ok(latency)) => {
                            debug!(group = %group, member = %tag, ms = latency.as_millis() as u64, "member healthy");
                            self.note_latency(&tag, latency);
                        }
                        Ok(Err(err)) => {
                            debug!(group = %group, member = %tag, %err, "member probe failed");
                            self.note_failure(&tag);
                        }
                        Err(_) => {
                            debug!(group = %group, member = %tag, "member probe timed out");
                            self.note_failure(&tag);
                        }
                    }
                }
            })
            .await;
    }

    /// Apply url-test / fallback politics after a probe round.
    fn recompute_selection(&self) {
        let candidate = match self.mode {
            GroupMode::Urltest => {
                let current = self.get_selected();
                let fastest = self.pick_fastest();
                if fastest == current {
                    return;
                }
                match (self.latency_of(&fastest), self.latency_of(&current)) {
                    // Only switch when the improvement beats the tolerance.
                    (Some(fastest_latency), Some(current_latency))
                        if fastest_latency + self.tolerance >= current_latency =>
                    {
                        return;
                    }
                    (Some(_), _) => fastest,
                    _ => return,
                }
            }
            GroupMode::Fallback => self.pick_first_healthy(),
            GroupMode::Select | GroupMode::Loadbalance => return,
        };

        if candidate != self.get_selected() {
            info!(group = %self.config.tag, member = %candidate, "proxy group switched member");
            get_global_selector_selections()
                .write()
                .insert(self.config.tag.clone(), candidate);
        }
    }

    async fn watch(self: Arc<Self>, shutdown: CancellationToken) {
        let mut ticker = tokio::time::interval_at(
            tokio::time::Instant::now() + Duration::from_secs(1),
            self.interval,
        );
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        info!(
            group = %self.config.tag,
            interval_secs = self.interval.as_secs(),
            url = %self.test_url,
            "proxy group health checks started"
        );

        loop {
            tokio::select! {
                biased;
                () = shutdown.cancelled() => break,
                _ = ticker.tick() => {
                    self.probe_members().await;
                    self.recompute_selection();
                }
            }
        }

        debug!(group = %self.config.tag, "proxy group health checks stopped");
    }
}

#[async_trait::async_trait]
impl OutboundProxy for GroupOutbound {
    async fn connect(&self) -> Result<()> {
        Ok(())
    }

    async fn disconnect(&self) -> Result<()> {
        Ok(())
    }

    fn tag(&self) -> &str {
        &self.config.tag
    }

    fn server_addr(&self) -> Option<(String, u16)> {
        self.leaf_addr.read().clone()
    }

    fn supports_udp(&self) -> bool {
        self.leaf_udp.load(Ordering::Relaxed)
    }

    fn group_pick(&self) -> Option<String> {
        Some(self.pick_member(None))
    }

    fn health_snapshot(&self) -> Option<(bool, Option<Duration>)> {
        let member = self.get_selected();
        let health = self.health.read();
        health
            .get(&member)
            .map(|state| (state.alive, state.latency))
    }

    fn validate_selection(&self, tag: &str) -> Result<()> {
        if self.accepts(tag) {
            Ok(())
        } else {
            Err(Error::config(format!(
                "Outbound '{}' is not a member of group '{}' (members: {})",
                tag,
                self.config.tag,
                self.members.join(", ")
            )))
        }
    }

    async fn refresh_leaf(&self) {
        if let Err(err) = self.resolve_leaf().await {
            debug!(group = %self.config.tag, %err, "cannot refresh leaf snapshot yet");
        }
    }

    fn spawn_health_checks(self: Arc<Self>, shutdown: CancellationToken) {
        if !matches!(self.mode, GroupMode::Urltest | GroupMode::Fallback) {
            return;
        }
        if self.interval.is_zero() {
            info!(group = %self.config.tag, "periodic probing disabled (interval = 0)");
            return;
        }
        let group = Arc::clone(&self);
        tokio::spawn(async move { group.watch(shutdown).await });
    }

    async fn test_http_latency(
        &self,
        test_url: &str,
        timeout: std::time::Duration,
    ) -> Result<std::time::Duration> {
        let proxy = self.resolve_leaf().await?;
        proxy.test_http_latency(test_url, timeout).await
    }

    async fn relay_tcp(&self, inbound: Box<dyn AsyncReadWrite>, target: TargetAddr) -> Result<()> {
        self.relay_tcp_with_connection(inbound, target, None).await
    }

    async fn relay_tcp_with_connection(
        &self,
        inbound: Box<dyn AsyncReadWrite>,
        target: TargetAddr,
        connection: Option<std::sync::Arc<crate::core::connection_tracker::TrackedConnection>>,
    ) -> Result<()> {
        let member = self.pick_member(Some(&target));
        let proxy = self.resolve_from(&member).await?;

        debug!(
            group = %self.config.tag,
            member = %member,
            leaf = %proxy.tag(),
            %target,
            "proxy group relaying"
        );

        let result = proxy.relay_tcp_with_connection(inbound, target, connection).await;
        match &result {
            Ok(()) => self.note_success(&member),
            Err(err) => {
                debug!(group = %self.config.tag, member = %member, %err, "member relay failed");
                self.note_failure(&member);
            }
        }
        result
    }

    async fn relay_udp_packet(&self, target: &TargetAddr, data: &[u8]) -> Result<Vec<u8>> {
        let proxy = self.resolve_leaf().await?;
        if !proxy.supports_udp() {
            return Err(Error::config(format!(
                "Member '{}' of group '{}' does not support UDP",
                proxy.tag(),
                self.config.tag
            )));
        }
        proxy.relay_udp_packet(target, data).await
    }
}

fn is_builtin(tag: &str) -> bool {
    tag == DIRECT_TAG || tag == REJECT_TAG
}

/// Build the built-in `DIRECT` / `REJECT` leafs when the configuration does not
/// define them explicitly (Clash configurations routinely omit them).
fn builtin_outbound(tag: &str) -> Option<Arc<dyn OutboundProxy>> {
    let outbound_type = match tag {
        DIRECT_TAG => OutboundType::Direct,
        REJECT_TAG => OutboundType::Reject,
        _ => return None,
    };
    let config = OutboundConfig {
        outbound_type,
        tag: tag.to_string(),
        server: None,
        port: None,
        options: HashMap::new(),
    };
    match outbound_type {
        OutboundType::Direct => Some(Arc::new(DirectOutbound::new(config))),
        OutboundType::Reject => Some(Arc::new(RejectOutbound::new(config))),
        _ => None,
    }
}

fn opt_str(options: &HashMap<String, Yaml>, key: &str) -> Option<String> {
    match options.get(key) {
        Some(Yaml::String(value)) if !value.trim().is_empty() => Some(value.clone()),
        _ => None,
    }
}

fn opt_u64(options: &HashMap<String, Yaml>, key: &str) -> Option<u64> {
    match options.get(key) {
        Some(Yaml::Number(number)) => number.as_u64(),
        Some(Yaml::String(text)) => text.trim().parse().ok(),
        _ => None,
    }
}

/// FNV-1a, used for consistent-hashing load balancing.
fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Cheap per-call entropy from the standard library's randomly seeded hasher.
fn entropy() -> u64 {
    use std::hash::{BuildHasher, Hasher};
    std::collections::hash_map::RandomState::new()
        .build_hasher()
        .finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::outbound::ProxyRegistry;
    use tokio::sync::RwLock;

    fn group_config(tag: &str, kind: OutboundType, members: &[&str], extra: &[(&str, Yaml)]) -> OutboundConfig {
        let mut options: HashMap<String, Yaml> = HashMap::new();
        options.insert(
            "outbounds".to_string(),
            Yaml::Sequence(
                members
                    .iter()
                    .map(|member| Yaml::String((*member).to_string()))
                    .collect(),
            ),
        );
        for (key, value) in extra {
            options.insert((*key).to_string(), value.clone());
        }
        OutboundConfig {
            outbound_type: kind,
            tag: tag.to_string(),
            server: None,
            port: None,
            options,
        }
    }

    fn registry() -> ProxyRegistry {
        Arc::new(RwLock::new(HashMap::new()))
    }

    /// Assert a configuration error without requiring `Debug` on the success
    /// type (proxy objects are not printable).
    fn error_of<T>(result: Result<T>, expectation: &str) -> Error {
        match result {
            Ok(_) => panic!("expected an error: {expectation}"),
            Err(error) => error,
        }
    }

    async fn register_group(registry: &ProxyRegistry, group: Arc<GroupOutbound>) {
        registry
            .write()
            .await
            .insert(group.tag().to_string(), group.clone());
    }

    #[test]
    fn parses_members_from_sequence_and_json_string() {
        let sequence = GroupOutbound::new(
            group_config("g-seq", OutboundType::Selector, &["a", "b"], &[]),
            registry(),
        )
        .expect("group");
        assert_eq!(sequence.members(), ["a", "b"]);

        let mut options = HashMap::new();
        options.insert(
            "outbounds".to_string(),
            Yaml::String("[\"x\",\"y\"]".to_string()),
        );
        let encoded = GroupOutbound::new(
            OutboundConfig {
                outbound_type: OutboundType::Selector,
                tag: "g-json".to_string(),
                server: None,
                port: None,
                options,
            },
            registry(),
        )
        .expect("group");
        assert_eq!(encoded.members(), ["x", "y"]);
    }

    #[test]
    fn reject_group_is_not_accepted_as_a_group() {
        let err = error_of(
            GroupOutbound::new(
                group_config("g-direct", OutboundType::Direct, &[], &[]),
                registry(),
            ),
            "direct outbound must not build a group",
        );
        assert!(err.to_string().contains("not a proxy group"));
    }

    #[test]
    fn selection_must_be_a_member() {
        let group = GroupOutbound::new(
            group_config("g-select", OutboundType::Selector, &["a", "b"], &[]),
            registry(),
        )
        .expect("group");

        group.set_selected("b").expect("member selection");
        assert_eq!(group.get_selected(), "b");

        group.set_selected(DIRECT_TAG).expect("built-in selection");
        assert_eq!(group.get_selected(), DIRECT_TAG);

        let err = group.set_selected("nope").expect_err("foreign tag");
        assert!(err.to_string().contains("not a member"));
    }

    #[test]
    fn url_test_prefers_lowest_latency() {
        let group = GroupOutbound::new(
            group_config("g-url", OutboundType::Urltest, &["slow", "fast"], &[]),
            registry(),
        )
        .expect("group");

        group.note_latency("slow", Duration::from_millis(400));
        group.note_latency("fast", Duration::from_millis(30));
        group.recompute_selection();
        assert_eq!(group.pick_member(None), "fast");

        // A tie inside the tolerance keeps the current member.
        group.note_latency("slow", Duration::from_millis(60));
        group.recompute_selection();
        assert_eq!(group.pick_member(None), "fast");
        assert_eq!(group.get_selected(), "fast");
    }

    #[test]
    fn fallback_skips_members_that_failed() {
        let group = GroupOutbound::new(
            group_config("g-fallback", OutboundType::Fallback, &["first", "second"], &[]),
            registry(),
        )
        .expect("group");
        assert_eq!(group.pick_member(None), "first");

        group.note_failure("first");
        group.recompute_selection();
        assert_eq!(group.pick_member(None), "second");
        assert_eq!(group.get_selected(), "second");

        group.note_latency("first", Duration::from_millis(20));
        group.recompute_selection();
        assert_eq!(group.pick_member(None), "first");
    }

    #[test]
    fn load_balance_round_robins_and_hashes_stably() {
        let round_robin = GroupOutbound::new(
            group_config("g-lb-rr", OutboundType::Loadbalance, &["a", "b", "c"], &[]),
            registry(),
        )
        .expect("group");
        let picked: Vec<String> = (0..4).map(|_| round_robin.pick_member(None)).collect();
        assert_eq!(picked, ["a", "b", "c", "a"]);

        let hashed = GroupOutbound::new(
            group_config(
                "g-lb-hash",
                OutboundType::Loadbalance,
                &["a", "b"],
                &[("strategy", Yaml::String("consistent-hashing".to_string()))],
            ),
            registry(),
        )
        .expect("group");
        let target = TargetAddr::new_domain("example.com".to_string(), 443);
        let first = hashed.pick_member(Some(&target));
        let second = hashed.pick_member(Some(&target));
        assert_eq!(first, second, "hashing must be stable per destination");
    }

    #[test]
    fn unknown_load_balance_strategy_fails_closed() {
        let err = error_of(
            GroupOutbound::new(
                group_config(
                    "g-lb-bad",
                    OutboundType::Loadbalance,
                    &["a"],
                    &[("strategy", Yaml::String("magic".to_string()))],
                ),
                registry(),
            ),
            "unknown strategy must be rejected",
        );
        assert!(err.to_string().contains("unknown strategy"));
    }

    #[test]
    fn multi_hop_relay_is_rejected() {
        let err = error_of(
            GroupOutbound::new(
                group_config("g-relay", OutboundType::Relay, &["a", "b"], &[]),
                registry(),
            ),
            "chaining must be rejected",
        );
        assert!(err.to_string().contains("proxy chaining is unavailable"));
    }

    #[tokio::test]
    async fn nested_groups_resolve_to_a_leaf() {
        let registry = registry();
        let leaf = Arc::new(crate::core::outbound::DirectOutbound::new(OutboundConfig {
            outbound_type: OutboundType::Direct,
            tag: "leaf".to_string(),
            server: None,
            port: None,
            options: HashMap::new(),
        }));
        registry.write().await.insert("leaf".to_string(), leaf.clone());

        let inner = Arc::new(
            GroupOutbound::new(
                group_config("nest-inner", OutboundType::Selector, &["leaf"], &[]),
                registry.clone(),
            )
            .expect("inner"),
        );
        register_group(&registry, inner).await;

        let outer = GroupOutbound::new(
            group_config("nest-outer", OutboundType::Selector, &["nest-inner"], &[]),
            registry.clone(),
        )
        .expect("outer");

        let resolved = outer.resolve_leaf().await.expect("leaf");
        assert_eq!(resolved.tag(), "leaf");
        assert!(resolved.supports_udp());
        assert_eq!(outer.group_pick().as_deref(), Some("nest-inner"));
    }

    #[tokio::test]
    async fn selection_loops_are_detected() {
        let registry = registry();
        let first = Arc::new(
            GroupOutbound::new(
                group_config("loop-a", OutboundType::Selector, &["loop-b"], &[]),
                registry.clone(),
            )
            .expect("a"),
        );
        let second = Arc::new(
            GroupOutbound::new(
                group_config("loop-b", OutboundType::Selector, &["loop-a"], &[]),
                registry.clone(),
            )
            .expect("b"),
        );
        register_group(&registry, first.clone()).await;
        register_group(&registry, second).await;

        let err = error_of(first.resolve_leaf().await, "loop must fail");
        assert!(err.to_string().contains("selection loop"), "{err}");
    }

    #[tokio::test]
    async fn missing_member_is_reported() {
        let group = GroupOutbound::new(
            group_config("g-missing", OutboundType::Selector, &["ghost"], &[]),
            registry(),
        )
        .expect("group");
        let err = error_of(group.resolve_leaf().await, "missing member");
        assert!(err.to_string().contains("is not defined"), "{err}");
    }

    #[tokio::test]
    async fn builtin_members_resolve_without_configuration() {
        let group = GroupOutbound::new(
            group_config("g-builtin", OutboundType::Selector, &[DIRECT_TAG], &[]),
            registry(),
        )
        .expect("group");
        let direct = group.resolve_leaf().await.expect("DIRECT leaf");
        assert_eq!(direct.tag(), DIRECT_TAG);

        let reject = GroupOutbound::new(
            group_config("g-builtin-reject", OutboundType::Selector, &[REJECT_TAG], &[]),
            registry(),
        )
        .expect("group");
        let reject_leaf = reject.resolve_leaf().await.expect("REJECT leaf");
        assert_eq!(reject_leaf.tag(), REJECT_TAG);
    }

    #[test]
    fn consistent_hashing_spreads_hosts() {
        let mut buckets = HashSet::new();
        let members: Vec<&str> = vec!["a", "b", "c", "d"];
        for host in ["one.example", "two.example", "three.example", "four.example"] {
            buckets.insert((fnv1a(host.as_bytes()) % members.len() as u64) as usize);
        }
        assert!(buckets.len() > 1, "hashing should not collapse every host");
    }
}
