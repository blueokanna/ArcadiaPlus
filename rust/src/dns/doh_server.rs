//! DNS over HTTPS (DoH) server implementation.
//!
//! RFC 8484: a DNS query arrives as a binary message either POSTed as the
//! request body or GET-encoded in the `?dns=` parameter, and the answer leaves
//! as `application/dns-message`.
//!
//! Framing comes from [`crate::protocol::h1_server`] — this crate's HTTP/1.1
//! core over `courierust_h1` — the same core the proxy inbounds use. A DoH
//! server that framed requests differently from the proxies next to it would be
//! two parsers on one port range, and two parsers are two answers to "where did
//! this message end"; keeping one is what makes keep-alive safe here.
//!
//! TLS stays on `rustls` (via `tokio-rustls`), the layer the inbound-TLS and
//! QUIC paths already use, so a certificate loaded here is validated by the
//! same stack as everywhere else in this crate.

use crate::crypto::base64::Engine;
use crate::crypto::base64::URL_SAFE_NO_PAD;
use crate::dns::RecordType;
use crate::dns::error::{DnsError, Result};
use crate::dns::resolver::DnsResolver;
use crate::protocol::h1_server::{H1Connection, Request, Response};
use hickory_proto::op::{Message, ResponseCode};
use hickory_proto::rr::{RData, Record};
use hickory_proto::serialize::binary::{BinDecodable, BinEncodable};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use std::fs::File;
use std::io::BufReader;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tokio_rustls::TlsAcceptor;
use tracing::{debug, error, info, trace, warn};

/// Cap on a DoH request head. DNS queries carry a method, a path and a handful
/// of headers; anything larger is a mistake or an attack.
const MAX_HEAD_LEN: usize = 16 * 1024;

/// Cap on a DoH request body. The largest realistic DNS message is a few
/// kilobytes of EDNS payload, so 64 KiB is generous without being a foothold.
const MAX_BODY_LEN: usize = 64 * 1024;

/// Media type RFC 8484 §6 defines for DNS messages.
const DNS_MEDIA_TYPE: &str = "application/dns-message";

/// How long a client may cache an answer.
///
/// The resolver's own cache is the authority on TTLs; this is the ceiling a
/// browser is asked to respect, so a stubbed answer cannot outlive a config
/// change by hours.
const MAX_AGE_SECONDS: u32 = 300;

/// DoH server configuration
#[derive(Debug, Clone)]
pub struct DohServerConfig {
    /// Listen address
    pub listen: SocketAddr,
    /// TLS certificate path
    pub cert_path: String,
    /// TLS private key path
    pub key_path: String,
    /// DNS query path (default: /dns-query)
    pub path: String,
}

impl Default for DohServerConfig {
    fn default() -> Self {
        Self {
            // Built from octets rather than parsed from a string: a default
            // value must not be able to fail.
            listen: SocketAddr::from(([127, 0, 0, 1], 8443)),
            cert_path: String::new(),
            key_path: String::new(),
            path: "/dns-query".to_string(),
        }
    }
}

/// DNS over HTTPS server
pub struct DohServer {
    /// Configuration
    config: DohServerConfig,
    /// DNS resolver
    resolver: Arc<DnsResolver>,
    /// TLS acceptor
    tls_acceptor: Option<TlsAcceptor>,
    /// Shutdown signal sender
    shutdown_tx: broadcast::Sender<()>,
}

impl DohServer {
    /// Create a new DoH server
    pub fn new(config: DohServerConfig, resolver: Arc<DnsResolver>) -> Result<Self> {
        let tls_acceptor = if !config.cert_path.is_empty() && !config.key_path.is_empty() {
            Some(Self::create_tls_acceptor(
                &config.cert_path,
                &config.key_path,
            )?)
        } else {
            None
        };

        let (shutdown_tx, _) = broadcast::channel(1);

        Ok(Self {
            config,
            resolver,
            tls_acceptor,
            shutdown_tx,
        })
    }

    /// Create TLS acceptor from certificate and key files
    fn create_tls_acceptor(cert_path: &str, key_path: &str) -> Result<TlsAcceptor> {
        let certs = Self::load_certs(cert_path)?;
        let key = Self::load_private_key(key_path)?;

        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .map_err(|e| DnsError::Tls(format!("TLS config error: {}", e)))?;

        Ok(TlsAcceptor::from(Arc::new(config)))
    }

    /// Load certificates from PEM file
    fn load_certs(path: &str) -> Result<Vec<CertificateDer<'static>>> {
        let file = File::open(path)
            .map_err(|e| DnsError::Config(format!("Failed to open cert file: {}", e)))?;
        let mut reader = BufReader::new(file);

        let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut reader)
            .filter_map(|r| r.ok())
            .collect();

        if certs.is_empty() {
            return Err(DnsError::Config(
                "No certificates found in file".to_string(),
            ));
        }

        Ok(certs)
    }

    /// Load private key from PEM file
    fn load_private_key(path: &str) -> Result<PrivateKeyDer<'static>> {
        let file = File::open(path)
            .map_err(|e| DnsError::Config(format!("Failed to open key file: {}", e)))?;
        let mut reader = BufReader::new(file);

        loop {
            match rustls_pemfile::read_one(&mut reader) {
                Ok(Some(rustls_pemfile::Item::Pkcs1Key(key))) => {
                    return Ok(PrivateKeyDer::Pkcs1(key));
                }
                Ok(Some(rustls_pemfile::Item::Pkcs8Key(key))) => {
                    return Ok(PrivateKeyDer::Pkcs8(key));
                }
                Ok(Some(rustls_pemfile::Item::Sec1Key(key))) => {
                    return Ok(PrivateKeyDer::Sec1(key));
                }
                Ok(None) => break,
                Ok(Some(_)) => continue,
                Err(e) => {
                    return Err(DnsError::Config(format!("Failed to parse key: {}", e)));
                }
            }
        }

        Err(DnsError::Config("No private key found in file".to_string()))
    }

    /// Start the DoH server
    pub async fn start(&self) -> Result<()> {
        let listener = TcpListener::bind(self.config.listen).await?;
        info!("DoH server listening on {}", self.config.listen);

        let resolver = self.resolver.clone();
        let path = self.config.path.clone();
        let tls_acceptor = self.tls_acceptor.clone();
        let mut shutdown_rx = self.shutdown_tx.subscribe();

        loop {
            tokio::select! {
                result = listener.accept() => {
                    match result {
                        Ok((stream, addr)) => {
                            let _ = stream.set_nodelay(true);
                            let resolver = resolver.clone();
                            let path = path.clone();
                            let tls_acceptor = tls_acceptor.clone();

                            tokio::spawn(async move {
                                if let Err(e) = Self::handle_connection(
                                    stream,
                                    addr,
                                    resolver,
                                    path,
                                    tls_acceptor,
                                ).await {
                                    debug!("DoH connection error from {}: {}", addr, e);
                                }
                            });
                        }
                        Err(e) => {
                            error!("DoH accept error: {}", e);
                        }
                    }
                }
                _ = shutdown_rx.recv() => {
                    info!("DoH server shutting down");
                    break;
                }
            }
        }

        Ok(())
    }

    /// Handle a single connection
    async fn handle_connection(
        stream: tokio::net::TcpStream,
        addr: SocketAddr,
        resolver: Arc<DnsResolver>,
        path: String,
        tls_acceptor: Option<TlsAcceptor>,
    ) -> Result<()> {
        trace!("DoH connection from {}", addr);

        if let Some(acceptor) = tls_acceptor {
            let tls_stream = acceptor
                .accept(stream)
                .await
                .map_err(|e| DnsError::Tls(format!("TLS handshake failed: {}", e)))?;
            Self::serve(tls_stream, resolver, path).await
        } else {
            Self::serve(stream, resolver, path).await
        }
    }

    /// Answer requests on one connection until the client leaves or asks to.
    ///
    /// The loop is what makes keep-alive real: a browser resolving a page sends
    /// a burst of queries over one connection, and re-running the whole accept
    /// path per query would spend more time in handshakes than in DNS.
    async fn serve<S>(stream: S, resolver: Arc<DnsResolver>, path: String) -> Result<()>
    where
        S: AsyncRead + AsyncWrite + Unpin,
    {
        let mut connection = H1Connection::with_limits(stream, MAX_HEAD_LEN, MAX_BODY_LEN);

        loop {
            let request = match connection.read_request().await {
                Ok(Some(request)) => request,
                Ok(None) => break,
                Err(error) => {
                    debug!("DoH request could not be read: {}", error);
                    break;
                }
            };

            let keep_alive = request.keep_alive();
            let response = Self::handle_request(&request, &resolver, &path).await;
            let close = response.close || !keep_alive;

            if let Err(error) = connection.write_response(&response).await {
                debug!("DoH response could not be written: {}", error);
                break;
            }

            if close {
                break;
            }
        }

        Ok(())
    }

    /// Handle HTTP request
    async fn handle_request(
        request: &Request,
        resolver: &DnsResolver,
        expected_path: &str,
    ) -> Response {
        // The target may carry a query string (`?dns=…`); the routing decision
        // is about the path alone.
        let path = request.target.split('?').next().unwrap_or("");

        if path != expected_path {
            return Response::text(404, "Not Found\n");
        }

        let outcome = match request.method.as_str() {
            "GET" => Self::handle_get_request(request, resolver).await,
            "POST" => Self::handle_post_request(request, resolver).await,
            _ => {
                let mut response = Response::text(405, "Method Not Allowed\n");
                response.set_header("allow", "GET, POST");
                return response;
            }
        };

        match outcome {
            Ok(answer) => {
                let body = answer.to_bytes().unwrap_or_default();
                let mut response = Response::new(200, body);
                response.set_header("content-type", DNS_MEDIA_TYPE);
                response.set_header("cache-control", &format!("max-age={MAX_AGE_SECONDS}"));
                response
            }
            Err(error) => {
                warn!("DoH query error: {}", error);
                // RFC 8484 §4.2.1: a server that cannot answer still answers —
                // an empty body with a 5xx tells the client not to retry the
                // same server, where a dropped connection tells it nothing.
                Response::text(500, format!("DNS Error: {error}\n"))
            }
        }
    }

    /// Handle GET request (base64url encoded DNS query in ?dns= parameter)
    async fn handle_get_request(request: &Request, resolver: &DnsResolver) -> Result<Message> {
        let query_string = request.target.split_once('?').map(|(_, q)| q).unwrap_or("");

        let dns_param = query_string
            .split('&')
            .find_map(|param| {
                let (key, value) = param.split_once('=')?;
                if key == "dns" { Some(value) } else { None }
            })
            .ok_or_else(|| DnsError::Protocol("Missing 'dns' query parameter".to_string()))?;

        // corduit's codec errors are `no_std`-lean and only implement `Debug`.
        let query_bytes = URL_SAFE_NO_PAD
            .decode(dns_param)
            .map_err(|e| DnsError::Protocol(format!("Invalid base64: {e:?}")))?;

        Self::process_dns_query(&query_bytes, resolver).await
    }

    /// Handle POST request (binary DNS message in body)
    async fn handle_post_request(request: &Request, resolver: &DnsResolver) -> Result<Message> {
        let content_type = request.header("content-type").unwrap_or("");

        if !content_type.contains(DNS_MEDIA_TYPE) {
            return Err(DnsError::Protocol(format!(
                "Invalid content-type: {}",
                content_type
            )));
        }

        Self::process_dns_query(&request.body, resolver).await
    }

    /// Process DNS query and generate response
    async fn process_dns_query(query_bytes: &[u8], resolver: &DnsResolver) -> Result<Message> {
        let request = Message::from_bytes(query_bytes)
            .map_err(|e| DnsError::Protocol(format!("Invalid DNS message: {}", e)))?;

        let mut response = Message::response(request.metadata.id, request.metadata.op_code);
        response.metadata.recursion_desired = request.metadata.recursion_desired;
        response.metadata.recursion_available = true;

        for query in &request.queries {
            response.add_query(query.clone());
        }

        for query in &request.queries {
            let name = query.name().to_string();
            let record_type = RecordType::from(query.query_type());

            trace!("DoH query: {} {:?}", name, record_type);

            match resolver.resolve(&name, record_type).await {
                Ok(ips) => {
                    for ip in ips {
                        let rdata = match ip {
                            IpAddr::V4(v4) => RData::A(hickory_proto::rr::rdata::A(v4)),
                            IpAddr::V6(v6) => RData::AAAA(hickory_proto::rr::rdata::AAAA(v6)),
                        };

                        let record =
                            Record::from_rdata(query.name().clone(), MAX_AGE_SECONDS, rdata);
                        response.add_answer(record);
                    }

                    if response.answers.is_empty() {
                        response.metadata.response_code = ResponseCode::NXDomain;
                    } else {
                        response.metadata.response_code = ResponseCode::NoError;
                    }
                }
                Err(e) => {
                    warn!("DoH resolution failed for {}: {}", name, e);
                    response.metadata.response_code = ResponseCode::ServFail;
                }
            }
        }

        Ok(response)
    }

    /// Stop the DoH server
    pub fn stop(&self) {
        let _ = self.shutdown_tx.send(());
    }

    /// Get the listen address
    pub fn listen_addr(&self) -> SocketAddr {
        self.config.listen
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dns::config::DnsConfig;
    use crate::protocol::h1_server::Request;
    use bytes::Bytes;
    use courierust::courierust_http::{HeaderMap, HeaderValue, Method, Version};

    fn request(method: Method, target: &str, content_type: Option<&str>) -> Request {
        let mut headers = HeaderMap::new();
        if let Some(content_type) = content_type
            && let (Ok(name), Ok(value)) = (
                "content-type".parse(),
                HeaderValue::from_bytes(content_type.as_bytes()),
            )
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
    fn test_doh_server_config_default() {
        let config = DohServerConfig::default();
        assert_eq!(config.path, "/dns-query");
    }

    #[tokio::test]
    async fn test_doh_server_creation_without_tls() {
        let dns_config = DnsConfig {
            nameservers: vec!["8.8.8.8".to_string()],
            ..Default::default()
        };
        let resolver = Arc::new(DnsResolver::new(dns_config).unwrap());

        let config = DohServerConfig {
            listen: "127.0.0.1:18443".parse().unwrap(),
            cert_path: String::new(),
            key_path: String::new(),
            path: "/dns-query".to_string(),
        };

        let server = DohServer::new(config, resolver);
        assert!(server.is_ok());
    }

    #[tokio::test]
    async fn unknown_paths_are_not_found() {
        let dns_config = DnsConfig {
            nameservers: vec!["8.8.8.8".to_string()],
            ..Default::default()
        };
        let resolver = DnsResolver::new(dns_config).unwrap();

        let response = DohServer::handle_request(
            &request(Method::GET, "/nope", None),
            &resolver,
            "/dns-query",
        )
        .await;
        assert_eq!(response.status, 404);
    }

    #[tokio::test]
    async fn unsupported_methods_say_which_ones_are_supported() {
        let dns_config = DnsConfig {
            nameservers: vec!["8.8.8.8".to_string()],
            ..Default::default()
        };
        let resolver = DnsResolver::new(dns_config).unwrap();

        let response = DohServer::handle_request(
            &request(Method::DELETE, "/dns-query", None),
            &resolver,
            "/dns-query",
        )
        .await;
        assert_eq!(response.status, 405);
        assert!(
            response
                .headers
                .iter()
                .any(|(name, value)| name.as_str() == "allow" && value == "GET, POST"),
            "the answer must name the methods it accepts"
        );
    }

    #[tokio::test]
    async fn posts_without_the_dns_media_type_are_rejected() {
        let dns_config = DnsConfig {
            nameservers: vec!["8.8.8.8".to_string()],
            ..Default::default()
        };
        let resolver = DnsResolver::new(dns_config).unwrap();

        let response = DohServer::handle_request(
            &request(Method::POST, "/dns-query", Some("text/plain")),
            &resolver,
            "/dns-query",
        )
        .await;
        assert_eq!(response.status, 500);
    }
}
