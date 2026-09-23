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

/// What the subscriber should let through.
///
/// `Off` is a real switch rather than a synonym for `error`: both the UI and
/// Clash profiles can ask for `silent`, and answering that with error-level
/// output would downgrade the request without saying so.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogFilter {
    Off,
    UpTo(Level),
}

/// Installs the subscriber. Idempotent, and a no-op once a subscriber exists.
pub fn init(filter: LogFilter) -> Result<(), String> {
    if LEVEL.get().is_some() {
        return Ok(());
    }

    let (filter_layer, handle) = reload::Layer::<EnvFilter, Registry>::new(build_filter(filter));
    let registry = tracing_subscriber::registry()
        .with(filter_layer)
        .with(EngineLogLayer);

    #[cfg(target_os = "android")]
    {
        let android_layer =
            tracing_android::layer("ArcadiaPlus").map_err(|e| format!("logcat layer: {e}"))?;
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

/// Applies a new filter to the running subscriber, installing one if the
/// caller changes the level before the bridge has brought tracing up.
pub fn set_level(filter: LogFilter) -> Result<(), String> {
    match LEVEL.get() {
        Some(handle) => handle
            .reload(build_filter(filter))
            .map_err(|e| format!("cannot apply the log level: {e}")),
        None => init(filter),
    }
}

/// Parses the level names the UI and profiles send. Unknown names are
/// rejected rather than silently mapped onto something else.
pub fn parse_level(value: &str) -> Result<LogFilter, String> {
    match value.trim().to_ascii_lowercase().as_str() {
        "trace" => Ok(LogFilter::UpTo(Level::TRACE)),
        "debug" => Ok(LogFilter::UpTo(Level::DEBUG)),
        "info" => Ok(LogFilter::UpTo(Level::INFO)),
        "warn" | "warning" => Ok(LogFilter::UpTo(Level::WARN)),
        "error" => Ok(LogFilter::UpTo(Level::ERROR)),
        "silent" | "off" => Ok(LogFilter::Off),
        unsupported => Err(format!("unsupported log level '{unsupported}'")),
    }
}

/// The engine logs at the requested level; everything else stays at `warn` so
/// dependency chatter cannot bury it. `RUST_LOG` still wins when set.
fn build_filter(filter: LogFilter) -> EnvFilter {
    if let Ok(from_env) = EnvFilter::try_from_default_env() {
        return from_env;
    }

    match filter {
        LogFilter::Off => EnvFilter::new("off"),
        LogFilter::UpTo(level) => EnvFilter::new(format!(
            "warn,corduit={level},rust_lib_arcadia_plus={level}"
        )),
    }
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
        assert_eq!(parse_level("INFO").unwrap(), LogFilter::UpTo(Level::INFO));
        assert_eq!(
            parse_level(" warning ").unwrap(),
            LogFilter::UpTo(Level::WARN)
        );
        assert_eq!(parse_level("silent").unwrap(), LogFilter::Off);
        assert_eq!(parse_level("OFF").unwrap(), LogFilter::Off);
        assert!(parse_level("verbose").is_err());
    }

    #[test]
    fn dependency_chatter_is_filtered() {
        assert!(is_noisy("hyper::proto"));
        assert!(is_noisy("courierust_tls"));
        assert!(!is_noisy("corduit::engine"));
        assert!(!is_noisy("rust_lib_arcadia_plus"));
    }
}
