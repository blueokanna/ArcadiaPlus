//! The local REST API.
//!
//! A small read-mostly JSON API over the same state the engine runs on: traffic
//! counters, health, proxies, routing rules and the active configuration. It is
//! the machine-readable view of the proxy for scripts and dashboards — the Dart
//! UI talks to the FFI layer instead.
//!
//! ## Why there is no web framework here
//!
//! The framing is [`crate::protocol::h1_server`] — this crate's HTTP/1.1 core
//! over `courierust_h1`, the same core the proxy inbounds and the DoH server
//! use. Pulling in a framework for nine routes would make the dependency tree of
//! a *proxy* depend on a web stack, and would give this crate a second HTTP
//! parser to keep in sync with the one that guards the proxy ports.
//!
//! JSON encoding stays on `serde_json`: the payloads are configuration and
//! routing types whose `serde` derive is also the YAML and FFI contract, and one
//! derive feeding three formats beats three models of one truth.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

use crate::core::config::Config;
use crate::core::error::{Error, Result};
use crate::core::health_check::{HealthMonitor, HealthStatus};
use crate::core::proxy::ProxyManager;
use crate::core::traffic_counters::TrafficStatsManager;
use crate::protocol::h1_server::{H1Connection, Request, Response};

/// A management API is small by nature; these bounds say so.
const MAX_HEAD_LEN: usize = 32 * 1024;

/// Configuration updates arrive here, so the body bound is the largest
/// configuration this API will accept in one request.
const MAX_BODY_LEN: usize = 4 * 1024 * 1024;

/// API server state
#[derive(Clone)]
pub struct ApiState {
    pub proxy_manager: Arc<ProxyManager>,
    pub health_monitor: Arc<HealthMonitor>,
    pub traffic_stats: Arc<TrafficStatsManager>,
}

/// API response wrapper
#[derive(Serialize)]
struct ApiResponse<T> {
    success: bool,
    data: Option<T>,
    error: Option<String>,
}

impl<T> ApiResponse<T> {
    fn success(data: T) -> Self {
        Self {
            success: true,
            data: Some(data),
            error: None,
        }
    }

    fn error(message: String) -> Self {
        Self {
            success: false,
            data: None,
            error: Some(message),
        }
    }
}

/// Server info response
#[derive(Serialize)]
struct ServerInfo {
    version: String,
    uptime: u64,
    active_connections: usize,
}

/// Traffic stats response
#[derive(Serialize)]
struct TrafficResponse {
    upload_bytes: u64,
    download_bytes: u64,
    total_bytes: u64,
    connections: u64,
    connection_time_secs: u64,
}

/// Health status response
#[derive(Serialize)]
struct HealthResponse {
    tag: String,
    status: String,
    details: Option<String>,
}

/// Proxy info response
#[derive(Serialize)]
struct ProxyInfo {
    tag: String,
    proxy_type: String,
    server: Option<String>,
    port: Option<u16>,
    healthy: bool,
}

/// Config update request
#[derive(Deserialize)]
struct ConfigUpdateRequest {
    config: Config,
}

/// API server
pub struct ApiServer {
    state: ApiState,
    cancel_token: CancellationToken,
    running: Arc<AtomicBool>,
}

impl ApiServer {
    /// Create a new API server
    pub fn new(
        proxy_manager: Arc<ProxyManager>,
        health_monitor: Arc<HealthMonitor>,
        traffic_stats: Arc<TrafficStatsManager>,
    ) -> Self {
        Self {
            state: ApiState {
                proxy_manager,
                health_monitor,
                traffic_stats,
            },
            cancel_token: CancellationToken::new(),
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    /// The state the handlers read.
    pub fn state(&self) -> &ApiState {
        &self.state
    }

    /// Serve on `addr` until [`ApiServer::stop`], returning the bound address.
    ///
    /// The listener is created before this returns, so a caller that finds out
    /// the port is taken finds out *here* — not from a background task's log
    /// line an hour later.
    pub async fn start(&self, addr: SocketAddr) -> Result<SocketAddr> {
        if self.running.load(Ordering::Relaxed) {
            return Err(Error::config("the REST API is already running"));
        }

        let listener = TcpListener::bind(addr).await.map_err(|error| {
            Error::network(format!("failed to bind the REST API to {addr}: {error}"))
        })?;
        let local = listener.local_addr().map_err(|error| {
            Error::network(format!("failed to read the REST API address: {error}"))
        })?;

        let state = self.state.clone();
        let cancel_token = self.cancel_token.clone();
        let running = Arc::clone(&self.running);
        running.store(true, Ordering::Relaxed);

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = cancel_token.cancelled() => break,
                    result = listener.accept() => {
                        match result {
                            Ok((stream, peer)) => {
                                let _ = stream.set_nodelay(true);
                                let state = state.clone();
                                tokio::spawn(async move {
                                    if let Err(error) = Self::serve(stream, state).await {
                                        tracing::debug!("REST API connection from {peer} ended: {error}");
                                    }
                                });
                            }
                            Err(error) => {
                                tracing::error!("REST API accept error: {error}");
                            }
                        }
                    }
                }
            }
            running.store(false, Ordering::Relaxed);
            tracing::info!("REST API on {local} stopped");
        });

        tracing::info!("REST API listening on {local}");
        Ok(local)
    }

    /// Stop serving and wait for the accept loop to finish.
    pub async fn stop(&self) {
        self.cancel_token.cancel();

        let mut attempts = 0;
        while self.running.load(Ordering::Relaxed) && attempts < 50 {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            attempts += 1;
        }
    }

    /// Answer requests on one connection until the client leaves or asks to.
    async fn serve<S>(stream: S, state: ApiState) -> Result<()>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let mut connection = H1Connection::with_limits(stream, MAX_HEAD_LEN, MAX_BODY_LEN);

        loop {
            let request = match connection.read_request().await {
                Ok(Some(request)) => request,
                Ok(None) => break,
                Err(error) => {
                    tracing::debug!("REST API request could not be read: {error}");
                    break;
                }
            };

            let keep_alive = request.keep_alive();
            let response = dispatch(&state, &request).await;
            let close = response.close || !keep_alive;

            if let Err(error) = connection.write_response(&response).await {
                tracing::debug!("REST API response could not be written: {error}");
                break;
            }

            if close {
                break;
            }
        }

        Ok(())
    }
}

/// Route one request.
async fn dispatch(state: &ApiState, request: &Request) -> Response {
    let method = request.method.as_str();
    let path = request.target.split('?').next().unwrap_or("");

    match (method, path) {
        ("GET", "/api/v1/info") => json(ApiResponse::success(server_info(state))),
        ("GET", "/api/v1/traffic") => json(ApiResponse::success(traffic_stats(state))),
        ("POST", "/api/v1/traffic/reset") => {
            state.traffic_stats.reset().await;
            json(ApiResponse::success("Traffic statistics reset".to_string()))
        }
        ("GET", "/api/v1/health") => json(ApiResponse::success(health(state))),
        ("GET", "/api/v1/proxies") => json(ApiResponse::success(proxies(state).await)),
        ("GET", "/api/v1/config") => {
            let config = state.proxy_manager.get_config().await;
            json(ApiResponse::success(config))
        }
        ("POST", "/api/v1/config") => update_config(state, &request.body).await,
        ("GET", "/api/v1/rules") => json(ApiResponse::success(rules(state).await)),
        ("GET", _) if path.starts_with("/api/v1/proxies/") => {
            let tag = &path["/api/v1/proxies/".len()..];
            json(proxy(state, tag).await)
        }
        _ => {
            let mut response =
                json::<()>(ApiResponse::error(format!("no route for {method} {path}")));
            response.status = 404;
            response
        }
    }
}

/// Build a `200 OK` JSON answer.
fn json<T: Serialize>(value: ApiResponse<T>) -> Response {
    match serde_json::to_vec(&value) {
        Ok(body) => {
            let mut response = Response::new(200, body);
            response.set_header("content-type", "application/json; charset=utf-8");
            // Counters and configuration are live values; a cached answer is a
            // wrong answer.
            response.set_header("cache-control", "no-store");
            response
        }
        Err(error) => {
            tracing::error!("REST API could not encode a response: {error}");
            let mut response = Response::text(500, "failed to encode the response\n");
            response.headers.clear();
            response.set_header("content-type", "text/plain; charset=utf-8");
            response
        }
    }
}

/// Get server information
fn server_info(state: &ApiState) -> ServerInfo {
    ServerInfo {
        version: env!("CARGO_PKG_VERSION").to_string(),
        uptime: 0,
        active_connections: state.traffic_stats.active_connections(),
    }
}

/// Get traffic statistics
fn traffic_stats(state: &ApiState) -> TrafficResponse {
    let stats = state.traffic_stats.global_stats();
    TrafficResponse {
        upload_bytes: stats.upload_bytes,
        download_bytes: stats.download_bytes,
        total_bytes: stats.total_bytes(),
        connections: stats.connections,
        connection_time_secs: stats.connection_time_secs,
    }
}

/// Get health status of all proxies
fn health(state: &ApiState) -> Vec<HealthResponse> {
    state
        .health_monitor
        .get_all_health()
        .into_iter()
        .map(|(tag, status)| {
            let (status_str, details) = match status {
                HealthStatus::Healthy => ("healthy".to_string(), None),
                HealthStatus::Unhealthy { reason, last_error } => {
                    let details = match (reason, last_error) {
                        (reason, Some(error)) => format!("{reason}: {error}"),
                        (reason, None) => reason,
                    };
                    ("unhealthy".to_string(), Some(details))
                }
                HealthStatus::Unknown => ("unknown".to_string(), None),
            };

            HealthResponse {
                tag,
                status: status_str,
                details,
            }
        })
        .collect()
}

/// Describe one outbound the way the API reports it.
fn describe(state: &ApiState, outbound: crate::core::config::OutboundConfig) -> ProxyInfo {
    let healthy = state
        .health_monitor
        .get_health(&outbound.tag)
        .map(|status| matches!(status, HealthStatus::Healthy))
        .unwrap_or(false);

    ProxyInfo {
        tag: outbound.tag,
        proxy_type: format!("{:?}", outbound.outbound_type),
        server: outbound.server,
        port: outbound.port,
        healthy,
    }
}

/// Get all proxies
async fn proxies(state: &ApiState) -> Vec<ProxyInfo> {
    let config = state.proxy_manager.get_config().await;
    config
        .outbounds
        .into_iter()
        .map(|outbound| describe(state, outbound))
        .collect()
}

/// Get specific proxy information, or the error envelope when it is unknown.
async fn proxy(state: &ApiState, tag: &str) -> ApiResponse<ProxyInfo> {
    let config = state.proxy_manager.get_config().await;

    match config.outbounds.into_iter().find(|o| o.tag == tag) {
        Some(outbound) => ApiResponse::success(describe(state, outbound)),
        None => ApiResponse::error(format!("Proxy '{tag}' not found")),
    }
}

/// Update configuration
async fn update_config(state: &ApiState, body: &[u8]) -> Response {
    let request: ConfigUpdateRequest = match serde_json::from_slice(body) {
        Ok(request) => request,
        Err(error) => {
            let mut response = json::<()>(ApiResponse::error(format!(
                "Invalid configuration body: {error}"
            )));
            response.status = 400;
            return response;
        }
    };

    match state.proxy_manager.reload(request.config).await {
        Ok(()) => json(ApiResponse::success(
            "Configuration updated successfully".to_string(),
        )),
        Err(error) => {
            let mut response = json::<()>(ApiResponse::error(format!(
                "Failed to update configuration: {error}"
            )));
            response.status = 400;
            response
        }
    }
}

/// Get routing rules
async fn rules(state: &ApiState) -> Vec<serde_json::Value> {
    let config = state.proxy_manager.get_config().await;
    config
        .rules
        .into_iter()
        .map(|rule| {
            serde_json::json!({
                "type": format!("{:?}", rule.rule_type),
                "payload": rule.payload,
                "outbound": rule.outbound,
                "process_name": rule.process_name,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use courierust::courierust_http::{HeaderMap, Method, Version};

    fn request(method: Method, target: &str, body: &'static [u8]) -> Request {
        Request {
            method,
            target: target.to_string(),
            version: Version::HTTP_11,
            headers: HeaderMap::new(),
            body: Bytes::from_static(body),
        }
    }

    #[test]
    fn the_error_envelope_has_a_stable_shape() {
        let encoded =
            serde_json::to_string(&ApiResponse::<()>::error("boom".to_string())).expect("encode");
        assert_eq!(encoded, r#"{"success":false,"data":null,"error":"boom"}"#);
    }

    #[test]
    fn the_success_envelope_has_a_stable_shape() {
        let encoded = serde_json::to_string(&ApiResponse::success(42u32)).expect("encode");
        assert_eq!(encoded, r#"{"success":true,"data":42,"error":null}"#);
    }

    #[tokio::test]
    async fn unknown_routes_are_answered_with_404() {
        let state = ApiState {
            proxy_manager: Arc::new(
                ProxyManager::new(Config::default())
                    .await
                    .expect("a manager with no inbounds"),
            ),
            health_monitor: Arc::new(HealthMonitor::new(
                crate::core::health_check::HealthCheckConfig::default(),
            )),
            traffic_stats: Arc::new(TrafficStatsManager::new()),
        };

        let response = dispatch(&state, &request(Method::GET, "/nope", b"")).await;
        assert_eq!(response.status, 404);
        let body = String::from_utf8(response.body.to_vec()).expect("utf8");
        assert!(body.contains("\"success\":false"), "got: {body}");
    }
}
