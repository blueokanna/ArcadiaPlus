//! Bridge-local mirrors of corduit's public DTOs.
//!
//! `flutter_rust_bridge` walks the types reachable from [`crate::api`],
//! so the bridge needs concrete types it can generate code for. These
//! mirrors exist for that reason only: field-for-field they are
//! corduit's DTOs, and the `From` impls below are the single place where
//! one is turned into the other.

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

/// DNS config DTO.
#[frb]
#[derive(Debug, Clone)]
pub struct DnsConfigDto {
    pub enable: bool,
    pub listen: String,
    pub enhanced_mode: String,
    pub nameservers: Vec<String>,
    pub fallback: Vec<String>,
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

impl From<engine::DnsConfigDto> for DnsConfigDto {
    fn from(value: engine::DnsConfigDto) -> Self {
        Self {
            enable: value.enable,
            listen: value.listen,
            enhanced_mode: value.enhanced_mode,
            nameservers: value.nameservers,
            fallback: value.fallback,
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
