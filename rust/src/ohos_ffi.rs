//! Native entry points for the HarmonyOS VPN extension process.
//!
//! The VPN data path runs where the tunnel fd is born: inside the
//! `VpnExtensionAbility` process. That process hosts no Flutter engine, so the
//! FRB surface is not available to it — these `extern "C"` functions are the
//! whole interface, wrapped by the small NAPI module under
//! `ohos/entry/src/main/cpp` that the ArkTS side imports as
//! `libarcadia_core.so`.
//!
//! The extension owns three things, and so does this module:
//!
//! * the engine itself — the same `initialize_corduit`/`start_corduit` pair the
//!   app's own process uses, fed the config the UI process wrote to the shared
//!   sandbox;
//! * the tun fd `vpnConnection.create(...)` returned;
//! * the tunnel exemption for the engine's own dials, through one of two
//!   mechanisms the ArkTS side picks between: `protectProcessNet` (API 22+),
//!   recorded here as a boolean, or the per-fd `protect` callback registered
//!   through [`arcadia_ohos_set_protect_callback`] on older devices.
//!
//! # Failure policy
//!
//! Every entry point returns `0` on success and a negative code on failure,
//! and every failure is also logged through `tracing` — a process without a UI
//! can only explain itself that way. Panics are caught at the boundary: an
//! unwind that crossed an `extern "C"` frame would abort the extension, which
//! the system reads as "the VPN app crashed" and answers by tearing the tunnel
//! down.

use std::ffi::{c_char, c_int, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};

use tracing::{error, info, warn};

/// Run `body`, converting a panic into the generic failure code.
fn guarded(body: impl FnOnce() -> c_int) -> c_int {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(code) => code,
        Err(_) => {
            error!("panic escaped a HarmonyOS entry point; returning failure");
            -1
        }
    }
}

/// Read a NUL-terminated string, `None` when the pointer is null or not UTF-8.
fn read_cstr(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    // Safety: the NAPI wrapper hands over pointers into strings that live for
    // the duration of the call and are NUL-terminated by construction.
    let value = unsafe { CStr::from_ptr(pointer) };
    value.to_str().ok().map(str::to_owned)
}

/// Install a file-backed subscriber for the extension process, once.
///
/// The extension has no log panel and no console; the file inside the app
/// sandbox is the only place its engine can be debugged from, and the UI
/// process can read the same file because both run under the app's sandbox.
fn init_logging(path: &str) {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let path = std::path::PathBuf::from(path);
        let make_writer = move || -> Box<dyn std::io::Write + Send> {
            match std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
            {
                Ok(file) => Box::new(file),
                Err(_) => Box::new(std::io::sink()),
            }
        };
        let _ = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_writer(make_writer)
            .with_env_filter(tracing_subscriber::EnvFilter::new("info"))
            .try_init();
    });
}

/// Start the engine and the packet path for one VPN session.
///
/// Returns `0` when the tunnel is up; negative codes name the stage that
/// failed (`-2` arguments, `-3` config unreadable, `-4` engine init, `-5`
/// engine start, `-6` packet path) so the ArkTS side can report something
/// more useful than "failed".
///
/// # Safety
///
/// The three string pointers must be NUL-terminated UTF-8 or null;
/// `tun_fd` must be a valid descriptor owned by the calling process.
#[no_mangle]
pub extern "C" fn arcadia_ohos_start(
    config_path: *const c_char,
    geoip_path: *const c_char,
    log_path: *const c_char,
    tun_fd: c_int,
    protect_process: c_int,
) -> c_int {
    guarded(|| {
        let Some(config_path) = read_cstr(config_path) else {
            error!("arcadia_ohos_start: no config path");
            return -2;
        };
        if let Some(log_path) = read_cstr(log_path) {
            init_logging(&log_path);
        }

        let config = match std::fs::read_to_string(&config_path) {
            Ok(config) => config,
            Err(error) => {
                error!("the engine config at {config_path} is unreadable: {error}");
                return -3;
            }
        };

        match read_cstr(geoip_path) {
            Some(path) if std::path::Path::new(&path).is_file() => {
                // Same contract as the app's own process: the environment
                // variable is what corduit reads when the router builds its
                // country matcher, so it must be set before initialization.
                std::env::set_var("CORDUIT_GEOIP_DB", &path);
                info!("GeoIP database registered: {path}");
            }
            Some(path) => warn!("GeoIP database missing at {path}; GEOIP rules stay inert"),
            None => warn!("no GeoIP path was provided; GEOIP rules stay inert"),
        }

        if let Err(error) = corduit::api::initialize_corduit(config) {
            error!("engine initialization failed: {error}");
            return -4;
        }
        if let Err(error) = corduit::api::start_corduit() {
            error!("engine start failed: {error}");
            return -5;
        }

        // Both protections are cheap to record; whichever the ArkTS side
        // managed to arrange is the one that will carry the exemption.
        corduit::api::set_ohos_process_protected(protect_process != 0);
        corduit::api::set_ohos_vpn_fd(tun_fd);

        match corduit::api::start_ohos_vpn() {
            Ok(true) => {
                info!("HarmonyOS packet path started on fd {tun_fd}");
                0
            }
            Ok(false) => {
                error!("HarmonyOS packet path refused to start (see the engine log above)");
                -6
            }
            Err(error) => {
                error!("HarmonyOS packet path failed: {error}");
                -6
            }
        }
    })
}

/// Stop the packet path and the engine. Idempotent.
#[no_mangle]
pub extern "C" fn arcadia_ohos_stop() -> c_int {
    guarded(|| {
        let _ = corduit::api::stop_ohos_vpn();
        let _ = corduit::api::stop_corduit();
        info!("HarmonyOS engine stopped");
        0
    })
}

/// Register (or clear, with a null pointer) the per-fd tunnel exemption.
///
/// The callback reaches `vpnConnection.protect` through the NAPI thread-safe
/// function the wrapper installed, so it is asynchronous by construction: the
/// engine is told "treated as protected" and the ArkTS side reports its own
/// failures. Devices that offer `protectProcessNet` do not need this at all.
///
/// # Safety
///
/// `callback` must stay callable for as long as the engine runs; the NAPI
/// wrapper owns that lifetime.
#[no_mangle]
pub extern "C" fn arcadia_ohos_set_protect_callback(
    callback: Option<extern "C" fn(c_int) -> c_int>,
) -> c_int {
    guarded(|| {
        match callback {
            Some(callback) => {
                corduit::netstack::set_protect_callback(move |fd| callback(fd) != 0);
                0
            }
            None => {
                corduit::netstack::clear_protect_callback();
                0
            }
        }
    })
}

/// Apply a routing mode (`rule`/`global`/`direct`) to the running engine.
///
/// # Safety
///
/// `mode` must be a NUL-terminated UTF-8 string or null.
#[no_mangle]
pub extern "C" fn arcadia_ohos_set_proxy_mode(mode: *const c_char) -> c_int {
    guarded(|| {
        let Some(mode) = read_cstr(mode) else {
            return -2;
        };
        let mode_int = match mode.to_ascii_lowercase().as_str() {
            "global" => 1,
            "direct" => 2,
            "rule" => 3,
            _ => 0,
        };
        match corduit::api::set_proxy_mode(mode_int) {
            Ok(()) => 0,
            Err(error) => {
                error!("proxy mode '{mode}' was rejected: {error}");
                -1
            }
        }
    })
}
