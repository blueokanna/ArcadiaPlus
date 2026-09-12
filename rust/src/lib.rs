//! # VeloGuard core
//!
//! One crate, one `src` tree, five layers:
//!
//! ```text
//! api  ─┬─ core ─── protocol      (wire formats, TLS, QUIC, WireGuard, TUIC)
//!       ├─ dns                     (upstream resolution, cache, fake-IP, DoH/DoT)
//!       └─ netstack                (TUN device, user-space TCP/IP, NAT)
//! ```
//!
//! The Flutter frontend only ever talks to [`api`]; everything below it is an
//! implementation detail that is free to move. Layers talk *downwards* through
//! explicit types — no layer reaches back into the UI.
//!
//! `rust-version` is pinned to the oldest toolchain this crate is expected to
//! build with; `edition = 2024` is used so `unsafe_op_in_unsafe_fn` and the
//! stricter temporary-scope rules apply.
#![allow(unexpected_cfgs)]

mod frb_generated;
mod logging;

use std::sync::Arc;
use tokio::sync::RwLock;

use crate::core::VeloGuard;

/// Flutter Rust Bridge surface: the only stable ABI exported to Dart.
pub mod api;
/// Proxy engine: configuration, routing rules, inbounds and outbounds.
pub mod core;
/// In-house cryptography: the single entry point for every primitive we use.
pub mod crypto;
/// DNS stack: upstream selection, caching, fake-IP and local servers.
pub mod dns;
/// HTTP: the one egress path for document fetches, on `courierust`.
pub mod http;
/// User-space network stack: TUN devices, TCP/UDP NAT, packet plumbing.
pub mod netstack;
/// Wire protocols and transports shared by every outbound.
pub mod protocol;

mod error;
mod types;

#[cfg(target_os = "android")]
pub mod android_jni;

pub use api::*;
pub use error::*;
pub use types::*;

use std::sync::Once;

static CRYPTO_PROVIDER: Once = Once::new();

/// Install the process-wide rustls crypto provider.
///
/// `rustls` 0.23 refuses to pick a provider on your behalf, and several
/// dependencies here (tokio-rustls for inbound TLS and the TLS transport,
/// rustls itself for the DoH server) build their own clients: the first such
/// build panics with "No rustls crypto provider is configured" unless
/// *something* installed a default. Leaving that to chance turns
/// which-subsystem-starts-first into a crash, so every entry point that can
/// construct a TLS client funnels through here (the router, the proxy manager,
/// and each direct TLS user).
///
/// QUIC is not on this list: it runs on corduit's own TLS 1.3-over-QUIC stack,
/// which needs no rustls provider.
///
/// HTTP(S) document fetches do not need this either: `crate::http` speaks over
/// `courierust`, which brings its own TLS stack, and so do the proxy inbounds
/// (`courierust_h1` framing, no rustls client involved).
///
/// Lives at the crate root because both `core` and `netstack` need it and the
/// layers below `core` must not reach back up into it. Idempotent after the
/// first call: `install_default` returns `Err` when a provider (including one
/// the host application installed) already exists, and that is fine — a process
/// has exactly one either way.
pub fn install_crypto_provider() {
    CRYPTO_PROVIDER.call_once(|| {
        if rustls::crypto::ring::default_provider()
            .install_default()
            .is_err()
        {
            tracing::debug!("A rustls crypto provider was already installed; keeping it");
        }
    });
}

static VELOGUARD_INSTANCE: once_cell::sync::Lazy<Arc<RwLock<Option<VeloGuard>>>> =
    once_cell::sync::Lazy::new(|| Arc::new(RwLock::new(None)));

pub(crate) static TUN_LIFECYCLE_LOCK: once_cell::sync::Lazy<tokio::sync::Mutex<()>> =
    once_cell::sync::Lazy::new(|| tokio::sync::Mutex::new(()));

#[cfg(target_os = "android")]
static ANDROID_VPN_PROCESSOR: once_cell::sync::Lazy<
    Arc<parking_lot::RwLock<Option<Arc<crate::netstack::AndroidVpnProcessor>>>>,
> = once_cell::sync::Lazy::new(|| Arc::new(parking_lot::RwLock::new(None)));

#[cfg(target_os = "android")]
static ANDROID_TUN_DEVICE: once_cell::sync::Lazy<
    parking_lot::Mutex<Option<crate::netstack::TunDevice>>,
> = once_cell::sync::Lazy::new(|| parking_lot::Mutex::new(None));

#[cfg(target_os = "android")]
static ANDROID_PACKET_TASK: once_cell::sync::Lazy<
    parking_lot::Mutex<Option<tokio::task::JoinHandle<()>>>,
> = once_cell::sync::Lazy::new(|| parking_lot::Mutex::new(None));

/// Global Windows VPN processor for stats tracking
#[cfg(windows)]
static WINDOWS_VPN_PROCESSOR: once_cell::sync::Lazy<
    Arc<parking_lot::RwLock<Option<Arc<crate::netstack::WindowsVpnProcessor>>>>,
> = once_cell::sync::Lazy::new(|| Arc::new(parking_lot::RwLock::new(None)));

/// Global Windows route manager
#[cfg(windows)]
static WINDOWS_ROUTE_MANAGER: once_cell::sync::Lazy<
    Arc<parking_lot::RwLock<Option<crate::netstack::WindowsRouteManager>>>,
> = once_cell::sync::Lazy::new(|| Arc::new(parking_lot::RwLock::new(None)));

/// Global Windows TUN device
#[cfg(windows)]
static WINDOWS_TUN_DEVICE: once_cell::sync::Lazy<
    Arc<parking_lot::RwLock<Option<crate::netstack::TunDevice>>>,
> = once_cell::sync::Lazy::new(|| Arc::new(parking_lot::RwLock::new(None)));

#[cfg(target_os = "linux")]
static LINUX_VPN_PROCESSOR: once_cell::sync::Lazy<
    parking_lot::RwLock<Option<Arc<crate::netstack::TunPacketProcessor>>>,
> = once_cell::sync::Lazy::new(|| parking_lot::RwLock::new(None));

#[cfg(target_os = "linux")]
static LINUX_TUN_DEVICE: once_cell::sync::Lazy<
    parking_lot::Mutex<Option<crate::netstack::TunDevice>>,
> = once_cell::sync::Lazy::new(|| parking_lot::Mutex::new(None));

#[cfg(target_os = "linux")]
static LINUX_ROUTE_MANAGER: once_cell::sync::Lazy<
    parking_lot::Mutex<Option<crate::netstack::RouteManager>>,
> = once_cell::sync::Lazy::new(|| parking_lot::Mutex::new(None));

#[cfg(target_os = "linux")]
static LINUX_PACKET_TASK: once_cell::sync::Lazy<
    parking_lot::Mutex<Option<tokio::task::JoinHandle<()>>>,
> = once_cell::sync::Lazy::new(|| parking_lot::Mutex::new(None));

/// Set the global Android VPN processor
#[cfg(target_os = "android")]
pub fn set_android_vpn_processor(processor: Arc<crate::netstack::AndroidVpnProcessor>) {
    let mut guard = ANDROID_VPN_PROCESSOR.write();
    *guard = Some(processor);
    tracing::info!("Android VPN processor stored globally for stats tracking");
}

/// Clear the global Android VPN processor
#[cfg(target_os = "android")]
pub fn clear_android_vpn_processor() {
    let mut guard = ANDROID_VPN_PROCESSOR.write();
    *guard = None;
    tracing::info!("Android VPN processor cleared");
}

/// Get the global Android VPN processor
#[cfg(target_os = "android")]
pub fn get_android_vpn_processor() -> Option<Arc<crate::netstack::AndroidVpnProcessor>> {
    let guard = ANDROID_VPN_PROCESSOR.read();
    guard.clone()
}

#[cfg(target_os = "android")]
pub fn set_android_tun_device(device: crate::netstack::TunDevice) {
    *ANDROID_TUN_DEVICE.lock() = Some(device);
}

#[cfg(target_os = "android")]
pub fn take_android_tun_device() -> Option<crate::netstack::TunDevice> {
    ANDROID_TUN_DEVICE.lock().take()
}

#[cfg(target_os = "android")]
pub fn set_android_packet_task(task: tokio::task::JoinHandle<()>) {
    *ANDROID_PACKET_TASK.lock() = Some(task);
}

#[cfg(target_os = "android")]
pub fn take_android_packet_task() -> Option<tokio::task::JoinHandle<()>> {
    ANDROID_PACKET_TASK.lock().take()
}

#[cfg(target_os = "linux")]
pub fn set_linux_vpn_processor(processor: Arc<crate::netstack::TunPacketProcessor>) {
    *LINUX_VPN_PROCESSOR.write() = Some(processor);
}

#[cfg(target_os = "linux")]
pub fn get_linux_vpn_processor() -> Option<Arc<crate::netstack::TunPacketProcessor>> {
    LINUX_VPN_PROCESSOR.read().clone()
}

#[cfg(target_os = "linux")]
pub fn take_linux_vpn_processor() -> Option<Arc<crate::netstack::TunPacketProcessor>> {
    LINUX_VPN_PROCESSOR.write().take()
}

#[cfg(target_os = "linux")]
pub fn set_linux_tun_device(device: crate::netstack::TunDevice) {
    *LINUX_TUN_DEVICE.lock() = Some(device);
}

#[cfg(target_os = "linux")]
pub fn take_linux_tun_device() -> Option<crate::netstack::TunDevice> {
    LINUX_TUN_DEVICE.lock().take()
}

#[cfg(target_os = "linux")]
pub fn linux_tun_device_is_running() -> bool {
    LINUX_TUN_DEVICE
        .lock()
        .as_ref()
        .is_some_and(crate::netstack::TunDevice::is_running)
}

#[cfg(target_os = "linux")]
pub fn set_linux_route_manager(manager: crate::netstack::RouteManager) {
    *LINUX_ROUTE_MANAGER.lock() = Some(manager);
}

#[cfg(target_os = "linux")]
pub fn take_linux_route_manager() -> Option<crate::netstack::RouteManager> {
    LINUX_ROUTE_MANAGER.lock().take()
}

#[cfg(target_os = "linux")]
pub fn set_linux_packet_task(task: tokio::task::JoinHandle<()>) {
    *LINUX_PACKET_TASK.lock() = Some(task);
}

#[cfg(target_os = "linux")]
pub fn take_linux_packet_task() -> Option<tokio::task::JoinHandle<()>> {
    LINUX_PACKET_TASK.lock().take()
}

#[cfg(target_os = "linux")]
pub fn linux_packet_task_is_running() -> bool {
    LINUX_PACKET_TASK
        .lock()
        .as_ref()
        .is_some_and(|task| !task.is_finished())
}

/// Set the global Windows VPN processor
#[cfg(windows)]
pub fn set_windows_vpn_processor(processor: Arc<crate::netstack::WindowsVpnProcessor>) {
    let mut guard = WINDOWS_VPN_PROCESSOR.write();
    *guard = Some(processor);
    tracing::info!("Windows VPN processor stored globally for stats tracking");
}

/// Clear the global Windows VPN processor
#[cfg(windows)]
pub fn clear_windows_vpn_processor() {
    let mut guard = WINDOWS_VPN_PROCESSOR.write();
    *guard = None;
    tracing::info!("Windows VPN processor cleared");
}

/// Get the global Windows VPN processor
#[cfg(windows)]
pub fn get_windows_vpn_processor() -> Option<Arc<crate::netstack::WindowsVpnProcessor>> {
    let guard = WINDOWS_VPN_PROCESSOR.read();
    guard.clone()
}

#[cfg(windows)]
pub fn take_windows_vpn_processor() -> Option<Arc<crate::netstack::WindowsVpnProcessor>> {
    WINDOWS_VPN_PROCESSOR.write().take()
}

/// Set the global Windows route manager
#[cfg(windows)]
pub fn set_windows_route_manager(manager: crate::netstack::WindowsRouteManager) {
    let mut guard = WINDOWS_ROUTE_MANAGER.write();
    *guard = Some(manager);
    tracing::info!("Windows route manager stored globally");
}

/// Get the global Windows route manager
#[cfg(windows)]
pub fn get_windows_route_manager()
-> Option<parking_lot::MappedRwLockReadGuard<'static, crate::netstack::WindowsRouteManager>> {
    let guard = WINDOWS_ROUTE_MANAGER.read();
    if guard.is_some() {
        Some(parking_lot::RwLockReadGuard::map(guard, |opt| {
            opt.as_ref().unwrap()
        }))
    } else {
        None
    }
}

/// Get mutable access to the global Windows route manager
#[cfg(windows)]
pub fn get_windows_route_manager_mut()
-> Option<parking_lot::MappedRwLockWriteGuard<'static, crate::netstack::WindowsRouteManager>> {
    let guard = WINDOWS_ROUTE_MANAGER.write();
    if guard.is_some() {
        Some(parking_lot::RwLockWriteGuard::map(guard, |opt| {
            opt.as_mut().unwrap()
        }))
    } else {
        None
    }
}

/// Clear the global Windows route manager
#[cfg(windows)]
pub fn clear_windows_route_manager() {
    let mut guard = WINDOWS_ROUTE_MANAGER.write();
    *guard = None;
    tracing::info!("Windows route manager cleared");
}

#[cfg(windows)]
pub fn take_windows_route_manager() -> Option<crate::netstack::WindowsRouteManager> {
    WINDOWS_ROUTE_MANAGER.write().take()
}

/// Set the global Windows TUN device
#[cfg(windows)]
pub fn set_windows_tun_device(device: crate::netstack::TunDevice) {
    let mut guard = WINDOWS_TUN_DEVICE.write();
    *guard = Some(device);
    tracing::info!("Windows TUN device stored globally");
}

/// Clear the global Windows TUN device
#[cfg(windows)]
pub fn clear_windows_tun_device() {
    let mut guard = WINDOWS_TUN_DEVICE.write();
    *guard = None;
    tracing::info!("Windows TUN device cleared");
}

/// Take the global Windows TUN device (removes it from global state)
#[cfg(windows)]
pub fn take_windows_tun_device() -> Option<crate::netstack::TunDevice> {
    let mut guard = WINDOWS_TUN_DEVICE.write();
    guard.take()
}

/// Get the global VeloGuard instance
async fn get_veloguard_instance() -> Result<Arc<RwLock<Option<VeloGuard>>>> {
    Ok(Arc::clone(&VELOGUARD_INSTANCE))
}

#[cfg(test)]
mod tests {
    use super::types::*;
    use proptest::prelude::*;

    // Generators for DTO types
    fn arb_traffic_stats_dto() -> impl Strategy<Value = TrafficStatsDto> {
        (
            any::<u64>(),
            any::<u64>(),
            any::<u64>(),
            any::<u64>(),
            any::<u32>(),
            any::<u64>(),
        )
            .prop_map(
                |(
                    upload,
                    download,
                    total_upload,
                    total_download,
                    connection_count,
                    uptime_secs,
                )| {
                    TrafficStatsDto {
                        upload,
                        download,
                        total_upload,
                        total_download,
                        connection_count,
                        uptime_secs,
                    }
                },
            )
    }

    fn arb_connection_dto() -> impl Strategy<Value = ConnectionDto> {
        (
            "[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}",
            "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}:[0-9]{1,5}",
            "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}",
            proptest::option::of("[a-z]{3,10}\\.[a-z]{2,3}"),
            prop_oneof!["TCP", "UDP", "HTTP", "SOCKS5"],
            "[a-z]{3,10}",
            any::<u64>(),
            any::<u64>(),
            any::<i64>(),
            proptest::option::of("[A-Z]{3,10}"),
        )
            .prop_map(
                |(
                    id,
                    src_addr,
                    dst_addr,
                    dst_domain,
                    protocol,
                    outbound,
                    upload,
                    download,
                    start_time,
                    rule,
                )| {
                    ConnectionDto {
                        id,
                        src_addr,
                        dst_addr,
                        dst_domain,
                        protocol,
                        outbound,
                        upload,
                        download,
                        start_time,
                        rule,
                    }
                },
            )
    }

    fn arb_proxy_info_dto() -> impl Strategy<Value = ProxyInfoDto> {
        (
            "[a-z]{3,10}",
            prop_oneof![
                "direct",
                "reject",
                "shadowsocks",
                "vmess",
                "trojan",
                "wireguard"
            ],
            proptest::option::of("[a-z]{3,10}\\.[a-z]{2,3}"),
            proptest::option::of(1u16..65535u16),
            proptest::option::of(1u64..10000u64),
            any::<bool>(),
        )
            .prop_map(|(tag, protocol_type, server, port, latency_ms, alive)| {
                ProxyInfoDto {
                    tag,
                    protocol_type,
                    server,
                    port,
                    latency_ms,
                    alive,
                }
            })
    }

    fn arb_proxy_group_dto() -> impl Strategy<Value = ProxyGroupDto> {
        (
            "[a-z]{3,10}",
            prop_oneof!["selector", "url-test", "fallback", "load-balance"],
            proptest::collection::vec("[a-z]{3,10}", 1..5),
            "[a-z]{3,10}",
        )
            .prop_map(|(tag, group_type, proxies, selected)| ProxyGroupDto {
                tag,
                group_type,
                proxies,
                selected,
            })
    }

    fn arb_rule_dto() -> impl Strategy<Value = RuleDto> {
        (
            prop_oneof![
                "domain",
                "domain-suffix",
                "domain-keyword",
                "ip-cidr",
                "geoip",
                "match"
            ],
            "[a-z]{3,20}",
            "[a-z]{3,10}",
            any::<u64>(),
        )
            .prop_map(|(rule_type, payload, outbound, matched_count)| RuleDto {
                rule_type,
                payload,
                outbound,
                matched_count,
            })
    }

    fn arb_dns_config_dto() -> impl Strategy<Value = DnsConfigDto> {
        (
            any::<bool>(),
            "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}:[0-9]{1,5}",
            prop_oneof!["normal", "fake-ip"],
            proptest::collection::vec("[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}", 1..3),
            proptest::collection::vec("[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}", 0..2),
        )
            .prop_map(|(enable, listen, enhanced_mode, nameservers, fallback)| {
                DnsConfigDto {
                    enable,
                    listen,
                    enhanced_mode,
                    nameservers,
                    fallback,
                }
            })
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(100))]

        /// **Feature: rust-codebase-optimization, Property 7: FFI Serialization Round-Trip**
        /// **Validates: Requirements 11.1-11.6**
        /// For any TrafficStatsDto, serializing to JSON and deserializing back produces an equivalent value
        #[test]
        fn test_traffic_stats_dto_roundtrip(dto in arb_traffic_stats_dto()) {
            let json = serde_json::to_string(&dto).expect("Failed to serialize");
            let deserialized: TrafficStatsDto = serde_json::from_str(&json).expect("Failed to deserialize");

            prop_assert_eq!(dto.upload, deserialized.upload);
            prop_assert_eq!(dto.download, deserialized.download);
            prop_assert_eq!(dto.total_upload, deserialized.total_upload);
            prop_assert_eq!(dto.total_download, deserialized.total_download);
            prop_assert_eq!(dto.connection_count, deserialized.connection_count);
            prop_assert_eq!(dto.uptime_secs, deserialized.uptime_secs);
        }

        /// **Feature: rust-codebase-optimization, Property 7: FFI Serialization Round-Trip**
        /// **Validates: Requirements 11.1-11.6**
        /// For any ConnectionDto, serializing to JSON and deserializing back produces an equivalent value
        #[test]
        fn test_connection_dto_roundtrip(dto in arb_connection_dto()) {
            let json = serde_json::to_string(&dto).expect("Failed to serialize");
            let deserialized: ConnectionDto = serde_json::from_str(&json).expect("Failed to deserialize");

            prop_assert_eq!(dto.id, deserialized.id);
            prop_assert_eq!(dto.src_addr, deserialized.src_addr);
            prop_assert_eq!(dto.dst_addr, deserialized.dst_addr);
            prop_assert_eq!(dto.dst_domain, deserialized.dst_domain);
            prop_assert_eq!(dto.protocol, deserialized.protocol);
            prop_assert_eq!(dto.outbound, deserialized.outbound);
            prop_assert_eq!(dto.upload, deserialized.upload);
            prop_assert_eq!(dto.download, deserialized.download);
            prop_assert_eq!(dto.start_time, deserialized.start_time);
            prop_assert_eq!(dto.rule, deserialized.rule);
        }

        /// **Feature: rust-codebase-optimization, Property 7: FFI Serialization Round-Trip**
        /// **Validates: Requirements 11.1-11.6**
        /// For any ProxyInfoDto, serializing to JSON and deserializing back produces an equivalent value
        #[test]
        fn test_proxy_info_dto_roundtrip(dto in arb_proxy_info_dto()) {
            let json = serde_json::to_string(&dto).expect("Failed to serialize");
            let deserialized: ProxyInfoDto = serde_json::from_str(&json).expect("Failed to deserialize");

            prop_assert_eq!(dto.tag, deserialized.tag);
            prop_assert_eq!(dto.protocol_type, deserialized.protocol_type);
            prop_assert_eq!(dto.server, deserialized.server);
            prop_assert_eq!(dto.port, deserialized.port);
            prop_assert_eq!(dto.latency_ms, deserialized.latency_ms);
            prop_assert_eq!(dto.alive, deserialized.alive);
        }

        /// **Feature: rust-codebase-optimization, Property 7: FFI Serialization Round-Trip**
        /// **Validates: Requirements 11.1-11.6**
        /// For any ProxyGroupDto, serializing to JSON and deserializing back produces an equivalent value
        #[test]
        fn test_proxy_group_dto_roundtrip(dto in arb_proxy_group_dto()) {
            let json = serde_json::to_string(&dto).expect("Failed to serialize");
            let deserialized: ProxyGroupDto = serde_json::from_str(&json).expect("Failed to deserialize");

            prop_assert_eq!(dto.tag, deserialized.tag);
            prop_assert_eq!(dto.group_type, deserialized.group_type);
            prop_assert_eq!(dto.proxies, deserialized.proxies);
            prop_assert_eq!(dto.selected, deserialized.selected);
        }

        /// **Feature: rust-codebase-optimization, Property 7: FFI Serialization Round-Trip**
        /// **Validates: Requirements 11.1-11.6**
        /// For any RuleDto, serializing to JSON and deserializing back produces an equivalent value
        #[test]
        fn test_rule_dto_roundtrip(dto in arb_rule_dto()) {
            let json = serde_json::to_string(&dto).expect("Failed to serialize");
            let deserialized: RuleDto = serde_json::from_str(&json).expect("Failed to deserialize");

            prop_assert_eq!(dto.rule_type, deserialized.rule_type);
            prop_assert_eq!(dto.payload, deserialized.payload);
            prop_assert_eq!(dto.outbound, deserialized.outbound);
            prop_assert_eq!(dto.matched_count, deserialized.matched_count);
        }

        /// **Feature: rust-codebase-optimization, Property 7: FFI Serialization Round-Trip**
        /// **Validates: Requirements 11.1-11.6**
        /// For any DnsConfigDto, serializing to JSON and deserializing back produces an equivalent value
        #[test]
        fn test_dns_config_dto_roundtrip(dto in arb_dns_config_dto()) {
            let json = serde_json::to_string(&dto).expect("Failed to serialize");
            let deserialized: DnsConfigDto = serde_json::from_str(&json).expect("Failed to deserialize");

            prop_assert_eq!(dto.enable, deserialized.enable);
            prop_assert_eq!(dto.listen, deserialized.listen);
            prop_assert_eq!(dto.enhanced_mode, deserialized.enhanced_mode);
            prop_assert_eq!(dto.nameservers, deserialized.nameservers);
            prop_assert_eq!(dto.fallback, deserialized.fallback);
        }
    }

    /// The Dart client serialises the *whole* DTO tree, explicit `null`s
    /// included, and future clients will send fields this build does not know.
    /// Whatever parses that payload must therefore tolerate `null` → `None`
    /// and ignore unknown keys — otherwise a UI update bricks the engine.
    /// This pins that contract against the in-house codec so a `nextjson`
    /// upgrade cannot silently break the app.
    #[test]
    fn dart_config_json_stays_parseable() {
        let json = r#"{
            "general": {
                "port": 7890,
                "socks_port": null,
                "redir_port": null,
                "tproxy_port": null,
                "mixed_port": 7891,
                "authentication": null,
                "allow_lan": false,
                "bind_address": "127.0.0.1",
                "mode": "rule",
                "log_level": "info",
                "ipv6": false,
                "tcp_concurrent": true,
                "external_controller": null,
                "external_ui": null,
                "secret": null,
                "field_from_a_newer_client": 1
            },
            "dns": {
                "enable": true,
                "listen": "127.0.0.1:1053",
                "nameservers": ["1.1.1.1"],
                "fallback": [],
                "enhanced_mode": "fake-ip"
            },
            "inbounds": [
                {
                    "inbound_type": "mixed",
                    "tag": "mixed-in",
                    "listen": "127.0.0.1",
                    "port": 7891,
                    "options": "{}"
                }
            ],
            "outbounds": [
                {
                    "outbound_type": "direct",
                    "tag": "DIRECT",
                    "server": null,
                    "port": null,
                    "options": "{}"
                }
            ],
            "rules": [
                {
                    "rule_type": "domain-suffix",
                    "payload": "example.com",
                    "outbound": "DIRECT",
                    "process_name": null
                }
            ]
        }"#;

        let config: VeloGuardConfig = nextjson::from_str(json)
            .expect("nextjson must accept the payload the Dart client sends");

        assert_eq!(config.general.port, 7890);
        assert!(config.general.socks_port.is_none());
        assert!(config.general.secret.is_none());
        assert_eq!(config.dns.nameservers, vec!["1.1.1.1".to_string()]);
        assert_eq!(config.inbounds.len(), 1);
        assert_eq!(config.inbounds[0].tag, "mixed-in");
        assert_eq!(config.outbounds[0].tag, "DIRECT");
        assert!(config.outbounds[0].server.is_none());
        assert_eq!(config.rules[0].payload, "example.com");
    }
}
