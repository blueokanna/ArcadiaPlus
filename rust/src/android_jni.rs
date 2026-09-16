//! Android `VpnService` JNI entry points.
//!
//! Kotlin loads `librust_lib_veloguard.so` and calls
//! `VeloGuardVpnService.nativeInitRustBridge()` / `nativeClearRustBridge()`;
//! both symbols are bound to that class name and library stem, so they stay
//! here.
//!
//! Everything behind them — pinning the `JavaVM` and the service reference,
//! installing the netstack `protect(fd)` callback, and the readiness checks
//! `start_android_vpn` performs before packet processing starts — belongs to
//! corduit. Forwarding instead of mirroring that state keeps exactly one JNI
//! state machine in the process, and it is the one the engine can see.

#![cfg(target_os = "android")]

use jni::objects::JObject;
use jni::JNIEnv;

/// Called by `VeloGuardVpnService` when the service starts.
#[no_mangle]
pub extern "system" fn Java_com_blueokanna_veloguard_VeloGuardVpnService_nativeInitRustBridge<
    'local,
>(
    env: JNIEnv<'local>,
    vpn_service: JObject<'local>,
) {
    corduit::android_jni::Java_com_blueokanna_corduit_CorduitVpnService_nativeInitRustBridge(
        env,
        vpn_service,
    );
}

/// Called by `VeloGuardVpnService` when the service stops.
#[no_mangle]
pub extern "system" fn Java_com_blueokanna_veloguard_VeloGuardVpnService_nativeClearRustBridge<
    'local,
>(
    env: JNIEnv<'local>,
    vpn_service: JObject<'local>,
) {
    corduit::android_jni::Java_com_blueokanna_corduit_CorduitVpnService_nativeClearRustBridge(
        env,
        vpn_service,
    );
}
