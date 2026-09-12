use tracing_subscriber::layer::Context;

pub(crate) struct FlutterLogLayer;

impl<S> tracing_subscriber::Layer<S> for FlutterLogLayer
where
    S: tracing::Subscriber,
{
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        let metadata = event.metadata();
        let level = metadata.level();
        let target = metadata.target();

        // Skip internal logs from the runtime and the TLS provider; their
        // targets are noisy at debug level and never describe this engine.
        if target.starts_with("tokio") || target.starts_with("rustls") {
            return;
        }

        let mut visitor = LogVisitor::default();
        event.record(&mut visitor);

        // tzcraft owns the clock: `Zoned::now()` reads the system zone once per
        // event and `civil()` gives us the wall-clock fields for the log line.
        let timestamp = tzcraft::Zoned::now()
            .and_then(|zoned| zoned.civil())
            .map(|civil| civil.to_iso())
            .unwrap_or_else(|_| "clock-unavailable".to_string());
        let log_line = format!("[{}] [{}] {}", timestamp, level, visitor.message);

        crate::core::logging::add_log(log_line);
    }
}

#[derive(Default)]
pub(crate) struct LogVisitor {
    message: String,
}

impl tracing::field::Visit for LogVisitor {
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
            self.message = format!("{:?}", value);
        } else {
            self.message
                .push_str(&format!(" {}={:?}", field.name(), value));
        }
    }
}
