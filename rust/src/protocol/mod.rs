pub mod address;
pub mod error;
pub mod h1_client;
pub mod h1_server;
pub mod http2;
pub mod io_shim;
pub mod quic_client;
pub mod sync_bridge;
pub mod transport;

#[cfg(feature = "tls")]
pub mod tls;

#[cfg(feature = "wireguard")]
pub mod wireguard;

pub use address::{Address, AddressType};
pub use error::{ProtocolError, Result};

pub mod prelude {
    pub use crate::protocol::address::{Address, AddressType};
    pub use crate::protocol::error::{ProtocolError, Result};

    pub use crate::protocol::quic_client::{
        CongestionControl, QuicClientTuning, QuicConnection, QuicRecv, QuicSend, QuicStream,
    };
    pub use crate::protocol::transport::{
        GrpcConfig, GrpcMode, GrpcStream, GrpcTransport, H2Config, H2Stream, H2Transport,
        TlsConfig, TlsFingerprint, TlsStream, TlsTransport, TransportError, WebSocketConfig,
        WebSocketTransport, WsStream,
    };

    #[cfg(feature = "tls")]
    pub use crate::protocol::tls::{TlsAcceptor, TlsConnector, TlsStream as TlsModuleStream};

    #[cfg(feature = "wireguard")]
    pub use crate::protocol::wireguard::{WireGuardError, WireGuardTunnel};
}
