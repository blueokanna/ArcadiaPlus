//! RecurseX front-end: a stoppable UDP/TCP DNS service backed by
//! iterative (root-up) resolution.
//!
//! corduit's DNS layer forwards to upstream resolvers. When a VeloGuard
//! profile asks for local recursion instead, the resolver running here
//! answers from the root servers down, with RecurseX's semantic cache and
//! adaptive transport selection doing the heavy lifting. Point corduit's
//! `dns.nameservers` at the address this service reports and every
//! forwarded query becomes a recursive one.
//!
//! Lifecycle is explicit and bounded: [`start`] binds, [`stop`] signals
//! every worker and joins it, and both are safe to call repeatedly. The
//! resolver itself — along with its maintenance thread — is created once
//! per process, because the cache it owns is exactly the state that makes
//! recursion cheap.

use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use once_cell::sync::OnceCell;
use parking_lot::Mutex;
use recurse_x::{Message, Resolver, ResolverConfig};

use crate::types::RecursiveDnsStatus;

/// How long a worker blocks on `recv_from` before re-checking the stop flag.
const UDP_READ_TIMEOUT: Duration = Duration::from_millis(200);

/// Poll interval for non-blocking `accept` loops and TCP reads.
const TCP_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// Ceiling on in-flight queries. Beyond this the front-end drops datagrams
/// (UDP) or refuses connections (TCP) rather than spawning unboundedly.
const MAX_INFLIGHT: usize = 512;

/// Ceiling on concurrent TCP connections.
const MAX_TCP_CONNECTIONS: usize = 256;

/// The fallback UDP payload size when a query carries no EDNS OPT record
/// (RFC 1035 §4.2.1).
const DEFAULT_UDP_PAYLOAD: usize = 512;

static RESOLVER: OnceCell<Arc<Resolver>> = OnceCell::new();
static SERVICE: Mutex<Option<Service>> = Mutex::new(None);

struct Service {
    listen: String,
    stop: Arc<AtomicBool>,
    handles: Vec<JoinHandle<()>>,
}

/// The recursive resolver, created once per process.
fn resolver() -> Arc<Resolver> {
    RESOLVER
        .get_or_init(|| {
            let resolver = Arc::new(Resolver::new(ResolverConfig::default()));
            // Cache sweep + prefetch. The handle is detached: the thread
            // parks on the maintenance interval and exits with the process.
            let _ = resolver.spawn_maintenance();
            resolver
        })
        .clone()
}

/// Bind the front-end. Returns the address actually bound, which is what a
/// caller should hand to `dns.nameservers` (port `0` resolves to a free
/// port). Idempotent while running.
pub fn start(listen: &str) -> Result<String, String> {
    let mut slot = SERVICE.lock();
    if let Some(service) = slot.as_ref() {
        return Ok(service.listen.clone());
    }

    let requested = listen
        .to_socket_addrs()
        .map_err(|e| format!("invalid listen address '{listen}': {e}"))?
        .next()
        .ok_or_else(|| format!("listen address '{listen}' did not resolve"))?;

    let udp =
        UdpSocket::bind(requested).map_err(|e| format!("cannot bind UDP {requested}: {e}"))?;
    let bound = udp
        .local_addr()
        .map_err(|e| format!("cannot read the bound UDP address: {e}"))?;
    let tcp = TcpListener::bind(bound).map_err(|e| format!("cannot bind TCP {bound}: {e}"))?;

    configure(&udp, &tcp)?;

    let resolver = resolver();
    let stop = Arc::new(AtomicBool::new(false));
    let udp_inflight = Arc::new(AtomicUsize::new(0));
    let tcp_inflight = Arc::new(AtomicUsize::new(0));

    let mut handles = Vec::with_capacity(2);

    {
        let socket = Arc::new(udp);
        let resolver = resolver.clone();
        let stop = stop.clone();
        let inflight = udp_inflight.clone();
        handles.push(spawn("recursive-dns-udp", move || {
            serve_udp(socket, resolver, stop, inflight)
        })?);
    }

    {
        let resolver = resolver.clone();
        let stop = stop.clone();
        let inflight = tcp_inflight.clone();
        handles.push(spawn("recursive-dns-tcp", move || {
            serve_tcp_listener(tcp, resolver, stop, inflight)
        })?);
    }

    let bound = bound.to_string();
    *slot = Some(Service {
        listen: bound.clone(),
        stop,
        handles,
    });
    Ok(bound)
}

/// Signal every worker and wait for them to leave their loops. The bound
/// sockets close with the threads, so the port is free afterwards.
pub fn stop() -> Result<(), String> {
    let service = SERVICE.lock().take();
    let Some(service) = service else {
        return Ok(());
    };

    service.stop.store(true, Ordering::Relaxed);
    for handle in service.handles {
        handle
            .join()
            .map_err(|_| "recursive DNS worker panicked".to_string())?;
    }
    Ok(())
}

/// Whether the front-end is accepting queries, and where.
pub fn status() -> RecursiveDnsStatus {
    match SERVICE.lock().as_ref() {
        Some(service) => RecursiveDnsStatus {
            running: true,
            listen: Some(service.listen.clone()),
        },
        None => RecursiveDnsStatus {
            running: false,
            listen: None,
        },
    }
}

fn spawn<F>(name: &str, body: F) -> Result<JoinHandle<()>, String>
where
    F: FnOnce() + Send + 'static,
{
    thread::Builder::new()
        .name(name.to_string())
        .spawn(body)
        .map_err(|e| format!("cannot spawn {name}: {e}"))
}

fn configure(udp: &UdpSocket, tcp: &TcpListener) -> Result<(), String> {
    udp.set_read_timeout(Some(UDP_READ_TIMEOUT))
        .map_err(|e| format!("cannot arm the UDP read timeout: {e}"))?;
    tcp.set_nonblocking(true)
        .map_err(|e| format!("cannot switch the TCP listener to non-blocking: {e}"))
}

fn serve_udp(
    socket: Arc<UdpSocket>,
    resolver: Arc<Resolver>,
    stop: Arc<AtomicBool>,
    inflight: Arc<AtomicUsize>,
) {
    let mut buf = vec![0u8; u16::MAX as usize + 1];
    while !stop.load(Ordering::Relaxed) {
        let (len, peer) = match socket.recv_from(&mut buf) {
            Ok(received) => received,
            Err(e) if is_transient(&e) => continue,
            Err(_) => {
                thread::sleep(TCP_POLL_INTERVAL);
                continue;
            }
        };

        if inflight.load(Ordering::Relaxed) >= MAX_INFLIGHT {
            continue;
        }
        inflight.fetch_add(1, Ordering::Relaxed);

        let query = buf[..len].to_vec();
        let socket = socket.clone();
        let resolver = resolver.clone();
        let counter = inflight.clone();
        let spawned = thread::Builder::new()
            .name("recursive-dns-query".to_string())
            .spawn(move || {
                let limit = advertised_udp_payload(&query);
                let response = answer(&resolver, &query, Some(peer.ip()), Some(limit));
                let _ = socket.send_to(&response, peer);
                counter.fetch_sub(1, Ordering::Relaxed);
            });
        if spawned.is_err() {
            inflight.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

fn serve_tcp_listener(
    listener: TcpListener,
    resolver: Arc<Resolver>,
    stop: Arc<AtomicBool>,
    inflight: Arc<AtomicUsize>,
) {
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                if inflight.load(Ordering::Relaxed) >= MAX_TCP_CONNECTIONS {
                    drop(stream);
                    continue;
                }
                inflight.fetch_add(1, Ordering::Relaxed);

                let resolver = resolver.clone();
                let stop = stop.clone();
                let counter = inflight.clone();
                let spawned = thread::Builder::new()
                    .name("recursive-dns-connection".to_string())
                    .spawn(move || {
                        let _ = serve_connection(stream, resolver, stop);
                        counter.fetch_sub(1, Ordering::Relaxed);
                    });
                if spawned.is_err() {
                    inflight.fetch_sub(1, Ordering::Relaxed);
                }
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock => thread::sleep(TCP_POLL_INTERVAL),
            Err(_) => thread::sleep(TCP_POLL_INTERVAL),
        }
    }
}

/// Serve length-prefixed queries on one connection until the client leaves
/// or [`stop`] is raised.
fn serve_connection(
    mut stream: TcpStream,
    resolver: Arc<Resolver>,
    stop: Arc<AtomicBool>,
) -> std::io::Result<()> {
    stream.set_read_timeout(Some(TCP_POLL_INTERVAL))?;
    let client_ip = stream.peer_addr().ok().map(|peer| peer.ip());

    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }

        let mut len_buf = [0u8; 2];
        if !read_polling(&mut stream, &mut len_buf, &stop)? {
            return Ok(());
        }
        let len = u16::from_be_bytes(len_buf) as usize;
        if len == 0 {
            return Ok(());
        }

        let mut query = vec![0u8; len];
        if !read_polling(&mut stream, &mut query, &stop)? {
            return Ok(());
        }

        // TCP carries complete responses; the 16-bit frame length is the
        // only limit that applies.
        let response = answer(&resolver, &query, client_ip, None);
        let mut framed = Vec::with_capacity(response.len() + 2);
        framed.extend_from_slice(&(response.len() as u16).to_be_bytes());
        framed.extend_from_slice(&response);
        stream.write_all(&framed)?;
    }
}

/// Read `buf` fully, honouring the stop flag. `Ok(false)` means "stop now
/// or the peer closed", never a fatal condition.
fn read_polling(
    stream: &mut TcpStream,
    buf: &mut [u8],
    stop: &AtomicBool,
) -> std::io::Result<bool> {
    let mut filled = 0;
    while filled < buf.len() {
        if stop.load(Ordering::Relaxed) {
            return Ok(false);
        }
        match stream.read(&mut buf[filled..]) {
            Ok(0) => return Ok(false),
            Ok(n) => filled += n,
            Err(e) if is_transient(&e) => continue,
            Err(e)
                if e.kind() == ErrorKind::ConnectionReset
                    || e.kind() == ErrorKind::ConnectionAborted =>
            {
                return Ok(false)
            }
            Err(e) => return Err(e),
        }
    }
    Ok(true)
}

/// Frame a query through the resolver, degrading to FORMERR / SERVFAIL the
/// way RFC 1035 §4.1.1 expects when a query is unparseable or the engine
/// cannot produce an answer.
fn answer(
    resolver: &Resolver,
    query: &[u8],
    client_ip: Option<IpAddr>,
    udp_limit: Option<usize>,
) -> Vec<u8> {
    match Message::parse(query) {
        Ok(message) => {
            let mut response = resolver.handle_query(&message, client_ip);
            if let Some(limit) = udp_limit {
                response.truncate_for_udp(limit);
            }
            response.to_bytes().unwrap_or_else(|_| {
                message
                    .error_response(recurse_x::Rcode::SERVFAIL)
                    .to_bytes()
                    .unwrap_or_default()
            })
        }
        Err(_) => {
            let mut message = Message::new(0);
            message.flags.qr = true;
            message.flags.rcode = recurse_x::Rcode::FORMERR;
            message.to_bytes().unwrap_or_default()
        }
    }
}

/// The payload size the client advertised through EDNS, or the RFC 1035
/// default.
fn advertised_udp_payload(query: &[u8]) -> usize {
    Message::parse(query)
        .ok()
        .and_then(|message| message.edns.map(|edns| edns.udp_payload_size as usize))
        .unwrap_or(DEFAULT_UDP_PAYLOAD)
}

fn is_transient(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
    ) || is_connection_reset(error)
}

/// Windows reports ICMP port-unreachable on a connected UDP socket as
/// `ConnectionReset`; for a server socket that is an ordinary transient,
/// not a reason to abandon the receive loop.
fn is_connection_reset(error: &std::io::Error) -> bool {
    error.kind() == ErrorKind::ConnectionReset
}

// The front-end keeps process-wide state, so tests that touch it take this
// lock; cargo runs test functions in parallel otherwise.
#[cfg(test)]
mod tests {
    use super::*;

    /// Serialises the tests that bind or read the global front-end.
    static FRONT_END_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn lock_front_end() -> std::sync::MutexGuard<'static, ()> {
        FRONT_END_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn front_end_lifecycle() {
        let _guard = lock_front_end();

        let _ = stop();
        assert!(!status().running);

        let address = start("127.0.0.1:0").expect("loopback bind succeeds");
        assert!(
            address.starts_with("127.0.0.1:"),
            "unexpected bound address: {address}"
        );

        let snapshot = status();
        assert!(snapshot.running);
        assert_eq!(snapshot.listen.as_deref(), Some(address.as_str()));

        // Starting again while running reports the existing listener.
        assert_eq!(start("127.0.0.1:0").expect("idempotent start"), address);

        stop().expect("front-end stops");
        assert!(!status().running);
        assert_eq!(status().listen, None);

        // Stopping a stopped front-end is a no-op, not an error.
        stop().expect("second stop is a no-op");
    }

    #[test]
    fn unbindable_address_is_rejected() {
        let _guard = lock_front_end();

        let _ = stop();
        // TEST-NET-3 is not assigned to any local interface, so the bind
        // cannot succeed here.
        assert!(start("203.0.113.1:0").is_err());
        assert!(!status().running);
    }

    #[test]
    fn transient_errors_include_connection_reset() {
        assert!(is_transient(&std::io::Error::from(ErrorKind::WouldBlock)));
        assert!(is_transient(&std::io::Error::from(ErrorKind::TimedOut)));
        assert!(is_transient(&std::io::Error::from(
            ErrorKind::ConnectionReset
        )));
        assert!(!is_transient(&std::io::Error::from(ErrorKind::AddrInUse)));
    }
}
