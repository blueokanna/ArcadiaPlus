//! Android `VpnService` JNI entry points.
//!
//! Kotlin loads `librust_lib_arcadiaplus.so` and calls
//! `ArcadiaPlusVpnService.nativeInitRustBridge()` / `nativeClearRustBridge()`;
//! both symbols are bound to that class name and library stem, so they stay
//! here.
//!
//! Everything behind them — pinning the `JavaVM` and the service reference,
//! installing the netstack `protect(fd)` callback, and the readiness checks
//! `start_android_vpn` performs before packet processing starts — belongs to
//! corduit. Forwarding instead of mirroring that state keeps exactly one JNI
//! state machine in the process, and it is the one the engine can see.

#![cfg(target_os = "android")]

use jni::EnvUnowned;
use jni::objects::JObject;

/// Called by `ArcadiaPlusVpnService` when the service starts.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blueokanna_arcadiaplus_ArcadiaPlusVpnService_nativeInitRustBridge<
    'local,
>(
    env: EnvUnowned<'local>,
    vpn_service: JObject<'local>,
) {
    corduit::android_jni::Java_com_blueokanna_corduit_CorduitVpnService_nativeInitRustBridge(
        env,
        vpn_service,
    );
}

/// Called by `ArcadiaPlusVpnService` when the service stops.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blueokanna_arcadiaplus_ArcadiaPlusVpnService_nativeClearRustBridge<
    'local,
>(
    env: EnvUnowned<'local>,
    vpn_service: JObject<'local>,
) {
    let _ = std::panic::catch_unwind(|| {
        let _ = corduit::api::stop_android_vpn();
    });
    corduit::android_jni::Java_com_blueokanna_corduit_CorduitVpnService_nativeClearRustBridge(
        env,
        vpn_service,
    );
}

/// Notification, tile and permission-revocation disconnects stop the proxy too.
/// A Flutter TUN-only toggle calls nativeClearRustBridge and keeps listeners up.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blueokanna_arcadiaplus_ArcadiaPlusVpnService_nativeStopProxy(
    _env: EnvUnowned<'_>,
    _service: JObject<'_>,
) {
    let _ = std::panic::catch_unwind(|| {
        let _ = corduit::api::stop_corduit();
        let _ = crate::recursive_dns::stop();
    });
}
