//! ArcadiaPlus ⇄ [corduit] bridge for Flutter.
//!
//! The proxy engine itself lives in [`corduit`]: everything this crate
//! does is FFI plumbing — flattening corduit's synchronous API into the
//! async surface `flutter_rust_bridge` expects, mirroring corduit's DTOs
//! as bridge-local types, and hosting the pieces that are genuinely
//! ArcadiaPlus-specific (the Android `VpnService` JNI hooks and the
//! RecurseX recursive DNS front-end).
//!
//! Two rules keep this layer honest:
//!
//! * **No engine state lives here.** Sessions, TUN devices and packet
//!   tasks are owned by corduit; the bridge never caches them.
//! * **No blocking call runs on the async executor.** Every corduit call
//!   is dispatched through [`api::run`], which hands the work to a
//!   blocking worker thread.
//!
//! [corduit]: https://crates.io/crates/corduit

#![allow(unexpected_cfgs)]

mod frb_generated;
mod logging;

#[cfg(target_os = "android")]
pub mod android_jni;
pub mod api;
pub mod recursive_dns;
mod types;

pub use api::*;
pub use types::*;
