//! DNS client for upstream queries

use crate::dns::config::{UpstreamConfig, UpstreamProtocol};
use crate::dns::error::{DnsError, Result};

use hickory_proto::op::{Message, MessageType, OpCode, Query};
use hickory_proto::rr::{Name, RecordType};
use hickory_proto::serialize::binary::{BinDecodable, BinEncodable};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpStream, UdpSocket};
use tokio::time::timeout;
use tracing::debug;

/// DNS protocol type
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DnsProtocol {
    Udp,
    Tcp,
    DoT,
    DoH,
    DoQ,
}

/// DNS client for querying upstream servers
pub struct DnsClient {
    /// Upstream configuration
    config: UpstreamConfig,
    /// Query timeout
    timeout: Duration,
    /// TLS connector for DoT/DoH
    tls_connector: Option<Arc<tokio_rustls::TlsConnector>>,
}

impl DnsClient {
    /// Create a new DNS client
    pub fn new(config: UpstreamConfig, timeout: Duration) -> Result<Self> {
        let tls_connector = if matches!(
            config.protocol,
            UpstreamProtocol::DoT | UpstreamProtocol::DoH
        ) {
            Some(Arc::new(crate::tls_policy::client_connector(&[], false)))
        } else {
            None
        };

        Ok(Self {
            config,
            timeout,
            tls_connector,
        })
    }

    /// Query DNS
    pub async fn query(&self, name: &str, record_type: RecordType) -> Result<Message> {
        let message = self.build_query(name, record_type)?;

        match self.config.protocol {
            UpstreamProtocol::Udp => self.query_udp(&message).await,
            UpstreamProtocol::Tcp => self.query_tcp(&message).await,
            UpstreamProtocol::DoT => self.query_dot(&message).await,
            UpstreamProtocol::DoH => self.query_doh(&message).await,
            UpstreamProtocol::DoQ => {
                // DoQ not implemented yet
                Err(DnsError::NotImplemented)
            }
        }
    }

    /// Build DNS query message
    fn build_query(&self, name: &str, record_type: RecordType) -> Result<Message> {
        let name = Name::from_ascii(name)
            .map_err(|e| DnsError::NameError(format!("Invalid domain name: {}", e)))?;

        let mut message = Message::new(
            crate::crypto::random_u16(),
            MessageType::Query,
            OpCode::Query,
        );
        message.metadata.recursion_desired = true;

        let query = Query::query(name, record_type);
        message.add_query(query);

        Ok(message)
    }

    /// Query via UDP
    async fn query_udp(&self, message: &Message) -> Result<Message> {
        let addr = self.resolve_address().await?;
        let socket = UdpSocket::bind("0.0.0.0:0").await?;

        let data = message
            .to_bytes()
            .map_err(|e| DnsError::Protocol(e.to_string()))?;

        socket.send_to(&data, addr).await?;

        let mut buf = vec![0u8; 4096];
        let result = timeout(self.timeout, socket.recv_from(&mut buf)).await;

        match result {
            Ok(Ok((len, _))) => {
                let response = Message::from_bytes(&buf[..len])
                    .map_err(|e| DnsError::Protocol(e.to_string()))?;
                Ok(response)
            }
            Ok(Err(e)) => Err(DnsError::Io(e)),
            Err(_) => Err(DnsError::Timeout),
        }
    }

    /// Query via TCP
    async fn query_tcp(&self, message: &Message) -> Result<Message> {
        let addr = self.resolve_address().await?;
        let mut stream = timeout(self.timeout, TcpStream::connect(addr))
            .await
            .map_err(|_| DnsError::Timeout)??;

        let data = message
            .to_bytes()
            .map_err(|e| DnsError::Protocol(e.to_string()))?;

        // TCP DNS uses 2-byte length prefix
        let len = (data.len() as u16).to_be_bytes();
        stream.write_all(&len).await?;
        stream.write_all(&data).await?;

        // Read response length
        let mut len_buf = [0u8; 2];
        timeout(self.timeout, stream.read_exact(&mut len_buf))
            .await
            .map_err(|_| DnsError::Timeout)??;
        let len = u16::from_be_bytes(len_buf) as usize;

        // Read response
        let mut buf = vec![0u8; len];
        timeout(self.timeout, stream.read_exact(&mut buf))
            .await
            .map_err(|_| DnsError::Timeout)??;

        let response = Message::from_bytes(&buf).map_err(|e| DnsError::Protocol(e.to_string()))?;
        Ok(response)
    }

    /// Query via DNS over TLS (DoT)
    async fn query_dot(&self, message: &Message) -> Result<Message> {
        let addr = self.resolve_address().await?;
        let connector = self
            .tls_connector
            .as_ref()
            .ok_or(DnsError::Tls("TLS connector not initialized".to_string()))?;

        let server_name = self
            .config
            .server_name
            .as_ref()
            .ok_or(DnsError::Config("Server name required for DoT".to_string()))?;

        let server_name = rustls::pki_types::ServerName::try_from(server_name.as_str())
            .map_err(|e| DnsError::Tls(format!("Invalid server name: {}", e)))?
            .to_owned();

        let tcp_stream = timeout(self.timeout, TcpStream::connect(addr))
            .await
            .map_err(|_| DnsError::Timeout)??;

        let mut tls_stream = timeout(self.timeout, connector.connect(server_name, tcp_stream))
            .await
            .map_err(|_| DnsError::Timeout)?
            .map_err(|e| DnsError::Tls(e.to_string()))?;

        let data = message
            .to_bytes()
            .map_err(|e| DnsError::Protocol(e.to_string()))?;

        // TCP DNS uses 2-byte length prefix
        let len = (data.len() as u16).to_be_bytes();
        tls_stream.write_all(&len).await?;
        tls_stream.write_all(&data).await?;

        // Read response length
        let mut len_buf = [0u8; 2];
        timeout(self.timeout, tls_stream.read_exact(&mut len_buf))
            .await
            .map_err(|_| DnsError::Timeout)??;
        let len = u16::from_be_bytes(len_buf) as usize;

        // Read response
        let mut buf = vec![0u8; len];
        timeout(self.timeout, tls_stream.read_exact(&mut buf))
            .await
            .map_err(|_| DnsError::Timeout)??;

        let response = Message::from_bytes(&buf).map_err(|e| DnsError::Protocol(e.to_string()))?;
        Ok(response)
    }

    /// Query via DNS over HTTPS (DoH)
    ///
    /// Delegates to [`crate::dns::doh::DohClient`] rather than opening a TLS
    /// connection of its own: DoH is one protocol with one implementation here,
    /// and that implementation shares the process-wide HTTP door
    /// ([`crate::http`]) with every other fetch — one trust store, one set of
    /// timeouts, one body ceiling.
    async fn query_doh(&self, message: &Message) -> Result<Message> {
        let data = message
            .to_bytes()
            .map_err(|e| DnsError::Protocol(e.to_string()))?;

        let client = crate::dns::doh::DohClient::with_config(crate::dns::doh::DohClientConfig {
            url: self.doh_url(),
            method: crate::dns::doh::DohMethod::Post,
            timeout: self.timeout,
            headers: Vec::new(),
        })?;

        debug!("DoH query to {}", client.url());

        let response = client.exchange(&data).await?;
        Message::from_bytes(&response).map_err(|e| DnsError::Protocol(e.to_string()))
    }

    /// The URL this upstream's DoH endpoint lives at.
    fn doh_url(&self) -> String {
        let host = &self.config.address;
        let path = self.config.path.as_deref().unwrap_or("/dns-query");
        match self.config.port.unwrap_or(443) {
            443 => format!("https://{host}{path}"),
            port => format!("https://{host}:{port}{path}"),
        }
    }

    /// Resolve upstream server address
    async fn resolve_address(&self) -> Result<SocketAddr> {
        // If we have a direct socket address, use it
        if let Some(addr) = self.config.socket_addr() {
            return Ok(addr);
        }

        // Otherwise, we need to resolve the hostname
        // This is a bootstrap problem - we use system DNS for this
        let port = self.config.port.unwrap_or(match self.config.protocol {
            UpstreamProtocol::Udp | UpstreamProtocol::Tcp => 53,
            UpstreamProtocol::DoT | UpstreamProtocol::DoQ => 853,
            UpstreamProtocol::DoH => 443,
        });

        // Use tokio's built-in DNS resolution (system resolver)
        let addrs: Vec<SocketAddr> =
            tokio::net::lookup_host(format!("{}:{}", self.config.address, port))
                .await?
                .collect();

        addrs.into_iter().next().ok_or(DnsError::QueryFailed(
            "Failed to resolve upstream DNS server".to_string(),
        ))
    }

    /// Get protocol type
    pub fn protocol(&self) -> DnsProtocol {
        match self.config.protocol {
            UpstreamProtocol::Udp => DnsProtocol::Udp,
            UpstreamProtocol::Tcp => DnsProtocol::Tcp,
            UpstreamProtocol::DoT => DnsProtocol::DoT,
            UpstreamProtocol::DoH => DnsProtocol::DoH,
            UpstreamProtocol::DoQ => DnsProtocol::DoQ,
        }
    }

    /// Get server address
    pub fn address(&self) -> &str {
        &self.config.address
    }
}

/// Create DNS clients from configuration strings
pub fn create_clients(servers: &[String], timeout: Duration) -> Vec<DnsClient> {
    servers
        .iter()
        .filter_map(|s| {
            UpstreamConfig::parse(s).and_then(|config| DnsClient::new(config, timeout).ok())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore = "requires outbound UDP access to a public DNS resolver"]
    async fn test_udp_query() {
        let config = UpstreamConfig::parse("8.8.8.8").unwrap();
        let client = DnsClient::new(config, Duration::from_secs(5)).unwrap();

        let result = client.query("google.com", RecordType::A).await;
        assert!(result.is_ok());

        let response = result.unwrap();
        assert!(!response.answers.is_empty());
    }
}
