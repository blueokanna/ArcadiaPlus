//! VeloGuard Network Stack
//!
//! A userspace TCP/IP stack for TUN-based transparent proxying.
//!
//! This crate provides:
//! - TUN device management (cross-platform, using wintun on Windows)
//! - TCP connection handling with NAT
//! - UDP session handling with NAT
//! - IP packet parsing and generation using smoltcp
//! - DNS resolution with DoH/DoT support (via the `dns` layer)
//! - Fake-IP mode for transparent proxying
//! - SolidTCP: High-performance user-space TCP/IP stack (merged from veloguard-solidtcp)
//!
//! # Platform Requirements
//!
//! ## Windows
//! Requires `wintun.dll` in the executable directory.
//! The library will attempt to download it automatically if not present.
//! Manual download: https://www.wintun.net/
//!
//! ## Linux
//! Requires CAP_NET_ADMIN capability or root privileges.
//!
//! ## macOS
//! Requires root privileges.
//!
//! ## Android
//! Requires VpnService permission.
//!
//! # Example
//!
//! ```rust,no_run
//! use rust_lib_veloguard::netstack::TunPacketProcessor;
//! use std::net::SocketAddr;
//!
//! async fn run(proxy: SocketAddr) -> Result<(), Box<dyn std::error::Error>> {
//!     // The platform bridge owns the TUN device (wintun on Windows,
//!     // VpnService on Android) and hands raw IP packets to the processor.
//!     let (tun_tx, tun_rx) = tokio::sync::mpsc::channel(128);
//!     let processor = TunPacketProcessor::new_with_proxy_addr(proxy, 1500, tun_tx);
//!
//!     // Drive packets in from the device and drain outbound ones back out.
//!     processor.process_packet(b"<raw ip packet>").await?;
//!     let stats = processor.traffic_stats();
//!     println!("{} packets in, {} out", stats.packets_received, stats.packets_sent);
//!     let _ = tun_rx;
//!
//!     Ok(())
//! }
//! ```

#[cfg(target_os = "android")]
pub mod android_vpn;
pub mod error;
pub mod route;
pub mod solidtcp;
pub mod tun;
pub mod vpn;
#[cfg(windows)]
pub mod windows_route;
#[cfg(windows)]
pub mod windows_vpn;
#[cfg(windows)]
pub mod wintun_embed;

// Re-exports
pub use error::{NetStackError, Result};
pub use route::RouteManager;
pub use tun::{TunConfig, TunDevice};
pub use vpn::{TunPacketProcessor, TunTrafficStats};

// Re-export DNS types so netstack callers have a single import point
pub use crate::dns::{
    CacheStatistics,
    DnsCache,
    // Client
    DnsClient,
    DnsConfig,
    DnsError,
    // Core types
    DnsManager,
    DnsManagerState,
    DnsProtocol,
    DnsResolver,
    DnsServer,
    // DoH/DoT
    DohClient,
    DohClientConfig,
    DohMethod,
    DohResolver,
    DotClient,
    DotClientConfig,
    DotResolver,
    FakeIpEntry,
    // Fake-IP
    FakeIpPool,
    FallbackFilter,
    // Other
    HostsFile,
    RecordType,
    Result as DnsResult,
    // Config
    UpstreamConfig,
    UpstreamProtocol,
};

// Android-specific exports
#[cfg(target_os = "android")]
pub use tun::{
    ANDROID_PROXY_MODE, ANDROID_VPN_FD, clear_android_vpn_fd, get_android_proxy_mode,
    get_android_vpn_fd, set_android_proxy_mode, set_android_vpn_fd,
};

#[cfg(target_os = "android")]
pub use android_vpn::{AndroidVpnProcessor, VpnTrafficStats};

#[cfg(target_os = "android")]
pub use solidtcp::{
    clear_protect_callback, has_protect_callback, protect_socket, set_protect_callback,
};

// Windows-specific exports
#[cfg(windows)]
pub use windows_vpn::{
    WindowsVpnProcessor, WindowsVpnTrafficStats, get_windows_proxy_mode, set_windows_proxy_mode,
};

#[cfg(windows)]
pub use windows_route::{WindowsRouteManager, flush_dns_cache, set_tun_dns};

#[cfg(windows)]
pub fn check_wintun_available() -> bool {
    wintun_embed::is_wintun_available()
}

/// Check if wintun.dll is available (non-Windows)
#[cfg(not(windows))]
pub fn check_wintun_available() -> bool {
    true // Not needed on non-Windows platforms
}

/// Get the path where wintun.dll should be placed
#[cfg(windows)]
pub fn get_wintun_path() -> Option<std::path::PathBuf> {
    wintun_embed::get_wintun_dll_path().ok()
}

/// Get the path where wintun.dll should be placed (non-Windows)
#[cfg(not(windows))]
pub fn get_wintun_path() -> Option<std::path::PathBuf> {
    None
}

/// Ensure wintun.dll is available, downloading if necessary (Windows only)
#[cfg(windows)]
pub async fn ensure_wintun() -> Result<std::path::PathBuf> {
    // First try to use existing or embedded
    if let Ok(path) = wintun_embed::ensure_wintun_available() {
        return Ok(path);
    }

    // Try to download
    wintun_embed::download_wintun_dll().await
}

/// Ensure wintun.dll is available (non-Windows - always succeeds)
#[cfg(not(windows))]
pub async fn ensure_wintun() -> Result<std::path::PathBuf> {
    Ok(std::path::PathBuf::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tun_config_default() {
        let config = TunConfig::default();
        assert_eq!(config.name, "VeloGuard");
        assert_eq!(config.address, std::net::Ipv4Addr::new(198, 18, 0, 1));
        assert_eq!(config.mtu, 1500);
    }
}
