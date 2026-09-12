//! Certificate verification utilities
//!
//! The verifier itself lives in [`crate::tls_policy`], so the `tls` feature and
//! the TLS transport cannot end up with two subtly different implementations.
//! It is re-exported here because that is the path callers already use.

pub use crate::tls_policy::SkipServerVerification;
