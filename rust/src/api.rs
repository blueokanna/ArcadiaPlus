//! The FFI surface: one corduit call in, one async Dart future out.
//!
//! corduit's API is synchronous; Dart's FFI contract here is not. Every
//! entry point therefore funnels through [`run`], which moves the work to
//! a blocking worker thread so a `start_proxy` that takes a second, or a
//! latency probe that takes ten, can never stall the Flutter isolate or
//! the async executor.
//!
//! The function set, names and argument order mirror `corduit::api`
//! exactly — this file is a flattening, not a redesign.

use flutter_rust_bridge::frb;

use corduit as engine;

use crate::recursive_dns;
use crate::types::*;

/// Dispatch a corduit call onto a blocking worker.
///
/// The engine's error type is stringified at the boundary; a panicking
/// worker surfaces as an error string rather than taking the bridge down
/// with it.
pub(crate) async fn run<T, E, F>(job: F) -> std::result::Result<T, String>
where
    F: FnOnce() -> std::result::Result<T, E> + Send + 'static,
    E: std::fmt::Display + Send + 'static,
    T: Send + 'static,
{
    match tokio::task::spawn_blocking(job).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(error.to_string()),
        Err(join_error) => Err(format!("corduit worker terminated: {join_error}")),
    }
}

// ============== Lifecycle ==============

/// `flutter_rust_bridge` entry point: installs the default Dart utilities and
/// brings up tracing.
///
/// The subscriber is installed here rather than through `corduit::api::init_app`
/// because corduit's installer runs once per process and cannot change the
/// level afterwards — see [`crate::logging`].
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    let _ = crate::logging::init(tracing::Level::INFO);
}

/// Point the engine's GeoIP matcher at a database file on disk.
///
/// corduit resolves `Country.mmdb` from `CORDUIT_GEOIP_DB`, or next to the
/// running executable. Neither applies to a Flutter app: the asset bundle is
/// sealed inside the APK / `.app` / install directory. The Dart side unpacks
/// the bundled database to a real path and registers it here, which must
/// happen before [`initialize_corduit`] — that call is where the router
/// builds its matcher, and `GEOIP` rules stay inert without a database.
///
/// A missing file is reported instead of silently leaving `GEOIP` rules
/// unmatched, so a broken deployment cannot pass for a working one.
#[frb]
pub async fn set_geoip_database_path(path: String) -> std::result::Result<(), String> {
    run(move || {
        let database = std::path::Path::new(&path);
        if !database.is_file() {
            return Err(format!("GeoIP database not found at {path}"));
        }
        std::env::set_var("CORDUIT_GEOIP_DB", database);
        Ok(())
    })
    .await
}

/// Validate a config without starting anything.
#[frb]
pub async fn test_config(config_json: String) -> std::result::Result<bool, String> {
    run(move || engine::api::test_config(config_json)).await
}

/// Build the engine from a JSON config. Does not start listeners.
#[frb]
pub async fn initialize_corduit(config_json: String) -> std::result::Result<(), String> {
    run(move || engine::api::initialize_corduit(config_json)).await
}

/// Start listeners, outbounds and the DNS server.
#[frb]
pub async fn start_corduit() -> std::result::Result<(), String> {
    run(|| engine::api::start_corduit()).await
}

/// Stop the engine and release every listener it owns.
#[frb]
pub async fn stop_corduit() -> std::result::Result<(), String> {
    run(|| engine::api::stop_corduit()).await
}

/// Replace the running config.
#[frb]
pub async fn reload_corduit(config_json: String) -> std::result::Result<(), String> {
    run(move || engine::api::reload_corduit(config_json)).await
}

/// Engine status snapshot.
#[frb]
pub async fn get_corduit_status() -> std::result::Result<ProxyStatus, String> {
    run(|| engine::api::get_corduit_status().map(ProxyStatus::from)).await
}

// ============== Proxy control ==============

/// Start the engine straight from a config document.
///
/// The name keeps corduit's spelling; the engine parses **JSON** in the
/// `CorduitConfig` shape (`outbound_type`/`inbound_type`/`rule_type` plus a
/// JSON `options` string), not YAML.
#[frb]
pub async fn start_proxy_from_yaml(yaml_config: String) -> std::result::Result<(), String> {
    run(move || engine::api::start_proxy_from_yaml(yaml_config)).await
}

/// Start the engine from a config file holding the same JSON document.
#[frb]
pub async fn start_proxy_from_file(config_path: String) -> std::result::Result<(), String> {
    run(move || engine::api::start_proxy_from_file(config_path)).await
}

#[frb]
pub async fn stop_proxy() -> std::result::Result<(), String> {
    run(|| engine::api::stop_proxy()).await
}

#[frb]
pub async fn is_proxy_running() -> std::result::Result<bool, String> {
    run(|| engine::api::is_proxy_running()).await
}

/// Replace the running config from a config document (JSON, same shape as
/// [`start_proxy_from_yaml`]).
#[frb]
pub async fn reload_config_from_yaml(yaml_config: String) -> std::result::Result<(), String> {
    run(move || engine::api::reload_config_from_yaml(yaml_config)).await
}

/// Replace the running config from a JSON config file on disk.
#[frb]
pub async fn reload_config_from_file(config_path: String) -> std::result::Result<(), String> {
    run(move || engine::api::reload_config_from_file(config_path)).await
}

#[frb]
pub async fn set_proxy_mode(mode: i32) -> std::result::Result<(), String> {
    run(move || engine::api::set_proxy_mode(mode)).await
}

#[frb]
pub async fn get_proxy_mode() -> std::result::Result<i32, String> {
    run(|| engine::api::get_proxy_mode()).await
}

// ============== Proxies & groups ==============

#[frb]
pub async fn get_proxies() -> std::result::Result<Vec<ProxyInfoDto>, String> {
    run(|| engine::api::get_proxies().map(|proxies| convert_vec(proxies))).await
}

#[frb]
pub async fn get_proxy_groups() -> std::result::Result<Vec<ProxyGroupDto>, String> {
    run(|| engine::api::get_proxy_groups().map(|groups| convert_vec(groups))).await
}

#[frb]
pub async fn select_proxy(group_tag: String, proxy_tag: String) -> std::result::Result<(), String> {
    run(move || engine::api::select_proxy(group_tag, proxy_tag)).await
}

#[frb]
pub async fn select_proxy_in_group(
    group_name: String,
    proxy_name: String,
) -> std::result::Result<bool, String> {
    run(move || engine::api::select_proxy_in_group(group_name, proxy_name)).await
}

#[frb]
pub async fn get_selected_proxy_in_group(
    group_name: String,
) -> std::result::Result<Option<String>, String> {
    run(move || engine::api::get_selected_proxy_in_group(group_name)).await
}

// ============== Latency probes ==============

/// Round-trip to `test_url` through the named outbound; returns millis.
#[frb]
pub async fn test_proxy_latency_dto(
    tag: String,
    test_url: String,
    timeout_ms: u64,
) -> std::result::Result<u64, String> {
    run(move || engine::api::test_proxy_latency_dto(tag, test_url, timeout_ms)).await
}

#[frb]
pub async fn test_all_proxies_latency(
    test_url: String,
    timeout_ms: u64,
) -> std::result::Result<Vec<ProxyLatencyDto>, String> {
    run(move || engine::api::test_all_proxies_latency(test_url, timeout_ms).map(convert_vec)).await
}

#[frb]
pub async fn test_proxy_latency(
    server: String,
    port: u16,
    timeout_ms: u32,
) -> std::result::Result<LatencyTestResult, String> {
    run(move || {
        engine::api::test_proxy_latency(server, port, timeout_ms).map(LatencyTestResult::from)
    })
    .await
}

#[frb]
pub async fn test_outbound_latency(
    outbound_name: String,
    timeout_ms: u32,
) -> std::result::Result<LatencyTestResult, String> {
    run(move || {
        engine::api::test_outbound_latency(outbound_name, timeout_ms).map(LatencyTestResult::from)
    })
    .await
}

#[frb]
pub async fn test_tcp_connectivity(
    server: String,
    port: u16,
    timeout_ms: u32,
) -> std::result::Result<LatencyTestResult, String> {
    run(move || {
        engine::api::test_tcp_connectivity(server, port, timeout_ms).map(LatencyTestResult::from)
    })
    .await
}

#[frb]
pub async fn test_shadowsocks_latency(
    server: String,
    port: u16,
    password: String,
    cipher: String,
    timeout_ms: u32,
) -> std::result::Result<LatencyTestResult, String> {
    run(move || {
        engine::api::test_shadowsocks_latency(server, port, password, cipher, timeout_ms)
            .map(LatencyTestResult::from)
    })
    .await
}

#[frb]
pub async fn test_proxies_latency(
    proxies: Vec<(String, u16)>,
    timeout_ms: u32,
) -> std::result::Result<Vec<LatencyTestResult>, String> {
    run(move || engine::api::test_proxies_latency(proxies, timeout_ms).map(convert_vec)).await
}

// ============== Traffic & connections ==============

#[frb]
pub async fn get_traffic_stats() -> std::result::Result<TrafficStats, String> {
    run(|| engine::api::get_traffic_stats().map(TrafficStats::from)).await
}

#[frb]
pub async fn get_traffic_stats_dto() -> std::result::Result<TrafficStatsDto, String> {
    run(|| engine::api::get_traffic_stats_dto().map(TrafficStatsDto::from)).await
}

#[frb]
pub async fn get_connections() -> std::result::Result<Vec<ConnectionInfo>, String> {
    // corduit's `get_connections` discards the tracker result and always
    // returns an empty list, so the connection list is fed from the
    // tracker-backed active connections instead.
    run(|| engine::api::get_active_connections().map(convert_vec)).await
}

#[frb]
pub async fn get_connections_dto() -> std::result::Result<Vec<ConnectionDto>, String> {
    run(|| engine::api::get_connections_dto().map(convert_vec)).await
}

#[frb]
pub async fn get_active_connections() -> std::result::Result<Vec<ActiveConnection>, String> {
    run(|| engine::api::get_active_connections().map(convert_vec)).await
}

#[frb]
pub async fn close_connection(connection_id: String) -> std::result::Result<(), String> {
    run(move || engine::api::close_connection_by_id(connection_id)).await
}

#[frb]
pub async fn close_connection_by_id(id: String) -> std::result::Result<(), String> {
    run(move || engine::api::close_connection_by_id(id)).await
}

#[frb]
pub async fn close_active_connection(connection_id: String) -> std::result::Result<bool, String> {
    run(move || engine::api::close_active_connection(connection_id)).await
}

#[frb]
pub async fn close_all_connections() -> std::result::Result<(), String> {
    run(|| engine::api::close_all_connections()).await
}

#[frb]
pub async fn close_all_connections_dto() -> std::result::Result<(), String> {
    run(|| engine::api::close_all_connections_dto()).await
}

/// Counters as `(total_count, total_upload, total_download, active_count)`.
#[frb]
pub async fn get_connection_stats() -> std::result::Result<(u64, u64, u64, u64), String> {
    run(|| engine::api::get_connection_stats()).await
}

// ============== Rules & DNS ==============

#[frb]
pub async fn get_rules() -> std::result::Result<Vec<RuleDto>, String> {
    run(|| engine::api::get_rules().map(convert_vec)).await
}

#[frb]
pub async fn get_dns_config() -> std::result::Result<DnsConfigDto, String> {
    run(|| engine::api::get_dns_config().map(DnsConfigDto::from)).await
}

/// Start VeloGuard's recursive resolver front-end (RecurseX).
///
/// `listen` is a `host:port` pair; port `0` asks the OS for a free port
/// and the bound address is returned. Queries are answered by iterative
/// resolution from the root — no upstream forwarder is involved.
///
/// Calling this while an instance is already running returns the existing
/// address instead of rebinding.
#[frb]
pub async fn start_recursive_dns(listen: String) -> std::result::Result<String, String> {
    run(move || recursive_dns::start(&listen)).await
}

/// Stop the recursive resolver front-end.
#[frb]
pub async fn stop_recursive_dns() -> std::result::Result<(), String> {
    run(|| recursive_dns::stop()).await
}

#[frb]
pub async fn get_recursive_dns_status() -> std::result::Result<RecursiveDnsStatus, String> {
    run(|| Ok::<RecursiveDnsStatus, String>(recursive_dns::status())).await
}

// ============== Logs & diagnostics ==============

#[frb]
pub async fn get_logs(lines: Option<u32>) -> std::result::Result<Vec<String>, String> {
    run(move || engine::api::get_logs(lines)).await
}

#[frb]
pub async fn set_log_level(level: String) -> std::result::Result<(), String> {
    let parsed = crate::logging::parse_level(&level)?;
    run(move || crate::logging::set_level(parsed)).await
}

#[frb]
pub async fn get_system_info() -> std::result::Result<SystemInfo, String> {
    run(|| engine::api::get_system_info().map(SystemInfo::from)).await
}

#[frb]
pub async fn get_version() -> String {
    run(|| Ok::<String, String>(engine::api::get_version()))
        .await
        .unwrap_or_default()
}

#[frb]
pub async fn get_build_info() -> String {
    run(|| Ok::<String, String>(engine::api::get_build_info()))
        .await
        .unwrap_or_default()
}

// ============== TUN ==============

#[frb]
pub async fn start_tun_mode(
    tun_name: String,
    tun_address: String,
    tun_netmask: String,
) -> std::result::Result<(), String> {
    run(move || engine::api::start_tun_mode(tun_name, tun_address, tun_netmask)).await
}

#[frb]
pub async fn stop_tun_mode() -> std::result::Result<(), String> {
    run(|| engine::api::stop_tun_mode()).await
}

#[frb]
pub async fn enable_tun_mode() -> std::result::Result<TunStatus, String> {
    run(|| engine::api::enable_tun_mode().map(TunStatus::from)).await
}

#[frb]
pub async fn enable_tun_mode_with_mode(mode: String) -> std::result::Result<TunStatus, String> {
    run(move || engine::api::enable_tun_mode_with_mode(mode).map(TunStatus::from)).await
}

#[frb]
pub async fn disable_tun_mode() -> std::result::Result<TunStatus, String> {
    run(|| engine::api::disable_tun_mode().map(TunStatus::from)).await
}

#[frb]
pub async fn get_tun_status() -> std::result::Result<TunStatus, String> {
    run(|| engine::api::get_tun_status().map(TunStatus::from)).await
}

#[frb]
pub async fn set_vpn_fd(fd: i32) {
    let _ = run(move || {
        engine::api::set_vpn_fd(fd);
        Ok::<(), String>(())
    })
    .await;
}

#[frb]
pub async fn clear_vpn_fd() {
    let _ = run(|| {
        engine::api::clear_vpn_fd();
        Ok::<(), String>(())
    })
    .await;
}

#[frb]
pub async fn set_protect_socket_callback_enabled(enabled: bool) {
    let _ = run(move || {
        engine::api::set_protect_socket_callback_enabled(enabled);
        Ok::<(), String>(())
    })
    .await;
}

#[frb]
pub async fn is_wintun_available() -> bool {
    run(|| Ok::<bool, String>(engine::api::is_wintun_available()))
        .await
        .unwrap_or(false)
}

#[frb]
pub async fn get_wintun_dll_path() -> Option<String> {
    run(|| Ok::<Option<String>, String>(engine::api::get_wintun_dll_path()))
        .await
        .unwrap_or(None)
}

#[frb]
pub async fn ensure_wintun_dll() -> std::result::Result<String, String> {
    run(|| engine::api::ensure_wintun_dll()).await
}

#[frb]
pub async fn enable_uwp_loopback() -> std::result::Result<bool, String> {
    run(|| engine::api::enable_uwp_loopback()).await
}

#[frb]
pub async fn open_uwp_loopback_utility() -> std::result::Result<bool, String> {
    run(|| engine::api::open_uwp_loopback_utility()).await
}

// ============== Platform proxy mode ==============

#[frb]
pub async fn set_windows_proxy_mode(mode: String) -> std::result::Result<bool, String> {
    run(move || engine::api::set_windows_proxy_mode(mode)).await
}

#[frb]
pub async fn get_windows_proxy_mode_str() -> String {
    run(|| Ok::<String, String>(engine::api::get_windows_proxy_mode_str()))
        .await
        .unwrap_or_default()
}

/// Windows TUN counters as `(packets_received, packets_sent, bytes_received,
/// bytes_sent, tcp_connections, udp_sessions)`.
#[frb]
pub async fn get_windows_tun_stats() -> std::result::Result<(u64, u64, u64, u64, u64, u64), String>
{
    run(|| {
        engine::api::get_windows_tun_stats().map(
            |(packets_received, packets_sent, bytes_received, bytes_sent, tcp, udp)| {
                (
                    packets_received,
                    packets_sent,
                    bytes_received,
                    bytes_sent,
                    tcp as u64,
                    udp as u64,
                )
            },
        )
    })
    .await
}

#[frb]
pub async fn set_android_vpn_fd(fd: i32) {
    let _ = run(move || {
        engine::api::set_android_vpn_fd(fd);
        Ok::<(), String>(())
    })
    .await;
}

#[frb]
pub async fn get_android_vpn_fd() -> i32 {
    run(|| Ok::<i32, String>(engine::api::get_android_vpn_fd()))
        .await
        .unwrap_or(-1)
}

#[frb]
pub async fn clear_android_vpn_fd() {
    let _ = run(|| {
        engine::api::clear_android_vpn_fd();
        Ok::<(), String>(())
    })
    .await;
}

#[frb]
pub async fn set_android_proxy_mode(mode: String) {
    let _ = run(move || {
        engine::api::set_android_proxy_mode(mode);
        Ok::<(), String>(())
    })
    .await;
}

#[frb]
pub async fn get_android_proxy_mode() -> String {
    run(|| Ok::<String, String>(engine::api::get_android_proxy_mode()))
        .await
        .unwrap_or_default()
}

#[frb]
pub async fn start_android_vpn() -> std::result::Result<bool, String> {
    run(|| engine::api::start_android_vpn()).await
}

#[frb]
pub async fn stop_android_vpn() -> std::result::Result<bool, String> {
    run(|| engine::api::stop_android_vpn()).await
}
