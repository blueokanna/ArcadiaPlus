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
use jni::Outcome;
use jni::objects::JObject;
use jni::objects::JString;
use jni::sys::{jboolean, jint};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Called by `ArcadiaPlusVpnService` when the service starts.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blueokanna_arcadiaplus_ArcadiaPlusVpnService_nativeInitRustBridge<
    'local,
>(
    env: EnvUnowned<'local>,
    vpn_service: JObject<'local>,
) -> jboolean {
    corduit::android_jni::Java_com_blueokanna_corduit_CorduitVpnService_nativeInitRustBridge(
        env,
        vpn_service,
    );
    corduit::android_jni::is_jni_initialized().into()
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
        crate::vpn_resume::disarm();
        let _ = corduit::api::stop_corduit();
        let _ = crate::recursive_dns::stop();
    });
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blueokanna_arcadiaplus_ArcadiaPlusVpnService_nativeForgetSession(
    _env: EnvUnowned<'_>,
    _service: JObject<'_>,
) {
    let _ = catch_unwind(crate::vpn_resume::disarm);
}

fn session_path(mut env: EnvUnowned<'_>, path: JString<'_>, restore: bool) -> jboolean {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        env.with_env(|env| {
            let path = path.try_to_string(env)?;
            crate::api::init_app();
            let result = if restore {
                crate::vpn_resume::restore(std::path::Path::new(&path))
            } else {
                crate::vpn_resume::arm(std::path::Path::new(&path))
            };
            if let Err(error) = &result {
                tracing::error!("VPN restart state failed: {error}");
            }
            Ok::<bool, jni::errors::Error>(result.is_ok())
        })
        .into_outcome()
    }));
    matches!(outcome, Ok(Outcome::Ok(true))).into()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blueokanna_arcadiaplus_ArcadiaPlusVpnService_nativeSaveSession(
    env: EnvUnowned<'_>,
    _service: JObject<'_>,
    path: JString<'_>,
) -> jboolean {
    session_path(env, path, false)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blueokanna_arcadiaplus_ArcadiaPlusVpnService_nativeRestoreSession(
    env: EnvUnowned<'_>,
    _service: JObject<'_>,
    path: JString<'_>,
) -> jboolean {
    session_path(env, path, true)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_blueokanna_arcadiaplus_ArcadiaPlusVpnService_nativeResumePackets(
    _env: EnvUnowned<'_>,
    _service: JObject<'_>,
    fd: jint,
) -> jboolean {
    catch_unwind(|| {
        corduit::api::set_android_vpn_fd(fd);
        let mode = corduit::api::get_android_proxy_mode();
        corduit::api::set_android_proxy_mode(mode);
        corduit::api::start_android_vpn().unwrap_or(false)
    })
    .unwrap_or(false)
    .into()
}
