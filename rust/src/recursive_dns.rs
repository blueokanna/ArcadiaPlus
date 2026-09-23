//! RecurseX front-end: a stoppable UDP/TCP DNS service backed by
//! iterative (root-up) resolution.
//!
//! corduit's DNS layer forwards to upstream resolvers. When an ArcadiaPlus
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
//!
//! # Idle cost
//!
//! The front-end is meant to be affordable to leave running, which on a
//! phone is a hard requirement rather than a nicety: a worker that polls
//! its socket on a short timer keeps the CPU out of its deep sleep states
//! for as long as the app lives, and the heat that comes with it is
//! spent discovering that nothing had arrived. Both listeners therefore
//! block indefinitely and [`stop`] wakes them explicitly (a datagram for
//! UDP, a loopback connect for TCP, `shutdown` for sessions in flight).
//! When the front-end is idle it costs nothing; callers are still expected
//! to stop it when the proxy it serves is down, since a resolver nobody
//! queries should not exist at all.

use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{
    IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket,
};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use once_cell::sync::OnceCell;
use parking_lot::Mutex;
use recurse_x::{Message, Resolver, ResolverConfig};

use crate::types::RecursiveDnsStatus;

/// Safety net for the UDP receive loop. The loop blocks for as long as it
/// takes for a query to arrive and is woken by [`stop`]; this timeout only
/// bounds how long a lost wake-up could strand the worker, so it is measured
/// in whole seconds rather than milliseconds.
const UDP_READ_TIMEOUT: Duration = Duration::from_secs(1);

/// How long a TCP session may stay silent before its worker gives up.
const TCP_IDLE_TIMEOUT: Duration = Duration::from_secs(10);

/// Timeout for a single wake-up connect attempt. Loopback handshakes complete
/// in microseconds, so this only has to outlast a scheduling hiccup.
const WAKE_CONNECT_TIMEOUT: Duration = Duration::from_millis(50);

/// Total time [`stop`] may spend trying to release the accept loop.
const WAKE_BUDGET: Duration = Duration::from_secs(2);

/// Pause after an `accept` error that is not the stop flag, so a hard failure
/// (descriptor exhaustion, …) cannot turn the loop into a spin.
const ACCEPT_ERROR_BACKOFF: Duration = Duration::from_millis(250);

/// Ceiling on in-flight queries. Beyond this the front-end drops datagrams
/// (UDP) or refuses connections (TCP) rather than spawning unboundedly.
const MAX_INFLIGHT: usize = 512;

/// Ceiling on concurrent TCP connections.
const MAX_TCP_CONNECTIONS: usize = 256;

/// The fallback UDP payload size when a query carries no EDNS OPT record
/// (RFC 1035 §4.2.1).
const DEFAULT_UDP_PAYLOAD: usize = 512;

/// Ceiling on the payload a UDP client can talk the front-end into emitting,
/// whatever it advertises through EDNS0.
const MAX_UDP_PAYLOAD: usize = 4096;

static RESOLVER: OnceCell<Arc<Resolver>> = OnceCell::new();
static SERVICE: Mutex<Option<Service>> = Mutex::new(None);

/// Live TCP sessions, keyed by an id, so [`stop`] can end a session that is
/// parked in a blocking read. A thread sitting in `read` never observes the
/// stop flag on its own; `shutdown` is what releases it.
type ConnectionRegistry = Arc<Mutex<HashMap<u64, TcpStream>>>;

/// Source of the ids in [`ConnectionRegistry`].
static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

struct Service {
    listen: String,
    bound: SocketAddr,
    stop: Arc<AtomicBool>,
    connections: ConnectionRegistry,
    udp_worker: JoinHandle<()>,
    tcp_acceptor: JoinHandle<()>,
}

/// The recursive resolver, created once per process.
fn resolver() -> Arc<Resolver> {
    RESOLVER
        .get_or_init(|| {
            let resolver = Arc::new(Resolver::new(ResolverConfig::default()));
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
    let connections: ConnectionRegistry = Arc::new(Mutex::new(HashMap::new()));

    let udp_worker = {
        let socket = Arc::new(udp);
        let resolver = resolver.clone();
        let stop = stop.clone();
        let inflight = udp_inflight.clone();
        spawn("recursive-dns-udp", move || {
            serve_udp(socket, resolver, stop, inflight)
        })?
    };

    let tcp_acceptor = {
        let resolver = resolver.clone();
        let stop = stop.clone();
        let inflight = tcp_inflight.clone();
        let connections = connections.clone();
        spawn("recursive-dns-tcp", move || {
            serve_tcp_listener(tcp, resolver, stop, inflight, connections)
        })?
    };

    let listen = bound.to_string();
    *slot = Some(Service {
        listen: listen.clone(),
        bound,
        stop,
        connections,
        udp_worker,
        tcp_acceptor,
    });
    Ok(listen)
}

/// Signal every worker and wait for them to leave their loops. The bound
/// sockets close with the threads, so the port is free afterwards.
///
/// Both listeners block rather than poll (see [`configure`]), so stopping is
/// an active operation: the flag alone would leave the UDP worker parked in
/// `recv_from` and the TCP worker parked in `accept` until a real client
/// happened to arrive — which, on an idle phone, may be never. A one-byte
/// datagram and a loopback connect are what release them, and `shutdown`
/// does the same for any session already in progress.
pub fn stop() -> Result<(), String> {
    let service = SERVICE.lock().take();
    let Some(service) = service else {
        return Ok(());
    };

    service.stop.store(true, Ordering::Relaxed);

    let wake = wake_target(service.bound);
    wake_udp(&wake);
    wake_tcp(&wake, &service.tcp_acceptor);

    {
        let mut live = service.connections.lock();
        for (_, stream) in live.drain() {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
    }

    for handle in [service.udp_worker, service.tcp_acceptor] {
        handle
            .join()
            .map_err(|_| "recursive DNS worker panicked".to_string())?;
    }
    Ok(())
}

/// The address to aim a wake-up at. A listener bound to a wildcard address
/// does not accept packets addressed to the wildcard, so it is aimed at the
/// loopback of the same family instead.
fn wake_target(bound: SocketAddr) -> SocketAddr {
    match bound.ip() {
        IpAddr::V4(ip) if ip.is_unspecified() => {
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), bound.port())
        }
        IpAddr::V6(ip) if ip.is_unspecified() => {
            SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), bound.port())
        }
        _ => bound,
    }
}

/// Hand the UDP worker one datagram so it re-reads the stop flag. The worker
/// discards it: the flag is already set by the time the packet lands.
fn wake_udp(target: &SocketAddr) {
    let bind: SocketAddr = if target.is_ipv4() {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)
    } else {
        SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0)
    };
    let Ok(socket) = UdpSocket::bind(bind) else {
        return;
    };
    let _ = socket.send_to(&[0u8], target);
}

/// Hand the TCP worker one connection so its blocking `accept` returns.
///
/// A connect is only useful while the worker is actually parked in `accept`.
/// Once it has left — which happens whenever it lost the race to the stop
/// flag and exited at the top of its loop — connecting is not merely useless:
/// a closed loopback port is not refused on every platform, so each attempt
/// would burn its whole timeout. Asking the handle first keeps the pointless
/// case off the critical path, and the loop exits as soon as the worker is
/// gone for good.
///
/// The budget bounds the total wait, so a worker that somehow keeps failing to
/// take the hint cannot turn "stop" into a hang; `join` afterwards decides
/// whether that mattered.
fn wake_tcp(target: &SocketAddr, acceptor: &JoinHandle<()>) {
    let deadline = Instant::now() + WAKE_BUDGET;

    while Instant::now() < deadline {
        if acceptor.is_finished() {
            return;
        }
        if TcpStream::connect_timeout(target, WAKE_CONNECT_TIMEOUT).is_ok() {
            return;
        }
        thread::sleep(Duration::from_millis(5));
    }
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

/// Put both listeners into blocking mode.
///
/// This is the difference between a resolver that costs nothing while idle
/// and one that keeps the CPU waking up for the whole life of the app: a
/// short poll interval here would burn tens of wake-ups a second (and the
/// power state that goes with them) to discover that nothing had arrived.
/// [`stop`] supplies the wake-up that polling used to provide.
fn configure(udp: &UdpSocket, tcp: &TcpListener) -> Result<(), String> {
    udp.set_read_timeout(Some(UDP_READ_TIMEOUT))
        .map_err(|e| format!("cannot arm the UDP read timeout: {e}"))?;
    tcp.set_nonblocking(false)
        .map_err(|e| format!("cannot switch the TCP listener back to blocking: {e}"))?;
    Ok(())
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
            Err(_) => break,
        };

        if stop.load(Ordering::Relaxed) {
            break;
        }

        if len == 0 || inflight.load(Ordering::Relaxed) >= MAX_INFLIGHT {
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
                let response = answer(&resolver, &query, Some(peer.ip()), Transport::Udp);
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
    connections: ConnectionRegistry,
) {
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                if stop.load(Ordering::Relaxed) {
                    drop(stream);
                    break;
                }

                if inflight.load(Ordering::Relaxed) >= MAX_TCP_CONNECTIONS {
                    drop(stream);
                    continue;
                }
                inflight.fetch_add(1, Ordering::Relaxed);

                let id = NEXT_CONNECTION_ID.fetch_add(1, Ordering::Relaxed);
                if let Ok(handle) = stream.try_clone() {
                    connections.lock().insert(id, handle);
                }

                let resolver = resolver.clone();
                let stop = stop.clone();
                let counter = inflight.clone();
                let registry = connections.clone();
                let spawned = thread::Builder::new()
                    .name("recursive-dns-connection".to_string())
                    .spawn(move || {
                        let _ = serve_connection(stream, resolver, stop);
                        registry.lock().remove(&id);
                        counter.fetch_sub(1, Ordering::Relaxed);
                    });
                if spawned.is_err() {
                    connections.lock().remove(&id);
                    inflight.fetch_sub(1, Ordering::Relaxed);
                }
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => {
                if stop.load(Ordering::Relaxed) {
                    break;
                }
                thread::sleep(ACCEPT_ERROR_BACKOFF);
            }
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
    stream.set_read_timeout(Some(TCP_IDLE_TIMEOUT))?;
    let client_ip = stream.peer_addr().ok().map(|peer| peer.ip());

    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }

        let mut len_buf = [0u8; 2];
        if !read_exact(&mut stream, &mut len_buf)? {
            return Ok(());
        }
        let len = u16::from_be_bytes(len_buf) as usize;
        if len == 0 {
            return Ok(());
        }

        let mut query = vec![0u8; len];
        if !read_exact(&mut stream, &mut query)? {
            return Ok(());
        }
        let response = answer(&resolver, &query, client_ip, Transport::Tcp);
        let mut framed = Vec::with_capacity(response.len() + 2);
        framed.extend_from_slice(&(response.len() as u16).to_be_bytes());
        framed.extend_from_slice(&response);
        stream.write_all(&framed)?;
    }
}

/// Read `buf` fully. `Ok(false)` means "the peer went away, or the read was
/// ended for us", never a fatal condition.
///
/// There is deliberately no stop-flag check inside the loop: a thread parked
/// in a blocking read cannot observe one. The way a live session is ended is
/// `TcpStream::shutdown` from [`stop`], which makes the read return 0 and
/// this function report `false`.
fn read_exact(stream: &mut TcpStream, buf: &mut [u8]) -> std::io::Result<bool> {
    let mut filled = 0;
    while filled < buf.len() {
        match stream.read(&mut buf[filled..]) {
            Ok(0) => return Ok(false),
            Ok(n) => filled += n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::TimedOut => {
                return Ok(false)
            }
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

/// Which transport delivered a query: only UDP responses have to fit the
/// size the client advertised.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Transport {
    Udp,
    Tcp,
}

/// Frame a query through the resolver, degrading to FORMERR / SERVFAIL the
/// way RFC 1035 §4.1.1 expects when a query is unparseable or the engine
/// cannot produce an answer.
fn answer(
    resolver: &Resolver,
    query: &[u8],
    client_ip: Option<IpAddr>,
    transport: Transport,
) -> Vec<u8> {
    let Ok(message) = Message::parse(query) else {
        return formerr(query);
    };

    let mut response = resolver.handle_query(&message, client_ip);
    if transport == Transport::Udp {
        let limit = clamp_udp_payload(message.edns.as_ref().map(|edns| edns.udp_payload_size));
        response.truncate_for_udp(limit);
    }

    response.to_bytes().unwrap_or_else(|_| {
        message
            .error_response(recurse_x::Rcode::SERVFAIL)
            .to_bytes()
            .unwrap_or_default()
    })
}

/// The response size the client actually accepts: its EDNS0 advertisement,
/// clamped to what a resolver should ever emit over UDP. A client asking for
/// less than the RFC 1035 minimum gets the minimum.
fn clamp_udp_payload(advertised: Option<u16>) -> usize {
    advertised
        .map(usize::from)
        .unwrap_or(DEFAULT_UDP_PAYLOAD)
        .clamp(DEFAULT_UDP_PAYLOAD, MAX_UDP_PAYLOAD)
}

/// FORMERR for a query that cannot be parsed. The header ID is copied from
/// the raw bytes: even a malformed query carries one, and a client drops an
/// answer whose ID does not match the question it sent.
fn formerr(query: &[u8]) -> Vec<u8> {
    let id = if query.len() >= 2 {
        u16::from_be_bytes([query[0], query[1]])
    } else {
        0
    };

    let mut message = Message::new(id);
    message.flags.qr = true;
    message.flags.rcode = recurse_x::Rcode::FORMERR;
    message.to_bytes().unwrap_or_default()
}

/// Transient receive errors on the UDP worker. `TimedOut` is in the list
/// because the socket carries a one-second read timeout purely so the loop
/// re-reads the stop flag once a second; it is a normal, expected outcome of
/// an idle resolver, not a failure.
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

    /// Guards the blocking-listener design against a regression back to
    /// polling. The bound is generous — a poll interval healthy for the CPU
    /// would still sit far below it — but a loop that has to wait out a
    /// timeout before it notices the stop flag cannot pass.
    #[test]
    fn stop_does_not_wait_for_a_query() {
        let _guard = lock_front_end();

        let _ = stop();
        let _ = start("127.0.0.1:0").expect("loopback bind succeeds");

        let began = std::time::Instant::now();
        stop().expect("an idle front-end stops immediately");
        let elapsed = began.elapsed();

        assert!(
            elapsed < Duration::from_millis(500),
            "stop() took {elapsed:?}; an idle front-end must not wait for traffic"
        );
        assert!(!status().running);
    }

    #[test]
    fn wake_target_avoids_wildcard_addresses() {
        let specific: SocketAddr = "127.0.0.1:5335".parse().expect("valid address");
        assert_eq!(wake_target(specific), specific);
        let v4: SocketAddr = "0.0.0.0:5335".parse().expect("valid address");
        assert_eq!(
            wake_target(v4),
            "127.0.0.1:5335"
                .parse::<SocketAddr>()
                .expect("valid address")
        );

        let v6: SocketAddr = "[::]:5335".parse().expect("valid address");
        assert_eq!(
            wake_target(v6),
            "[::1]:5335".parse::<SocketAddr>().expect("valid address")
        );
    }

    #[test]
    fn response_size_follows_the_advertised_payload() {
        assert_eq!(clamp_udp_payload(None), DEFAULT_UDP_PAYLOAD);
        assert_eq!(clamp_udp_payload(Some(0)), DEFAULT_UDP_PAYLOAD);
        assert_eq!(clamp_udp_payload(Some(1232)), 1232);
        assert_eq!(clamp_udp_payload(Some(u16::MAX)), MAX_UDP_PAYLOAD);
    }

    #[test]
    fn formerr_echoes_the_query_id() {
        let response = formerr(&[0xAB, 0xCD, 0x01, 0x00]);
        let mut expected = Message::new(0xABCD);
        expected.flags.qr = true;
        expected.flags.rcode = recurse_x::Rcode::FORMERR;
        assert_eq!(response, expected.to_bytes().unwrap());

        // A datagram too short to carry an ID is still answered.
        assert!(!formerr(&[]).is_empty());
    }
}
