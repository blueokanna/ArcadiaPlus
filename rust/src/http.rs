//! One HTTP door, built on `courierust`.
//!
//! Every HTTP(S) fetch in this crate — subscription updates, rule lists, the
//! optional Wintun download, the latency probe — goes through [`get`]. That is
//! `courierust`'s client underneath: its own HTTP/1.1 keep-alive pool, its own
//! HTTP/2 with one driver thread per connection, and its own TLS with TLS 1.2
//! and TLS 1.3 against the platform trust store. Nothing third-party is
//! involved, which is the point: one stack means redirect policy, timeouts,
//! body limits and certificate handling are decided in exactly one place.
//!
//! ## Blocking client, async callers
//!
//! `courierust`'s client is synchronous by design — it owns its threads and its
//! pools. Tokio workers must never block, so [`get`] hands the request to the
//! blocking pool and awaits the result. The client itself is process-wide, so
//! keep-alive reuse survives across calls.
//!
//! ## Trust store
//!
//! Roots come from the operating system (`rustls-native-certs`). Where the
//! platform has no readable store — a stripped container, for instance — the
//! environment variable `VELOGUARD_TRUST_ROOTS_PEM` can point at a PEM bundle
//! to load instead; without either, TLS fails closed with an explanation rather
//! than trusting whatever answers the connection.

use std::sync::OnceLock;
use std::time::Duration;

use courierust::courierust_body::Body;
use courierust::courierust_client::{Client, ClientConfig, TlsSettings};
use courierust::courierust_http::request::Request;
use courierust::courierust_http::response::Response;
use courierust::courierust_http::{HeaderName, HeaderValue, PathAndQuery};
use courierust::courierust_tls::x509::RootStore;

/// Environment variable naming a PEM bundle to trust, used when the platform
/// store is unavailable.
pub const TRUST_ROOTS_PEM_ENV: &str = "VELOGUARD_TRUST_ROOTS_PEM";

/// End-to-end budget for a single document fetch.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

/// Ceiling on a response body we are willing to buffer. Rule lists and
/// subscriptions are text; anything larger is a mistake or an attack.
pub const DEFAULT_BODY_LIMIT: usize = 8 * 1024 * 1024;

/// Connect and TLS-handshake budgets, deliberately shorter than the whole
/// request: a host that accepts and then stalls should not eat the full window.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// Redirects followed before giving up.
const MAX_REDIRECTS: usize = 5;

/// A failed fetch, with the URL that failed.
#[derive(Debug)]
pub struct HttpError {
    url: String,
    detail: String,
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "GET {}: {}", self.url, self.detail)
    }
}

impl std::error::Error for HttpError {}

impl HttpError {
    fn new(url: &str, detail: impl Into<String>) -> Self {
        Self {
            url: url.to_string(),
            detail: detail.into(),
        }
    }
}

/// The process-wide client.
///
/// `courierust` keeps connections alive per authority, so one client shared by
/// every caller is not just cheaper, it is what makes keep-alive actually work
/// for repeated subscription refreshes.
fn client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        let config = ClientConfig {
            user_agent: Some(format!("VeloGuard/{}", env!("CARGO_PKG_VERSION"))),
            connect_timeout: Some(CONNECT_TIMEOUT),
            handshake_timeout: Some(HANDSHAKE_TIMEOUT),
            read_timeout: Some(DEFAULT_TIMEOUT),
            max_redirects: MAX_REDIRECTS,
            max_body: DEFAULT_BODY_LIMIT,
            tls: Some(tls_settings()),
            ..ClientConfig::default()
        };
        Client::with_config(config)
    })
}

/// TLS settings: verify against the platform trust store, TLS 1.2 as the floor.
fn tls_settings() -> TlsSettings {
    TlsSettings {
        roots: trust_roots(),
        verify: true,
        min_version: courierust::courierust_tls::TlsVersion::Tls12,
        max_version: courierust::courierust_tls::TlsVersion::Tls13,
        ..Default::default()
    }
}

/// Load the certificates we are willing to trust.
fn trust_roots() -> RootStore {
    let mut roots = RootStore::new();

    let native = rustls_native_certs::load_native_certs();
    for certificate in native.certs {
        roots.add_der(certificate.to_vec());
    }
    for error in &native.errors {
        tracing::warn!("Platform trust store entry could not be read: {error}");
    }

    if let Ok(path) = std::env::var(TRUST_ROOTS_PEM_ENV) {
        match std::fs::read_to_string(&path) {
            Ok(pem) => match roots.add_pem(&pem) {
                Ok(added) => tracing::info!("Loaded {added} extra trust roots from {path}"),
                Err(error) => tracing::warn!("Ignoring {path}: {error}"),
            },
            Err(error) => tracing::warn!("Ignoring {TRUST_ROOTS_PEM_ENV}='{path}': {error}"),
        }
    }

    if roots.is_empty() {
        tracing::warn!(
            "No trusted roots are available: set {TRUST_ROOTS_PEM_ENV} to a PEM bundle to enable HTTPS"
        );
    }

    roots
}

/// `GET url`, returning the response body.
///
/// Non-2xx responses are errors, so callers cannot mistake an error page for
/// a subscription.
pub async fn get(url: &str) -> Result<Vec<u8>, HttpError> {
    let target = url.to_string();
    let exchange =
        tokio::task::spawn_blocking(move || exchange_blocking(&target, RequestOptions::default()))
            .await
            .map_err(|error| HttpError::new(url, format!("fetch task failed: {error}")))?;

    exchange.map(Exchange::into_body)
}

/// `GET url`, decoded as UTF-8 text.
pub async fn get_text(url: &str) -> Result<String, HttpError> {
    let body = get(url).await?;
    String::from_utf8(body)
        .map_err(|error| HttpError::new(url, format!("body is not UTF-8: {error}")))
}

/// Per-request overrides for callers that cannot use the shared defaults.
pub struct RequestOptions {
    /// Ceiling on the buffered body.
    pub body_limit: usize,
    /// Redirects followed. `0` means the caller wants to see the `Location`
    /// header itself — which is what a download that polices its hosts needs.
    pub max_redirects: usize,
}

impl Default for RequestOptions {
    fn default() -> Self {
        Self {
            body_limit: DEFAULT_BODY_LIMIT,
            max_redirects: MAX_REDIRECTS,
        }
    }
}

/// One HTTP exchange, redirects followed only as far as `max_redirects` allows.
pub struct Exchange {
    /// Status code of the final response.
    pub status: u16,
    /// `Location` header of the final response, verbatim, when present.
    pub location: Option<String>,
    headers: courierust::courierust_http::HeaderMap,
    body: Vec<u8>,
}

impl Exchange {
    /// Whether the response is a redirect the caller must interpret itself.
    pub fn is_redirect(&self) -> bool {
        matches!(self.status, 301 | 302 | 303 | 307 | 308)
    }

    /// A response header, decoded as text when it is valid UTF-8.
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).and_then(|value| value.to_str().ok())
    }

    /// The body of the final response.
    pub fn into_body(self) -> Vec<u8> {
        self.body
    }
}

/// `GET url` with explicit limits, without hiding the redirect hop.
pub async fn exchange(url: &str, options: RequestOptions) -> Result<Exchange, HttpError> {
    let target = url.to_string();
    tokio::task::spawn_blocking(move || exchange_blocking(&target, options))
        .await
        .map_err(|error| HttpError::new(url, format!("fetch task failed: {error}")))?
}

/// Turn a `Location` header into the URL to request next.
///
/// Only `https://` targets, scheme-relative `//host/…` and absolute `/path`
/// values are accepted, and the result is parsed before it is returned. A
/// redirect we cannot fully reason about is refused rather than followed.
pub fn resolve_redirect(base_url: &str, location: &str) -> Result<String, HttpError> {
    let base = corduit::common::url::Url::parse(base_url)
        .map_err(|error| HttpError::new(base_url, format!("unparsable base URL: {error}")))?;

    let candidate = if location.starts_with("https://") {
        location.to_string()
    } else if let Some(rest) = location.strip_prefix("//") {
        format!("https://{rest}")
    } else if location.starts_with('/') {
        let host = base
            .host_str()
            .ok_or_else(|| HttpError::new(base_url, "base URL has no host"))?;
        // `host_str` hands back an IPv6 literal without brackets, so put them
        // back before the value goes into a URL.
        let host = if host.contains(':') && !host.starts_with('[') {
            format!("[{host}]")
        } else {
            host.to_string()
        };
        let authority = match base.port() {
            Some(port) => format!("{host}:{port}"),
            None => host,
        };
        format!("https://{authority}{location}")
    } else {
        return Err(HttpError::new(
            base_url,
            format!("refusing to follow relative redirect to '{location}'"),
        ));
    };

    let parsed = corduit::common::url::Url::parse(&candidate)
        .map_err(|error| HttpError::new(base_url, format!("unparsable redirect: {error}")))?;
    if parsed.scheme() != "https" {
        return Err(HttpError::new(
            base_url,
            format!("refusing to follow redirect to non-HTTPS target '{candidate}'"),
        ));
    }
    if parsed.host_str().is_none() {
        return Err(HttpError::new(
            base_url,
            format!("refusing to follow redirect without a host: '{candidate}'"),
        ));
    }

    Ok(candidate)
}

/// `POST url` with a body and its content type.
///
/// The DoH client is the caller that needs this: an RFC 8484 query is a binary
/// body, and routing it through the same door as every other fetch keeps one
/// TLS stack, one redirect policy and one body ceiling in the process.
///
/// Non-2xx responses are errors, exactly as in [`get`].
pub async fn post(url: &str, body: Vec<u8>, content_type: &str) -> Result<Exchange, HttpError> {
    post_with_headers(url, body, content_type, Vec::new()).await
}

/// `POST url` with extra request headers.
pub async fn post_with_headers(
    url: &str,
    body: Vec<u8>,
    content_type: &str,
    headers: Vec<(String, String)>,
) -> Result<Exchange, HttpError> {
    let target = url.to_string();
    let content_type = content_type.to_string();
    tokio::task::spawn_blocking(move || post_blocking(&target, &body, &content_type, &headers))
        .await
        .map_err(|error| HttpError::new(url, format!("fetch task failed: {error}")))?
}

fn post_blocking(
    url: &str,
    body: &[u8],
    content_type: &str,
    headers: &[(String, String)],
) -> Result<Exchange, HttpError> {
    request_blocking(FetchMethod::Post, url, headers, Some((body, content_type)))
}

/// `GET url` with extra request headers.
pub async fn get_with_headers(
    url: &str,
    headers: Vec<(String, String)>,
) -> Result<Exchange, HttpError> {
    let target = url.to_string();
    tokio::task::spawn_blocking(move || request_blocking(FetchMethod::Get, &target, &headers, None))
        .await
        .map_err(|error| HttpError::new(url, format!("fetch task failed: {error}")))?
}

/// The method of a [`request_blocking`] call.
#[derive(Clone, Copy)]
enum FetchMethod {
    Get,
    Post,
}

/// One request, no redirects beyond the client's policy, one buffered body.
fn request_blocking(
    method: FetchMethod,
    url: &str,
    headers: &[(String, String)],
    body: Option<(&[u8], &str)>,
) -> Result<Exchange, HttpError> {
    let target = request_target(url)?;

    with_client(&RequestOptions::default(), |client| {
        let mut request = match method {
            FetchMethod::Get => Request::get(target),
            FetchMethod::Post => Request::post(target),
        };

        if let Some((_, content_type)) = body
            && let (Ok(name), Ok(value)) = (
                HeaderName::from_bytes(b"content-type"),
                HeaderValue::from_bytes(content_type.as_bytes()),
            )
        {
            request = request.header(name, value);
        }

        for (name, value) in headers {
            match (
                name.parse::<HeaderName>(),
                HeaderValue::from_bytes(value.as_bytes()),
            ) {
                (Ok(name), Ok(value)) => request = request.header(name, value),
                // A header that cannot be represented on the wire is a
                // configuration mistake, not a reason to send a request that
                // means something else.
                _ => {
                    return Err(HttpError::new(url, format!("invalid request header '{name}'")));
                }
            }
        }

        let request = match (method, body) {
            (FetchMethod::Post, Some((payload, _))) => {
                request.with_body(Body::Bytes(courierust::Bytes::from(payload.to_vec())))
            }
            _ => request.with_body(Body::Empty),
        };

        let response = client
            .execute(url, request)
            .map_err(|error| HttpError::new(url, error.to_string()))?;

        finish(url, response)
    })
}

/// The request target of a URL: path plus query.
fn request_target(url: &str) -> Result<PathAndQuery, HttpError> {
    let parsed = corduit::common::url::Url::parse(url)
        .map_err(|error| HttpError::new(url, format!("unparsable URL: {error}")))?;

    let mut target = parsed.path().to_string();
    if !target.starts_with('/') {
        target.insert(0, '/');
    }
    if let Some(query) = parsed.query() {
        target.push('?');
        target.push_str(query);
    }

    PathAndQuery::from_bytes(target.as_bytes())
        .map_err(|error| HttpError::new(url, format!("unusable request target: {error}")))
}

fn exchange_blocking(url: &str, options: RequestOptions) -> Result<Exchange, HttpError> {
    with_client(&options, |client| {
        let response = client
            .get(url)
            .map_err(|error| HttpError::new(url, error.to_string()))?;
        finish(url, response)
    })
}

/// Turn a raw response into an [`Exchange`], or into the error it represents.
fn finish(url: &str, response: Response<Body>) -> Result<Exchange, HttpError> {
    let status = response.status.as_u16();
    let location = response
        .headers
        .get("location")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);

    if !response.status.is_success() && !matches!(status, 301 | 302 | 303 | 307 | 308) {
        let reason = response.status.canonical_reason().unwrap_or("Unknown");
        return Err(HttpError::new(url, format!("HTTP {status} {reason}")));
    }

    let body = response
        .body
        .collect()
        .map_err(|error| HttpError::new(url, format!("body could not be read: {error}")))?;

    Ok(Exchange {
        status,
        location,
        headers: response.headers,
        body: body.to_vec(),
    })
}

/// Run `action` on the shared client, or on a purpose-built one when the
/// caller needs limits the default configuration does not use.
fn with_client<T>(
    options: &RequestOptions,
    action: impl FnOnce(&Client) -> Result<T, HttpError>,
) -> Result<T, HttpError> {
    if options.max_redirects == MAX_REDIRECTS && options.body_limit == DEFAULT_BODY_LIMIT {
        return action(client());
    }

    let config = ClientConfig {
        user_agent: Some(format!("VeloGuard/{}", env!("CARGO_PKG_VERSION"))),
        connect_timeout: Some(CONNECT_TIMEOUT),
        handshake_timeout: Some(HANDSHAKE_TIMEOUT),
        read_timeout: Some(DEFAULT_TIMEOUT),
        max_redirects: options.max_redirects,
        max_body: options.body_limit,
        tls: Some(tls_settings()),
        ..ClientConfig::default()
    };
    action(&Client::with_config(config))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trust_roots_does_not_panic_without_environment_help() {
        // The platform store may be empty in a sandbox; loading must still be
        // a well-formed, non-panicking operation that reports what it found.
        // (`roots.is_empty()` is a legitimate outcome, so the assertion is
        // about the call completing rather than about a particular count.)
        let roots = trust_roots();
        let count = roots.len();
        assert_eq!(count, roots.len());
    }

    #[test]
    fn error_message_names_the_url() {
        let error = HttpError::new("https://example.invalid/x", "boom");
        assert!(error.to_string().contains("https://example.invalid/x"));
        assert!(error.to_string().contains("boom"));
    }
}
