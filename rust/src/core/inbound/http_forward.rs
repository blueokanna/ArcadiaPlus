//! The one place a proxied HTTP request is forwarded.
//!
//! The HTTP inbound and the HTTP half of the mixed inbound do exactly the same
//! work: route the request, refuse what cannot be routed, answer `CONNECT` by
//! handing back a tunnel, and forward everything else upstream. Keeping two
//! copies of that path meant two copies of the routing call, the hop-by-hop
//! filtering, the `CONNECT` handshake and the error mapping — and the copies
//! had already drifted: one re-parsed the upstream status line, the other
//! answered `200` no matter what the server said. This module is the single
//! answer; the inbounds only differ in which port they listen on and whether
//! they also speak SOCKS5.
//!
//! ## Shape of the forward
//!
//! * The request head arrives from the client over
//!   [`crate::protocol::h1_server`]; the *same* bytes are re-emitted upstream by
//!   [`crate::protocol::h1_client`] as origin-form, with hop-by-hop fields
//!   dropped and the body re-framed by length. Nothing is decided by regex over
//!   a byte string: both halves share one parser.
//! * The upstream connection comes from the router's chosen outbound, so a
//!   request can leave through DIRECT or through another proxy exactly as the
//!   rule set dictates.
//! * Failures become HTTP answers (`502`/`400`) rather than dropped sockets:
//!   an HTTP proxy that closes silently on error leaves clients guessing, and
//!   guessing is how a proxy turns into a bug report.

use std::sync::Arc;
use std::time::Duration;

use courierust::courierust_http::StatusCode;
use tokio::io::{AsyncRead, AsyncWrite};

use crate::core::connection_tracker::{TrackedConnection, global_tracker};
use crate::core::error::{Error, Result};
use crate::core::outbound::{OutboundManager, OutboundProxy, TargetAddr};
use crate::core::routing::Router;
use crate::protocol::h1_client::{
    self, DEFAULT_MAX_BODY_LEN, DEFAULT_MAX_HEAD_LEN, UpstreamRequest,
};
use crate::protocol::h1_server::{H1Connection, PrefixedStream, Request, Response};

/// Time budget for the upstream leg of one proxied request.
///
/// The client is waiting for an answer on an open connection; a proxy that
/// never gives up holds both sockets for as long as DNS or a firewall feels
/// like it. Thirty seconds is long enough for a slow origin and short enough
/// that a dead one is reported as `502`.
const UPSTREAM_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a display-only reverse lookup may hold up a tunnel.
///
/// The connection list shows a destination IP when one is known; the tunnel
/// does not depend on knowing it, so a resolver that hangs delays the entry
/// and not the traffic.
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(2);

/// Marker that identifies this hop in `Via`-style diagnostics.
pub const PROXY_AGENT: &str = "VeloGuard";

/// Where a proxied request is headed.
#[derive(Debug, Clone)]
pub struct Destination {
    /// Host name or IP literal from the request target.
    pub host: String,
    /// Port, with the scheme default applied when the client omitted it.
    pub port: u16,
}

/// A `CONNECT` that the caller must turn into a tunnel.
pub struct Tunnel {
    /// The authority the client asked for.
    pub destination: Destination,
    /// The outbound that will carry the tunnel.
    pub outbound: Arc<dyn OutboundProxy>,
    /// The outbound's tag, for logging and connection tracking.
    pub outbound_tag: String,
}

/// The outcome of forwarding one request.
pub enum Forwarded {
    /// Answer `200` and relay the socket (the `CONNECT` case).
    Tunnel(Tunnel),
    /// A finished response to write back to the client.
    Response(Response),
}

/// Route and forward one request.
pub async fn forward(
    request: &Request,
    router: &Router,
    outbound_manager: &OutboundManager,
    max_body: usize,
) -> Forwarded {
    let Some(destination) = destination_of(request) else {
        return Forwarded::Response(bad_request("the request target carries no usable host"));
    };

    let outbound_tag = router
        .match_outbound(Some(&destination.host), None, Some(destination.port), None)
        .await;

    let Some(outbound) = outbound_manager.get_proxy(&outbound_tag) else {
        tracing::error!(
            "HTTP proxy request for {}:{} matched unknown outbound '{}'",
            destination.host,
            destination.port,
            outbound_tag
        );
        return Forwarded::Response(bad_gateway(&format!(
            "outbound '{outbound_tag}' is not configured"
        )));
    };

    if request.connect_authority().is_some() {
        tracing::info!(
            "CONNECT {}:{} via '{}'",
            destination.host,
            destination.port,
            outbound_tag
        );
        return Forwarded::Tunnel(Tunnel {
            destination,
            outbound,
            outbound_tag,
        });
    }

    tracing::debug!(
        "{} {}:{} via '{}'",
        request.method.as_str(),
        destination.host,
        destination.port,
        outbound_tag
    );

    match exchange(request, &destination, outbound.as_ref(), max_body).await {
        Ok(response) => Forwarded::Response(response),
        Err(error) => {
            tracing::warn!(
                "forwarding {} to {}:{} failed: {}",
                request.method.as_str(),
                destination.host,
                destination.port,
                error
            );
            Forwarded::Response(bad_gateway(&format!("upstream request failed: {error}")))
        }
    }
}

/// Answer one `CONNECT` and relay the tunnel until either side closes.
///
/// Shared by the HTTP and mixed inbounds: the only thing that differs between
/// them is the tag the connection shows up under, so the read-ahead replay,
/// the display lookup and the tracking become one implementation instead of
/// two that drift.
pub async fn open_tunnel<S>(
    connection: H1Connection<S>,
    tunnel: Tunnel,
    inbound_tag: &str,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (socket, buffered) = connection
        .accept_connect(&[("proxy-agent", PROXY_AGENT)])
        .await
        .map_err(|error| Error::network(format!("failed to answer CONNECT: {error}")))?;

    let destination = tunnel.destination;
    let target = TargetAddr::new_domain(destination.host.clone(), destination.port);

    // Resolve the destination for the connection list only; the tunnel does
    // not depend on the answer.
    let destination_ip = match target {
        TargetAddr::Ip(addr) => Some(addr.ip().to_string()),
        TargetAddr::Domain(ref domain, port) => tokio::time::timeout(
            LOOKUP_TIMEOUT,
            tokio::net::lookup_host(format!("{domain}:{port}")),
        )
        .await
        .ok()
        .and_then(|result| result.ok())
        .and_then(|mut addrs| addrs.next())
        .map(|addr| addr.ip().to_string()),
    };

    let tracker = global_tracker();
    let tracked = tracker.track(TrackedConnection::new_with_ip(
        inbound_tag.to_string(),
        tunnel.outbound_tag.clone(),
        destination.host.clone(),
        destination_ip,
        destination.port,
        "HTTPS".to_string(),
        "tcp".to_string(),
        "HTTP-CONNECT".to_string(),
        format!("{}:{}", destination.host, destination.port),
    ));
    let tracked = Arc::clone(&tracked);

    tracing::debug!(
        "HTTP tunnel {}:{} established via '{}'",
        destination.host,
        destination.port,
        tunnel.outbound_tag
    );

    let result = tunnel
        .outbound
        .relay_tcp_with_connection(
            Box::new(PrefixedStream::new(socket, buffered)),
            target,
            Some(tracked.clone()),
        )
        .await;

    tracker.untrack(&tracked.id);

    if let Err(error) = result {
        tracing::debug!(
            "HTTP tunnel to {}:{} via '{}' ended: {}",
            destination.host,
            destination.port,
            tunnel.outbound_tag,
            error
        );
    }

    Ok(())
}

/// Send the request upstream and read one response.
async fn exchange(
    request: &Request,
    destination: &Destination,
    outbound: &dyn OutboundProxy,
    max_body: usize,
) -> Result<Response> {
    let target = TargetAddr::new_domain(destination.host.clone(), destination.port);

    // The outbound owns the upstream socket; a duplex pair lets this function
    // speak HTTP into it while the outbound's relay moves the bytes.
    let (mut upstream, relay_side) = tokio::io::duplex(64 * 1024);
    let relay = outbound.relay_tcp(Box::new(relay_side), target);

    let mut headers = request.headers.clone();
    ensure_host(&mut headers, destination);
    let origin = origin_form(request);

    let upstream_request = UpstreamRequest {
        method: &request.method,
        target: &origin,
        headers,
        body: request.body.clone(),
    };

    // Two things can end this wait: the response, or the outbound giving up
    // first (a failed connect, for instance). Waiting only on the response
    // would turn an outbound that never connects into a full timeout instead of
    // an immediate `502`, so both are raced.
    let mut exchange = std::pin::pin!(h1_client::exchange(
        &mut upstream,
        &upstream_request,
        DEFAULT_MAX_HEAD_LEN,
        max_body.clamp(1, DEFAULT_MAX_BODY_LEN),
    ));
    let mut relay = std::pin::pin!(relay);

    let response = tokio::select! {
        biased;
        answer = tokio::time::timeout(UPSTREAM_TIMEOUT, &mut exchange) => match answer {
            Ok(Ok(response)) => response,
            Ok(Err(error)) => {
                return Err(Error::network(format!("upstream exchange failed: {error}")));
            }
            Err(_) => {
                return Err(Error::network(format!(
                    "upstream exchange exceeded {}s",
                    UPSTREAM_TIMEOUT.as_secs()
                )));
            }
        },
        outcome = &mut relay => {
            return Err(match outcome {
                Ok(()) => Error::network("the outbound closed before answering"),
                Err(error) => Error::network(format!("outbound relay failed: {error}")),
            });
        }
    };

    // Returning drops our half of the duplex and the relay future with it: the
    // outbound's client-to-upstream direction has nothing left to pump, and the
    // answer must not wait for that unwind. The response was fully read by this
    // point, so nothing is truncated.
    let mut answer = Response::new(response.status.as_u16(), response.body);

    // The body was decoded, so its framing is this hop's business: the length
    // is re-derived from the bytes we are about to write and the upstream's
    // framing headers must not travel on.
    let mut headers = response.headers;
    for name in [
        "content-length",
        "transfer-encoding",
        "connection",
        "keep-alive",
    ] {
        headers.remove(name);
    }
    for (name, value) in headers.iter() {
        if let Ok(value) = value.to_str() {
            answer.set_header(name.as_str(), value);
        }
    }

    // A client that asked for `Connection: close` gets it — and so does one
    // whose connection this hop cannot keep alive for any other reason.
    answer.close = !request.keep_alive();

    Ok(answer)
}

/// The upstream request target: origin-form, whatever form the client used.
fn origin_form(request: &Request) -> String {
    let target = request.target.as_str();

    // Absolute-form (the proxy case): strip scheme and authority, keep the
    // path and query. Parsing with the same URL type the rest of the crate
    // uses keeps "what is a path" decided in one place.
    if (target.starts_with("http://") || target.starts_with("https://"))
        && let Ok(url) = corduit::common::url::Url::parse(target)
    {
        let mut form = url.path().to_string();
        if !form.starts_with('/') {
            form.insert(0, '/');
        }
        if let Some(query) = url.query() {
            form.push('?');
            form.push_str(query);
        }
        return form;
    }

    // Origin-form and asterisk-form already are what upstream wants.
    target.to_string()
}

/// The `Host` header upstream must see (RFC 9112 §3.2).
///
/// A client that sent absolute-form is *supposed* to send `Host` too, but
/// "supposed to" is not a framing guarantee: a request without it is not a
/// well-formed HTTP/1.1 request, so rather than forward one we synthesize it
/// from the authority we routed on.
fn ensure_host(headers: &mut courierust::courierust_http::HeaderMap, destination: &Destination) {
    if headers.contains_key("host") {
        return;
    }
    let host = if destination.port == 80 {
        destination.host.clone()
    } else {
        format!("{}:{}", destination.host, destination.port)
    };
    if let (Ok(name), Ok(value)) = (
        "host".parse::<courierust::courierust_http::HeaderName>(),
        courierust::courierust_http::HeaderValue::from_bytes(host.as_bytes()),
    ) {
        headers.insert(name, value);
    }
}

/// Work out where the request is headed.
fn destination_of(request: &Request) -> Option<Destination> {
    if let Some(authority) = request.connect_authority() {
        return split_authority(authority, None);
    }

    let target = request.target.as_str();
    let absolute_form = target.starts_with("http://") || target.starts_with("https://");

    if absolute_form
        && let Ok(url) = corduit::common::url::Url::parse(target)
        && let Some(host) = url.host_str()
    {
        let default_port = if url.scheme() == "https" { 443 } else { 80 };
        let port = url.port().unwrap_or(default_port);
        return Some(Destination {
            host: host.to_string(),
            port,
        });
    }

    // An absolute-form target we could not read is refused rather than
    // re-routed through `Host`: the client named an origin, and answering a
    // *different* one because parsing failed would be a routing decision the
    // client never asked for.
    if absolute_form {
        return None;
    }

    // Origin-form: the authority is in `Host`.
    let host = request.header("host")?;
    split_authority(host, Some(80))
}

/// Split `host[:port]`, with IPv6 literals in brackets.
fn split_authority(authority: &str, default_port: Option<u16>) -> Option<Destination> {
    let authority = authority.trim();
    if authority.is_empty() {
        return None;
    }

    // `[::1]:443` — the only place a colon inside the host is legal.
    if let Some(rest) = authority.strip_prefix('[') {
        let (host, tail) = rest.split_once(']')?;
        let port = match tail.split_once(':') {
            Some((_, port)) => port.parse::<u16>().ok()?,
            None => default_port?,
        };
        if host.is_empty() || port == 0 {
            return None;
        }
        return Some(Destination {
            host: host.to_string(),
            port,
        });
    }

    match authority.rsplit_once(':') {
        Some((host, port)) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => {
            let port = port.parse::<u16>().ok()?;
            if host.is_empty() || port == 0 {
                return None;
            }
            Some(Destination {
                host: host.to_string(),
                port,
            })
        }
        Some(_) => None,
        None => Some(Destination {
            host: authority.to_string(),
            port: default_port?,
        }),
    }
}

/// A `502` with a plain-text explanation.
fn bad_gateway(detail: &str) -> Response {
    Response::text(StatusCode::BAD_GATEWAY.as_u16(), format!("{detail}\r\n"))
}

/// A `400` with a plain-text explanation.
fn bad_request(detail: &str) -> Response {
    Response::text(StatusCode::BAD_REQUEST.as_u16(), format!("{detail}\r\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use courierust::courierust_http::{HeaderMap, HeaderValue, Method, Version};

    fn request(method: Method, target: &str, host: Option<&str>) -> Request {
        let mut headers = HeaderMap::new();
        if let Some(host) = host
            && let (Ok(name), Ok(value)) =
                ("host".parse(), HeaderValue::from_bytes(host.as_bytes()))
        {
            headers.insert(name, value);
        }
        Request {
            method,
            target: target.to_string(),
            version: Version::HTTP_11,
            headers,
            body: Bytes::new(),
        }
    }

    #[test]
    fn absolute_form_targets_keep_path_and_query() {
        let form = origin_form(&request(
            Method::GET,
            "http://example.com:8080/a/b?c=d&e=f",
            None,
        ));
        assert_eq!(form, "/a/b?c=d&e=f");
    }

    #[test]
    fn origin_form_targets_pass_through() {
        let form = origin_form(&request(
            Method::GET,
            "/index.html?x=1",
            Some("example.com"),
        ));
        assert_eq!(form, "/index.html?x=1");
    }

    #[test]
    fn connects_parse_the_authority() {
        let found = destination_of(&request(Method::CONNECT, "example.com:8443", None))
            .expect("destination");
        assert_eq!(found.host, "example.com");
        assert_eq!(found.port, 8443);
    }

    #[test]
    fn ipv6_authorities_keep_their_brackets_off() {
        let found = destination_of(&request(Method::CONNECT, "[2001:db8::1]:443", None))
            .expect("destination");
        assert_eq!(found.host, "2001:db8::1");
        assert_eq!(found.port, 443);
    }

    #[test]
    fn missing_port_uses_the_scheme_default() {
        let found = destination_of(&request(Method::GET, "https://example.com/x", None))
            .expect("destination");
        assert_eq!(found.port, 443);

        let found = destination_of(&request(Method::GET, "/x", Some("example.com")));
        assert_eq!(found.expect("destination").port, 80);
    }

    #[test]
    fn host_is_synthesized_when_the_client_omitted_it() {
        let mut headers = HeaderMap::new();
        ensure_host(
            &mut headers,
            &Destination {
                host: "example.com".to_string(),
                port: 8080,
            },
        );
        assert_eq!(
            headers.get("host").and_then(|value| value.to_str().ok()),
            Some("example.com:8080")
        );
    }

    #[test]
    fn a_client_host_header_is_never_overwritten() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "host".parse().expect("name"),
            HeaderValue::from_static("upstream.example"),
        );
        ensure_host(
            &mut headers,
            &Destination {
                host: "example.com".to_string(),
                port: 80,
            },
        );
        assert_eq!(
            headers.get("host").and_then(|value| value.to_str().ok()),
            Some("upstream.example")
        );
    }

    #[test]
    fn empty_authorities_are_rejected() {
        assert!(split_authority("", Some(80)).is_none());
        assert!(split_authority(":443", Some(80)).is_none());
        assert!(split_authority("example.com:0", Some(80)).is_none());
    }
}
