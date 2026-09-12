use thiserror::Error;

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("QUIC error: {0}")]
    Quic(String),

    #[error("TLS error: {0}")]
    Tls(String),

    #[error("WireGuard error: {0}")]
    WireGuard(String),

    #[error("TUIC error: {0}")]
    Tuic(String),

    #[error("Crypto error: {0}")]
    Crypto(String),

    #[error("Handshake error: {0}")]
    Handshake(String),

    #[error("Network error: {0}")]
    Network(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),

    #[error("Authentication failed")]
    AuthFailed,

    #[error("Protocol error: {0}")]
    Protocol(String),

    #[error("Connection closed")]
    ConnectionClosed,

    #[error("Timeout")]
    Timeout,

    #[error("Address parse error: {0}")]
    AddressParse(String),

    #[error("Unsupported address type: {0}")]
    UnsupportedAddressType(u8),

    #[error("Buffer too small")]
    BufferTooSmall,
}

pub type Result<T> = std::result::Result<T, ProtocolError>;

impl From<corduit::protocol::quic::QuicError> for ProtocolError {
    /// Keep the transport's classification instead of flattening everything
    /// into "QUIC error": "the certificate did not verify", "the peer closed
    /// the connection" and "the configuration asked for something impossible"
    /// send the user to three different places.
    fn from(error: corduit::protocol::quic::QuicError) -> Self {
        use corduit::protocol::quic::QuicError;

        match error {
            QuicError::Io(message) => {
                ProtocolError::Network(format!("QUIC socket error: {message}"))
            }
            QuicError::Tls(message) | QuicError::Certificate(message) => {
                ProtocolError::Tls(format!("QUIC handshake failed: {message}"))
            }
            QuicError::Timeout | QuicError::IdleTimeout => ProtocolError::Timeout,
            QuicError::InvalidConfig(message) => ProtocolError::InvalidConfig(message),
            QuicError::Closed | QuicError::ClosedByPeer { .. } | QuicError::StreamReset { .. } => {
                ProtocolError::ConnectionClosed
            }
            other => ProtocolError::Quic(other.to_string()),
        }
    }
}

impl From<rustls::Error> for ProtocolError {
    fn from(e: rustls::Error) -> Self {
        ProtocolError::Tls(e.to_string())
    }
}
