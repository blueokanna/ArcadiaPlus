//! DNS over HTTPS (DoH) client implementation.
//!
//! RFC 8484: a query leaves as a binary message either POSTed as the body or
//! GET-encoded in `?dns=`, and comes back as `application/dns-message`.
//!
//! The exchange itself goes through [`crate::http`]: one TLS stack, one
//! connection pool and one body ceiling for every document this process
//! fetches. A DNS client that opened its own TLS connection would quietly trust
//! a second set of roots and pick a second set of timeouts — the kind of
//! divergence that only shows up as "one feature cannot reach this host".

use std::net::IpAddr;
use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use hickory_proto::op::{Message, MessageType, OpCode, Query};
use hickory_proto::rr::{Name, RData};
use hickory_proto::serialize::binary::BinDecodable;
use tokio::sync::RwLock;
use tracing::{debug, trace, warn};
use url::Url;

use crate::crypto::base64::Engine;
use crate::crypto::base64::URL_SAFE_NO_PAD;
use crate::dns::RecordType;
use crate::dns::error::{DnsError, Result};

/// DoH request method
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DohMethod {
    /// HTTP GET with base64url encoded query
    Get,
    /// HTTP POST with binary DNS message
    #[default]
    Post,
}

/// DoH client configuration
#[derive(Debug, Clone)]
pub struct DohClientConfig {
    /// DoH server URL
    pub url: String,
    /// Request method (GET or POST)
    pub method: DohMethod,
    /// Request timeout
    pub timeout: Duration,
    /// Custom headers
    pub headers: Vec<(String, String)>,
}

impl Default for DohClientConfig {
    fn default() -> Self {
        Self {
            url: "https://dns.google/dns-query".to_string(),
            method: DohMethod::Post,
            timeout: Duration::from_secs(5),
            headers: Vec::new(),
        }
    }
}

/// DoH client for DNS resolution
pub struct DohClient {
    /// Parsed URL
    url: Url,
    /// Request method
    method: DohMethod,
    /// Request timeout
    timeout: Duration,
    /// Custom headers
    headers: Vec<(String, String)>,
}

impl DohClient {
    /// Create a new DoH client with URL
    pub fn new(url: &str) -> Result<Self> {
        Self::with_config(DohClientConfig {
            url: url.to_string(),
            ..Default::default()
        })
    }

    /// Create a new DoH client with configuration
    pub fn with_config(config: DohClientConfig) -> Result<Self> {
        let url = Url::parse(&config.url)
            .map_err(|e| DnsError::Config(format!("Invalid DoH URL: {}", e)))?;

        // Validate URL scheme
        if url.scheme() != "https" {
            return Err(DnsError::Config("DoH URL must use HTTPS".to_string()));
        }

        Ok(Self {
            url,
            method: config.method,
            timeout: config.timeout,
            headers: config.headers,
        })
    }

    /// Resolve a domain name to IP addresses
    pub async fn resolve(&self, domain: &str) -> Result<Vec<IpAddr>> {
        // Try A records first
        let mut ips = self.query(domain, RecordType::A).await.unwrap_or_default();

        // Also try AAAA records
        if let Ok(ipv6) = self.query(domain, RecordType::AAAA).await {
            ips.extend(ipv6);
        }

        if ips.is_empty() {
            return Err(DnsError::QueryFailed(format!(
                "No addresses found for {}",
                domain
            )));
        }

        Ok(ips)
    }

    /// Query DNS records
    pub async fn query(&self, domain: &str, record_type: RecordType) -> Result<Vec<IpAddr>> {
        let query_bytes = self.build_query(domain, record_type.into())?;
        let response_bytes = self.exchange(&query_bytes).await?;
        self.parse_response(&response_bytes)
    }

    /// Build DNS query message
    fn build_query(
        &self,
        domain: &str,
        record_type: hickory_proto::rr::RecordType,
    ) -> Result<Vec<u8>> {
        let name = Name::from_str(domain)
            .map_err(|e| DnsError::NameError(format!("Invalid domain name: {}", e)))?;

        let mut message = Message::new(
            crate::crypto::random_u16(),
            MessageType::Query,
            OpCode::Query,
        );
        message.metadata.recursion_desired = true;

        let query = Query::query(name, record_type);
        message.add_query(query);

        message
            .to_vec()
            .map_err(|e| DnsError::Protocol(format!("Failed to serialize query: {}", e)))
    }

    /// Send one encoded DNS query and return the raw response message.
    ///
    /// This is the crate's only DoH exchange — [`crate::dns::client::DnsClient`]
    /// delegates here too, so the encoding rules and the transport can never
    /// disagree about what a DoH request is.
    pub async fn exchange(&self, query: &[u8]) -> Result<Vec<u8>> {
        match tokio::time::timeout(self.timeout, self.send(query)).await {
            Ok(result) => result,
            Err(_) => Err(DnsError::Timeout),
        }
    }

    /// One request/response round trip, without the timeout wrapper.
    async fn send(&self, query: &[u8]) -> Result<Vec<u8>> {
        let response = match self.method {
            DohMethod::Get => {
                // RFC 8484 §4.1: the query travels base64url-encoded in `dns`,
                // and the rest of the URL — path *and* any query it already
                // carried — stays intact.
                let encoded = URL_SAFE_NO_PAD.encode(query);
                let separator = if self.url.query().is_some() { '&' } else { '?' };
                let target = format!("{}{separator}dns={encoded}", self.url);
                crate::http::get_with_headers(&target, self.headers.clone()).await
            }
            DohMethod::Post => {
                crate::http::post_with_headers(
                    self.url.as_str(),
                    query.to_vec(),
                    "application/dns-message",
                    self.headers.clone(),
                )
                .await
            }
        };

        match response {
            Ok(exchange) => Ok(exchange.into_body()),
            Err(error) => Err(DnsError::Http(error.to_string())),
        }
    }

    /// Parse DNS response
    fn parse_response(&self, response: &[u8]) -> Result<Vec<IpAddr>> {
        let message = Message::from_bytes(response)
            .map_err(|e| DnsError::Protocol(format!("Failed to parse DNS response: {}", e)))?;

        let mut ips = Vec::new();

        for answer in &message.answers {
            match &answer.data {
                RData::A(a) => ips.push(IpAddr::V4(a.0)),
                RData::AAAA(aaaa) => ips.push(IpAddr::V6(aaaa.0)),
                _ => {}
            }
        }

        trace!("DoH response: {} addresses", ips.len());
        Ok(ips)
    }

    /// Get the DoH server URL
    pub fn url(&self) -> &str {
        self.url.as_str()
    }
}

/// DoH resolver with multiple upstream servers and load balancing
pub struct DohResolver {
    /// DoH clients
    clients: Vec<DohClient>,
    /// Current client index (round-robin)
    current: Arc<RwLock<usize>>,
    /// Prefer IPv4 over IPv6
    prefer_ipv4: bool,
}

impl DohResolver {
    /// Create a new DoH resolver with multiple upstream servers
    pub fn new(urls: &[String]) -> Result<Self> {
        if urls.is_empty() {
            return Err(DnsError::Config("No DoH servers configured".to_string()));
        }

        let mut clients = Vec::new();
        for url in urls {
            match DohClient::new(url) {
                Ok(client) => {
                    debug!("DoH client created for {}", url);
                    clients.push(client);
                }
                Err(e) => {
                    warn!("Failed to create DoH client for {}: {}", url, e);
                }
            }
        }

        if clients.is_empty() {
            return Err(DnsError::Config(
                "No valid DoH servers configured".to_string(),
            ));
        }

        Ok(Self {
            clients,
            current: Arc::new(RwLock::new(0)),
            prefer_ipv4: true,
        })
    }

    /// Create with custom configuration for each server
    pub fn with_configs(configs: Vec<DohClientConfig>) -> Result<Self> {
        if configs.is_empty() {
            return Err(DnsError::Config("No DoH servers configured".to_string()));
        }

        let mut clients = Vec::new();
        for config in configs {
            match DohClient::with_config(config.clone()) {
                Ok(client) => {
                    debug!("DoH client created for {}", config.url);
                    clients.push(client);
                }
                Err(e) => {
                    warn!("Failed to create DoH client for {}: {}", config.url, e);
                }
            }
        }

        if clients.is_empty() {
            return Err(DnsError::Config(
                "No valid DoH servers configured".to_string(),
            ));
        }

        Ok(Self {
            clients,
            current: Arc::new(RwLock::new(0)),
            prefer_ipv4: true,
        })
    }

    /// Set IPv4 preference
    pub fn set_prefer_ipv4(&mut self, prefer: bool) {
        self.prefer_ipv4 = prefer;
    }

    /// Resolve a domain name using round-robin load balancing
    pub async fn resolve(&self, domain: &str) -> Result<Vec<IpAddr>> {
        let mut last_error = None;

        // Try each client in round-robin fashion
        for _ in 0..self.clients.len() {
            let idx = {
                let mut current = self.current.write().await;
                let idx = *current;
                *current = (*current + 1) % self.clients.len();
                idx
            };

            let client = &self.clients[idx];

            match client.resolve(domain).await {
                Ok(mut ips) if !ips.is_empty() => {
                    // Sort by preference
                    if self.prefer_ipv4 {
                        ips.sort_by_key(|ip| match ip {
                            IpAddr::V4(_) => 0,
                            IpAddr::V6(_) => 1,
                        });
                    }
                    debug!("DoH resolved {} to {:?} via {}", domain, ips, client.url());
                    return Ok(ips);
                }
                Ok(_) => {
                    debug!(
                        "DoH returned empty result for {} via {}",
                        domain,
                        client.url()
                    );
                }
                Err(e) => {
                    debug!(
                        "DoH resolution failed for {} via {}: {}",
                        domain,
                        client.url(),
                        e
                    );
                    last_error = Some(e);
                }
            }
        }

        Err(last_error.unwrap_or_else(|| {
            DnsError::QueryFailed(format!("All DoH servers failed for {}", domain))
        }))
    }

    /// Query specific record type
    pub async fn query(&self, domain: &str, record_type: RecordType) -> Result<Vec<IpAddr>> {
        let mut last_error = None;

        for _ in 0..self.clients.len() {
            let idx = {
                let mut current = self.current.write().await;
                let idx = *current;
                *current = (*current + 1) % self.clients.len();
                idx
            };

            let client = &self.clients[idx];

            match client.query(domain, record_type).await {
                Ok(ips) if !ips.is_empty() => {
                    return Ok(ips);
                }
                Ok(_) => continue,
                Err(e) => {
                    last_error = Some(e);
                }
            }
        }

        Err(last_error.unwrap_or_else(|| {
            DnsError::QueryFailed(format!(
                "All DoH servers failed for {} {:?}",
                domain, record_type
            ))
        }))
    }

    /// Get number of configured servers
    pub fn server_count(&self) -> usize {
        self.clients.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_doh_client_creation() {
        let client = DohClient::new("https://dns.google/dns-query");
        assert!(client.is_ok());
    }

    #[tokio::test]
    async fn test_doh_invalid_url() {
        let client = DohClient::new("http://dns.google/dns-query");
        assert!(client.is_err()); // Must be HTTPS
    }

    #[test]
    fn get_requests_carry_the_query_parameter() {
        // The GET form is easy to break because the encoded query lives in the
        // URL rather than the body: build the exact target and check both the
        // parameter and the untouched path.
        let client = DohClient::with_config(DohClientConfig {
            url: "https://dns.example/dns-query?token=abc".to_string(),
            method: DohMethod::Get,
            ..Default::default()
        })
        .expect("client");

        let encoded = URL_SAFE_NO_PAD.encode(b"\x00\x01");
        let separator = if client.url.query().is_some() {
            '&'
        } else {
            '?'
        };
        let target = format!("{}{separator}dns={encoded}", client.url);
        assert_eq!(target, "https://dns.example/dns-query?token=abc&dns=AAE");
    }

    #[tokio::test]
    #[ignore] // Requires network
    async fn test_doh_resolve() {
        let client = DohClient::new("https://dns.google/dns-query").unwrap();
        let result = client.resolve("google.com").await;
        assert!(result.is_ok());
        assert!(!result.unwrap().is_empty());
    }
}
