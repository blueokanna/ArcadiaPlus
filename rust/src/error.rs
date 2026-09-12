use flutter_rust_bridge::frb;
use std::fmt;

/// FFI error types
#[frb]
#[derive(Debug, Clone)]
pub enum VeloGuardError {
    Config(String),
    Network(String),
    Dns(String),
    Tls(String),
    Protocol(String),
    Io(String),
    Parse(String),
    Auth(String),
    Timeout(String),
    ResourceExhausted(String),
    Internal(String),
    Routing(String),
    Proxy(String),
}

impl fmt::Display for VeloGuardError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VeloGuardError::Config(msg) => write!(f, "Config error: {}", msg),
            VeloGuardError::Network(msg) => write!(f, "Network error: {}", msg),
            VeloGuardError::Dns(msg) => write!(f, "DNS error: {}", msg),
            VeloGuardError::Tls(msg) => write!(f, "TLS error: {}", msg),
            VeloGuardError::Protocol(msg) => write!(f, "Protocol error: {}", msg),
            VeloGuardError::Io(msg) => write!(f, "IO error: {}", msg),
            VeloGuardError::Parse(msg) => write!(f, "Parse error: {}", msg),
            VeloGuardError::Auth(msg) => write!(f, "Auth error: {}", msg),
            VeloGuardError::Timeout(msg) => write!(f, "Timeout error: {}", msg),
            VeloGuardError::ResourceExhausted(msg) => write!(f, "Resource exhausted: {}", msg),
            VeloGuardError::Internal(msg) => write!(f, "Internal error: {}", msg),
            VeloGuardError::Routing(msg) => write!(f, "Routing error: {}", msg),
            VeloGuardError::Proxy(msg) => write!(f, "Proxy error: {}", msg),
        }
    }
}

impl std::error::Error for VeloGuardError {}

impl From<crate::core::Error> for VeloGuardError {
    fn from(err: crate::core::Error) -> Self {
        match err {
            crate::core::Error::Config { message, .. } => VeloGuardError::Config(message),
            crate::core::Error::Network { message, .. } => VeloGuardError::Network(message),
            crate::core::Error::Dns { message, .. } => VeloGuardError::Dns(message),
            crate::core::Error::Tls { message, .. } => VeloGuardError::Tls(message),
            crate::core::Error::Protocol { message, .. } => VeloGuardError::Protocol(message),
            crate::core::Error::Io(err) => VeloGuardError::Io(err.to_string()),
            crate::core::Error::Parse { message, .. } => VeloGuardError::Parse(message),
            crate::core::Error::Auth { message, .. } => VeloGuardError::Auth(message),
            crate::core::Error::Timeout { message, .. } => VeloGuardError::Timeout(message),
            crate::core::Error::ResourceExhausted { message, .. } => {
                VeloGuardError::ResourceExhausted(message)
            }
            crate::core::Error::Internal { message, .. } => VeloGuardError::Internal(message),
            crate::core::Error::Routing { message, .. } => VeloGuardError::Routing(message),
            crate::core::Error::Proxy { message, .. } => VeloGuardError::Proxy(message),
        }
    }
}

/// FFI result type
pub type Result<T> = std::result::Result<T, VeloGuardError>;
