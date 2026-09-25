//! Bridge-local mirrors of corduit's public DTOs.
//!
//! `flutter_rust_bridge` walks the types reachable from [`crate::api`],
//! so the bridge needs concrete types it can generate code for. These
//! mirrors exist for that reason only: field-for-field they are
//! corduit's DTOs, and the `From` impls below are the single place where
//! one is turned into the other.

use std::collections::HashMap;

use flutter_rust_bridge::frb;

use corduit as engine;

/// Proxy status information.
#[frb]
#[derive(Debug, Clone)]
pub struct ProxyStatus {
    pub running: bool,
    pub inbound_count: u32,
    pub outbound_count: u32,
    pub connection_count: u32,
    pub memory_usage: u64,
    pub uptime: u64,
}

/// Traffic statistics.
#[frb]
#[derive(Debug, Clone)]
pub struct TrafficStats {
    pub upload: u64,
    pub download: u64,
    pub upload_speed: u64,
    pub download_speed: u64,
}

/// Connection information.
#[frb]
#[derive(Debug, Clone)]
pub struct ConnectionInfo {
    pub id: String,
    pub host: String,
    pub destination: String,
    pub upload: u64,
    pub download: u64,
    pub start_time: u64,
    pub rule: String,
    pub chains: Vec<String>,
}

/// System information.
#[frb]
#[derive(Debug, Clone)]
pub struct SystemInfo {
    pub platform: String,
    pub version: String,
    pub memory_total: u64,
    pub memory_used: u64,
    pub cpu_cores: u32,
    pub cpu_threads: u32,
    pub cpu_name: String,
    pub cpu_usage: f64,
}

/// Latency test result.
#[frb]
#[derive(Debug, Clone)]
pub struct LatencyTestResult {
    pub proxy_name: String,
    pub latency_ms: Option<u32>,
    pub success: bool,
    pub error: Option<String>,
}

/// Active connection for tracking.
#[frb]
#[derive(Debug, Clone)]
pub struct ActiveConnection {
    pub id: String,
    pub inbound_tag: String,
    pub outbound_tag: String,
    pub host: String,
    pub destination_ip: Option<String>,
    pub destination_port: u16,
    pub protocol: String,
    pub network: String,
    pub upload_bytes: u64,
    pub download_bytes: u64,
    pub start_time: u64,
    pub rule: String,
    pub rule_payload: String,
    pub process_name: Option<String>,
}

/// TUN mode status.
#[frb]
#[derive(Debug, Clone)]
pub struct TunStatus {
    pub enabled: bool,
    pub interface_name: Option<String>,
    pub mtu: Option<u32>,
    pub error: Option<String>,
}

/// Traffic statistics DTO.
#[frb]
#[derive(Debug, Clone)]
pub struct TrafficStatsDto {
    pub upload: u64,
    pub download: u64,
    pub total_upload: u64,
    pub total_download: u64,
    pub connection_count: u32,
    pub uptime_secs: u64,
}

/// Connection DTO.
#[frb]
#[derive(Debug, Clone)]
pub struct ConnectionDto {
    pub id: String,
    pub src_addr: String,
    pub dst_addr: String,
    pub dst_domain: Option<String>,
    pub protocol: String,
    pub outbound: String,
    pub upload: u64,
    pub download: u64,
    pub start_time: i64,
    pub rule: Option<String>,
}

/// Proxy info DTO.
#[frb]
#[derive(Debug, Clone)]
pub struct ProxyInfoDto {
    pub tag: String,
    pub protocol_type: String,
    pub server: Option<String>,
    pub port: Option<u16>,
    pub latency_ms: Option<u64>,
    pub alive: bool,
}

/// Proxy group DTO.
#[frb]
#[derive(Debug, Clone)]
pub struct ProxyGroupDto {
    pub tag: String,
    pub group_type: String,
    pub proxies: Vec<String>,
    pub selected: String,
}

/// Proxy latency DTO.
#[frb]
#[derive(Debug, Clone)]
pub struct ProxyLatencyDto {
    pub tag: String,
    pub latency_ms: Option<u64>,
    pub error: Option<String>,
}

/// Rule DTO.
#[frb]
#[derive(Debug, Clone)]
pub struct RuleDto {
    pub rule_type: String,
    pub payload: String,
    pub outbound: String,
    pub matched_count: u64,
}

/// `fallback-filter`: what makes an answer suspect enough to re-resolve it
/// through `fallback`.
#[frb]
#[derive(Debug, Clone)]
pub struct DnsFallbackFilterDto {
    /// Whether a geographic signal may trigger the re-resolve.
    pub geoip: Option<bool>,
    /// The country `geoip` keys on.
    pub geoip_code: Option<String>,
    /// Ranges whose answers always trigger the re-resolve.
    pub ipcidr: Vec<String>,
    /// Suffixes whose answers always trigger the re-resolve.
    pub domain: Vec<String>,
}

/// DNS config DTO.
#[frb]
#[derive(Debug, Clone)]
pub struct DnsConfigDto {
    pub enable: bool,
    pub listen: String,
    pub enhanced_mode: String,
    pub nameservers: Vec<String>,
    pub fallback: Vec<String>,
    /// Per-domain upstream overrides (`nameserver-policy`).
    pub nameserver_policy: HashMap<String, Vec<String>>,
    /// Resolvers used only to resolve an upstream's own host name.
    pub default_nameserver: Vec<String>,
    pub fallback_filter: DnsFallbackFilterDto,
    pub fake_ip_range: String,
    pub fake_ip_filter: Vec<String>,
    pub fake_ip_ttl: u32,
    /// How many static `hosts` entries are in effect.
    ///
    /// The entries themselves stay in the engine: a UI needs the count, and a
    /// hosts block can run to thousands of lines. A count of hosts or of cache
    /// slots cannot approach `u32::MAX`, and the narrower type keeps it a plain
    /// Dart `int` instead of the `BigInt` every byte counter needs.
    pub host_count: u32,
    pub use_hosts: bool,
    /// Forward-cache capacity, in entries.
    pub cache_size: u32,
}

/// RecurseX recursive DNS front-end status.
#[frb]
#[derive(Debug, Clone)]
pub struct RecursiveDnsStatus {
    /// Whether the front-end is accepting queries.
    pub running: bool,
    /// The bound `host:port`, present while [`crate::api::start_recursive_dns`]
    /// has an active listener.
    pub listen: Option<String>,
}

/// Loopback JSON-RPC server status. The token itself is never reported.
#[frb]
#[derive(Debug, Clone)]
pub struct RpcServerStatus {
    /// Whether the server's accept loop is running.
    pub running: bool,
    /// The bound address, `None` while stopped.
    pub addr: Option<String>,
    /// Whether requests must present a bearer token.
    pub token_set: bool,
}

/// Clash-compatible dashboard API status. The secret is never reported.
#[frb]
#[derive(Debug, Clone)]
pub struct ExternalControllerStatus {
    /// Whether the controller's accept loop is running.
    pub running: bool,
    /// The bound address, `None` while stopped.
    pub addr: Option<String>,
    /// Whether requests must present `general.secret`.
    pub secret_required: bool,
}

/// The engine's live `general` settings, read from the running instance.
#[frb]
#[derive(Debug, Clone)]
pub struct GeneralSnapshot {
    /// The configured mode, spelled `rule` / `global` / `direct`.
    pub mode: String,
    /// The runtime override: `1` global, `2` direct, `3` rule, `0` none.
    pub runtime_mode: i32,
    /// The configured log level.
    pub log_level: String,
    /// Whether the inbound listeners accept remote clients.
    pub allow_lan: bool,
    /// The address the inbounds bind to.
    pub bind_address: String,
    /// Whether IPv6 is enabled for outbound dialling.
    pub ipv6: bool,
    /// Whether host-name resolution races its candidate addresses.
    pub tcp_concurrent: bool,
    /// The SOCKS inbound port, when one is configured.
    pub socks_port: Option<u16>,
    /// The mixed inbound port, when one is configured.
    pub mixed_port: Option<u16>,
}

// ============== corduit → bridge conversions ==============

impl From<engine::ProxyStatus> for ProxyStatus {
    fn from(value: engine::ProxyStatus) -> Self {
        Self {
            running: value.running,
            inbound_count: value.inbound_count,
            outbound_count: value.outbound_count,
            connection_count: value.connection_count,
            memory_usage: value.memory_usage,
            uptime: value.uptime,
        }
    }
}

impl From<engine::TrafficStats> for TrafficStats {
    fn from(value: engine::TrafficStats) -> Self {
        Self {
            upload: value.upload,
            download: value.download,
            upload_speed: value.upload_speed,
            download_speed: value.download_speed,
        }
    }
}

impl From<engine::ActiveConnection> for ConnectionInfo {
    fn from(value: engine::ActiveConnection) -> Self {
        Self {
            id: value.id,
            host: value.host,
            destination: match value.destination_ip {
                Some(ip) => format!("{ip}:{}", value.destination_port),
                None => String::new(),
            },
            upload: value.upload_bytes,
            download: value.download_bytes,
            start_time: value.start_time,
            rule: value.rule,
            chains: vec![value.inbound_tag, value.outbound_tag],
        }
    }
}

impl From<engine::ConnectionInfo> for ConnectionInfo {
    fn from(value: engine::ConnectionInfo) -> Self {
        Self {
            id: value.id,
            host: value.host,
            destination: value.destination,
            upload: value.upload,
            download: value.download,
            start_time: value.start_time,
            rule: value.rule,
            chains: value.chains,
        }
    }
}

impl From<engine::SystemInfo> for SystemInfo {
    fn from(value: engine::SystemInfo) -> Self {
        Self {
            platform: value.platform,
            version: value.version,
            memory_total: value.memory_total,
            memory_used: value.memory_used,
            cpu_cores: value.cpu_cores,
            cpu_threads: value.cpu_threads,
            cpu_name: value.cpu_name,
            cpu_usage: value.cpu_usage,
        }
    }
}

impl From<engine::LatencyTestResult> for LatencyTestResult {
    fn from(value: engine::LatencyTestResult) -> Self {
        Self {
            proxy_name: value.proxy_name,
            latency_ms: value.latency_ms,
            success: value.success,
            error: value.error,
        }
    }
}

impl From<engine::ActiveConnection> for ActiveConnection {
    fn from(value: engine::ActiveConnection) -> Self {
        Self {
            id: value.id,
            inbound_tag: value.inbound_tag,
            outbound_tag: value.outbound_tag,
            host: value.host,
            destination_ip: value.destination_ip,
            destination_port: value.destination_port,
            protocol: value.protocol,
            network: value.network,
            upload_bytes: value.upload_bytes,
            download_bytes: value.download_bytes,
            start_time: value.start_time,
            rule: value.rule,
            rule_payload: value.rule_payload,
            process_name: value.process_name,
        }
    }
}

impl From<engine::TunStatus> for TunStatus {
    fn from(value: engine::TunStatus) -> Self {
        Self {
            enabled: value.enabled,
            interface_name: value.interface_name,
            mtu: value.mtu,
            error: value.error,
        }
    }
}

impl From<engine::TrafficStatsDto> for TrafficStatsDto {
    fn from(value: engine::TrafficStatsDto) -> Self {
        Self {
            upload: value.upload,
            download: value.download,
            total_upload: value.total_upload,
            total_download: value.total_download,
            connection_count: value.connection_count,
            uptime_secs: value.uptime_secs,
        }
    }
}

impl From<engine::ConnectionDto> for ConnectionDto {
    fn from(value: engine::ConnectionDto) -> Self {
        Self {
            id: value.id,
            src_addr: value.src_addr,
            dst_addr: value.dst_addr,
            dst_domain: value.dst_domain,
            protocol: value.protocol,
            outbound: value.outbound,
            upload: value.upload,
            download: value.download,
            start_time: value.start_time,
            rule: value.rule,
        }
    }
}

impl From<engine::ProxyInfoDto> for ProxyInfoDto {
    fn from(value: engine::ProxyInfoDto) -> Self {
        Self {
            tag: value.tag,
            protocol_type: value.protocol_type,
            server: value.server,
            port: value.port,
            latency_ms: value.latency_ms,
            alive: value.alive,
        }
    }
}

impl From<engine::ProxyGroupDto> for ProxyGroupDto {
    fn from(value: engine::ProxyGroupDto) -> Self {
        Self {
            tag: value.tag,
            group_type: value.group_type,
            proxies: value.proxies,
            selected: value.selected,
        }
    }
}

impl From<engine::ProxyLatencyDto> for ProxyLatencyDto {
    fn from(value: engine::ProxyLatencyDto) -> Self {
        Self {
            tag: value.tag,
            latency_ms: value.latency_ms,
            error: value.error,
        }
    }
}

impl From<engine::RuleDto> for RuleDto {
    fn from(value: engine::RuleDto) -> Self {
        Self {
            rule_type: value.rule_type,
            payload: value.payload,
            outbound: value.outbound,
            matched_count: value.matched_count,
        }
    }
}

impl From<engine::DnsFallbackFilterDto> for DnsFallbackFilterDto {
    fn from(value: engine::DnsFallbackFilterDto) -> Self {
        Self {
            geoip: value.geoip,
            geoip_code: value.geoip_code,
            ipcidr: value.ipcidr,
            domain: value.domain,
        }
    }
}

impl From<engine::DnsConfigDto> for DnsConfigDto {
    fn from(value: engine::DnsConfigDto) -> Self {
        Self {
            enable: value.enable,
            listen: value.listen,
            enhanced_mode: value.enhanced_mode,
            nameservers: value.nameservers,
            fallback: value.fallback,
            nameserver_policy: value.nameserver_policy,
            default_nameserver: value.default_nameserver,
            fallback_filter: DnsFallbackFilterDto::from(value.fallback_filter),
            fake_ip_range: value.fake_ip_range,
            fake_ip_filter: value.fake_ip_filter,
            fake_ip_ttl: value.fake_ip_ttl,
            host_count: u32::try_from(value.host_count).unwrap_or(u32::MAX),
            use_hosts: value.use_hosts,
            cache_size: u32::try_from(value.cache_size).unwrap_or(u32::MAX),
        }
    }
}

impl From<engine::RpcServerStatus> for RpcServerStatus {
    fn from(value: engine::RpcServerStatus) -> Self {
        Self {
            running: value.running,
            addr: value.addr,
            token_set: value.token_set,
        }
    }
}

impl From<engine::ExternalControllerStatus> for ExternalControllerStatus {
    fn from(value: engine::ExternalControllerStatus) -> Self {
        Self {
            running: value.running,
            addr: value.addr,
            secret_required: value.secret_required,
        }
    }
}

impl From<engine::GeneralSnapshot> for GeneralSnapshot {
    fn from(value: engine::GeneralSnapshot) -> Self {
        Self {
            mode: value.mode,
            runtime_mode: value.runtime_mode,
            log_level: value.log_level,
            allow_lan: value.allow_lan,
            bind_address: value.bind_address,
            ipv6: value.ipv6,
            tcp_concurrent: value.tcp_concurrent,
            socks_port: value.socks_port,
            mixed_port: value.mixed_port,
        }
    }
}

/// Map a vector of engine DTOs through their bridge conversion.
pub(crate) fn convert_vec<S, T: From<S>>(source: Vec<S>) -> Vec<T> {
    source.into_iter().map(T::from).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn traffic_stats_dto_round_trips_every_field() {
        let source = engine::TrafficStatsDto {
            upload: 1,
            download: 2,
            total_upload: 3,
            total_download: 4,
            connection_count: 5,
            uptime_secs: 6,
        };

        let mapped: TrafficStatsDto = source.into();
        assert_eq!(mapped.upload, 1);
        assert_eq!(mapped.download, 2);
        assert_eq!(mapped.total_upload, 3);
        assert_eq!(mapped.total_download, 4);
        assert_eq!(mapped.connection_count, 5);
        assert_eq!(mapped.uptime_secs, 6);
    }

    #[test]
    fn latency_result_keeps_failure_detail() {
        let source = engine::LatencyTestResult {
            proxy_name: "node-1".to_string(),
            latency_ms: None,
            success: false,
            error: Some("timeout".to_string()),
        };

        let mapped: LatencyTestResult = source.into();
        assert_eq!(mapped.proxy_name, "node-1");
        assert_eq!(mapped.latency_ms, None);
        assert!(!mapped.success);
        assert_eq!(mapped.error.as_deref(), Some("timeout"));
    }

    #[test]
    fn convert_vec_maps_every_element() {
        let source = vec![
            engine::ProxyLatencyDto {
                tag: "a".to_string(),
                latency_ms: Some(10),
                error: None,
            },
            engine::ProxyLatencyDto {
                tag: "b".to_string(),
                latency_ms: None,
                error: Some("failed".to_string()),
            },
        ];

        let mapped: Vec<ProxyLatencyDto> = convert_vec(source);
        assert_eq!(mapped.len(), 2);
        assert_eq!(mapped[0].tag, "a");
        assert_eq!(mapped[0].latency_ms, Some(10));
        assert_eq!(mapped[1].error.as_deref(), Some("failed"));
    }
}
