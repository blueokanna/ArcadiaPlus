//! Tracing setup owned by the bridge.
//!
//! corduit installs its subscriber behind a `Once` and its `set_log_level`
//! only validates the request, so how much gets logged can never change after
//! startup. The bridge therefore installs the subscriber itself: a reloadable
//! filter, a layer that mirrors every event into corduit's log buffer (the one
//! `get_logs` reads), and — on Android — logcat. That makes the log level in
//! the UI an actual control instead of a no-op.

use std::sync::OnceLock;

use tracing::Level;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::registry::Registry;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{reload, EnvFilter, Layer};

/// Verbose third-party stacks that would drown the user-facing log panel.
const NOISY_TARGETS: &[&str] = &[
    "hyper",
    "mio",
    "h2",
    "want",
    "tower",
    "rustls",
    "courierust",
    "reqwest",
    "tokio",
];

static LEVEL: OnceLock<reload::Handle<EnvFilter, Registry>> = OnceLock::new();

/// Installs the subscriber. Idempotent, and a no-op once a subscriber exists.
pub fn init(level: Level) -> Result<(), String> {
    if LEVEL.get().is_some() {
        return Ok(());
    }

    let (filter_layer, handle) = reload::Layer::<EnvFilter, Registry>::new(build_filter(level));
    let registry = tracing_subscriber::registry()
        .with(filter_layer)
        .with(EngineLogLayer);

    #[cfg(target_os = "android")]
    {
        let android_layer =
            tracing_android::layer("VeloGuard").map_err(|e| format!("logcat layer: {e}"))?;
        registry
            .with(android_layer)
            .try_init()
            .map_err(|e| format!("cannot install the subscriber: {e}"))?;
    }

    #[cfg(not(target_os = "android"))]
    {
        registry
            .try_init()
            .map_err(|e| format!("cannot install the subscriber: {e}"))?;
    }

    let _ = LEVEL.set(handle);
    Ok(())
}

/// Applies a new level to the running subscriber.
pub fn set_level(level: Level) -> Result<(), String> {
    match LEVEL.get() {
        Some(handle) => handle
            .reload(build_filter(level))
            .map_err(|e| format!("cannot apply the log level: {e}")),
        None => Err("logging has not been initialised".to_string()),
    }
}

/// Parses the level names the UI sends. Unknown names are rejected rather
/// than silently mapped onto something else.
pub fn parse_level(value: &str) -> Result<Level, String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "trace" => Ok(Level::TRACE),
        "debug" => Ok(Level::DEBUG),
        "info" => Ok(Level::INFO),
        "warn" | "warning" => Ok(Level::WARN),
        "error" => Ok(Level::ERROR),
        "silent" => Ok(Level::ERROR),
        unsupported => Err(format!("unsupported log level '{unsupported}'")),
    }
}

/// The engine logs at the requested level; everything else stays at `warn` so
/// dependency chatter cannot bury it. `RUST_LOG` still wins when set.
fn build_filter(level: Level) -> EnvFilter {
    EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new(format!("warn,corduit={level},rust_lib_veloguard={level}"))
    })
}

fn is_noisy(target: &str) -> bool {
    target.is_empty() || NOISY_TARGETS.iter().any(|noisy| target.starts_with(noisy))
}

/// Mirrors tracing events into corduit's log buffer, which is what the log
/// panel reads through `get_logs`.
struct EngineLogLayer;

impl<S: tracing::Subscriber> Layer<S> for EngineLogLayer {
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        let metadata = event.metadata();
        if is_noisy(metadata.target()) {
            return;
        }

        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);

        corduit::engine::logging::add_log(format!(
            "[{}] [{}] {}",
            corduit::common::clock::now_utc_timestamp(),
            metadata.level(),
            visitor.message
        ));
    }
}

#[derive(Default)]
struct MessageVisitor {
    message: String,
}

impl tracing::field::Visit for MessageVisitor {
    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" || self.message.is_empty() {
            self.message = value.to_string();
        } else {
            self.message
                .push_str(&format!(" {}={}", field.name(), value));
        }
    }

    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" || self.message.is_empty() {
            self.message = format!("{value:?}");
        } else {
            self.message
                .push_str(&format!(" {}={:?}", field.name(), value));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_names_match_the_ui() {
        assert_eq!(parse_level("INFO").unwrap(), Level::INFO);
        assert_eq!(parse_level(" warning ").unwrap(), Level::WARN);
        assert_eq!(parse_level("silent").unwrap(), Level::ERROR);
        assert!(parse_level("verbose").is_err());
    }

    #[test]
    fn dependency_chatter_is_filtered() {
        assert!(is_noisy("hyper::proto"));
        assert!(is_noisy("courierust_tls"));
        assert!(!is_noisy("corduit::engine"));
        assert!(!is_noisy("rust_lib_veloguard"));
    }
}
