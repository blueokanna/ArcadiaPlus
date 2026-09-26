//! RecurseX front-end: a stoppable UDP/TCP DNS service backed by iterative
//! (root-up) resolution.
//!
//! corduit's DNS layer forwards to upstream resolvers. When an ArcadiaPlus
//! profile asks for local recursion instead, the resolver running here
//! answers from the root servers down, with RecurseX's semantic cache and
//! adaptive transport selection doing the heavy lifting. Point corduit's
//! `dns.nameservers` at the address this service reports and every forwarded
//! query becomes a recursive one.
//!
//! RecurseX ships the server half itself (`recurse_x::Server`), so this module
//! is the lifecycle around it rather than a second implementation of it. The
//! datagram queue, the handler pool, EDNS0 truncation with the TC bit, the
//! FORMERR / SERVFAIL fallbacks and the shutdown handshake all live upstream,
//! where they are tested. What is left here is the part upstream cannot know:
//! when the front-end is allowed to exist, and who is allowed to reach it.
//!
//! # Reachability
//!
//! [`start`] hands its address straight back to the caller, which passes it to
//! corduit as a nameserver. That one fact decides the whole policy: the
//! address has to be one the engine can dial, and one nobody else can. A
//! wildcard bind fails both tests — `0.0.0.0:port` is not a dialable
//! nameserver address, and a recursive resolver reachable from off-host is an
//! open resolver, i.e. a DNS amplification weapon rather than a feature.
//! Loopback is therefore the only bind this front-end accepts, and it says so
//! instead of binding something it cannot serve.
//!
//! # Idle cost
//!
//! Everything below the lifecycle blocks rather than polls: the receiver pool
//! parks in `recv_from`, the handlers park on their queue, the accept loop
//! parks in `accept`. An idle front-end costs no wake-ups at all, and [`stop`]
//! is what makes the workers move — a one-byte datagram for the receivers, a
//! self-connect for the accept loop, a flag plus a queue notification for
//! everything else.
//!
//! The resolver is created in [`start`] and torn down in [`stop`], so its
//! cache lasts exactly as long as one run of the proxy. That is deliberate:
//! its maintenance thread wakes ten times a second (a one-second interval
//! sliced into 100 ms sleeps so shutdown is noticed promptly), and an idle
//! phone must not pay that for a cache nobody is querying. The front-end is
//! started with the proxy and stopped with it, so the cache is warm exactly
//! while it is worth having.

use std::net::{SocketAddr, ToSocketAddrs};
use std::thread::JoinHandle;

use parking_lot::Mutex;
use recurse_x::cache::persist::PersistConfig;
use recurse_x::{Resolver, ResolverConfig, Server, ServerConfig};

use crate::types::RecursiveDnsStatus;

/// Concurrent TCP sessions.
///
/// Each session costs a thread, so this is a thread bound rather than a memory
/// bound. The crate default (1024) suits a server with a scheduler to spare;
/// on a phone it is a pool a single client could park with connections that
/// never send a query. RFC 7766 expects clients to be served over few
/// persistent connections, and the only client here is the engine, so 64 is
/// already generous.
const MAX_TCP_CONNECTIONS: usize = 64;

/// Datagrams allowed to wait for a handler.
///
/// A datagram may be up to 64 KiB on the wire, which makes the queue a memory
/// bound as well as a scheduling one: 256 slots cap what a flood can make this
/// service hold at 16 MiB, while staying far above the depth a real client can
/// build (a query is tens of bytes, and the handlers drain continuously).
const UDP_QUEUE: usize = 256;

/// How often the resolver snapshots its L3 cache to disk.
///
/// The snapshot only has to be recent, not perfect: it exists so a restart
/// resumes with hot answers instead of a cold delegation walk for every name
/// the user opens. Thirty seconds bounds what a crash can lose while keeping
/// the write rate far below what a phone notices.
const CACHE_SNAPSHOT_INTERVAL_MS: u64 = 30_000;

/// Front-end tuning, written as deviations from the crate default so that only
/// the numbers which are wrong for a phone appear here.
fn server_config() -> ServerConfig {
    ServerConfig {
        udp_queue: UDP_QUEUE,
        max_tcp_connections: MAX_TCP_CONNECTIONS,
        ..ServerConfig::default()
    }
}

static SERVICE: Mutex<Option<Service>> = Mutex::new(None);

/// One running front-end.
///
/// The resolver is held here as well as inside the server because [`stop`] has
/// to shut it down, and the maintenance handle because nothing else would ever
/// join that thread.
struct Service {
    bound: SocketAddr,
    server: Server,
    resolver: Resolver,
    maintenance: JoinHandle<()>,
}

impl Service {
    fn address(&self) -> String {
        self.bound.to_string()
    }
}

/// Bind the front-end. Returns the address actually bound, which is what a
/// caller should hand to `dns.nameservers` (port `0` resolves to a free
/// port). Idempotent while running.
///
/// `cache_path` turns on the persistent L3 tier: the resolver loads that file
/// at construction and snapshots to it on an interval, so a restart starts
/// with the answers the last run already learned instead of walking from the
/// roots for every name again. An empty or absent path keeps the cache in
/// memory only.
pub fn start(listen: &str, cache_path: Option<&str>) -> Result<String, String> {
    let mut slot = SERVICE.lock();
    if let Some(service) = slot.as_ref() {
        return Ok(service.address());
    }

    let requested = requested_address(listen)?;
    let mut config = ResolverConfig::default();
    if let Some(path) = cache_path.filter(|path| !path.is_empty()) {
        config.persist = Some(PersistConfig::new(path, CACHE_SNAPSHOT_INTERVAL_MS));
    }
    let resolver = Resolver::new(config);
    let server = Server::with_config(resolver.clone(), server_config());
    let bound = server
        .bind_udp(requested)
        .map_err(|error| format!("cannot bind UDP on {requested}: {error}"))?;
    if let Err(error) = server.bind_tcp(bound) {
        server.shutdown();
        server.join();
        return Err(format!("cannot bind TCP on {bound}: {error}"));
    }

    let maintenance = resolver.spawn_maintenance();
    let service = Service {
        bound,
        server,
        resolver,
        maintenance,
    };
    let address = service.address();
    *slot = Some(service);
    Ok(address)
}

/// Signal the server and the resolver to stop, then wait for their threads.
///
/// Ordered deliberately: the server goes first, so no query can reach the
/// resolver once it is shutting down. The wait is not instant — a handler
/// already inside a resolution finishes it rather than being killed mid-flight
/// — which is why this is reached through a blocking worker instead of the UI
/// isolate. Waiting is what makes the contract real: when this returns, the
/// ports are free and the threads are gone.
pub fn stop() -> Result<(), String> {
    let Some(service) = SERVICE.lock().take() else {
        return Ok(());
    };

    service.server.shutdown();
    service.server.join();
    service.resolver.shutdown();
    service
        .maintenance
        .join()
        .map_err(|_| "the recursive DNS maintenance thread panicked".to_string())
}

/// Names the canary tries, in order; one answer is enough.
///
/// Both are common, stable names whose authoritative servers answer worldwide.
/// A resolver that cannot resolve either of them is not usable from this
/// network, whatever the reason — and it must not be published to the engine
/// before that is discovered.
const CANARY_NAMES: [&str; 2] = ["www.qq.com", "www.baidu.com"];
/// Budget for one canary exchange. A cold recursive walk of a two-label name
/// fits easily; anything slower is a stall the engine would pay per lookup.
const CANARY_ATTEMPT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(4);

/// Bind the front-end and publish it only if it can actually resolve.
///
/// A recursive resolver can be *up* and still be useless: on networks that
/// poison or block the delegation walk, it binds, accepts queries and then
/// times out on every one of them. As the engine's first nameserver it would
/// put that timeout in front of every new connection before falling through
/// to the profile's own resolvers — the "local resolution is broken and the
/// whole app is slow" report this check exists to prevent. When the canary
/// fails, the front-end is stopped again and the caller keeps the profile's
/// resolvers as the answer.
pub fn start_checked(listen: &str, cache_path: Option<&str>) -> Result<String, String> {
    let address = start(listen, cache_path)?;
    match canary_resolution(&address) {
        Ok(()) => Ok(address),
        Err(error) => {
            let _ = stop();
            Err(format!(
                "the recursive resolver bound {address} but could not resolve a canary \
                 name ({error}); it was stopped so the profile's own resolvers answer instead"
            ))
        }
    }
}

/// Ask the just-bound front-end one real question.
fn canary_resolution(address: &str) -> Result<(), String> {
    let target: SocketAddr = address
        .parse()
        .map_err(|error| format!("the bound address '{address}' does not parse: {error}"))?;
    let bind = if target.is_ipv4() {
        "0.0.0.0:0"
    } else {
        "[::]:0"
    };
    let socket = std::net::UdpSocket::bind(bind)
        .map_err(|error| format!("the canary socket could not bind: {error}"))?;
    socket
        .set_read_timeout(Some(CANARY_ATTEMPT_TIMEOUT))
        .map_err(|error| format!("the canary socket has no timeout: {error}"))?;

    let mut last = String::new();
    for (index, name) in CANARY_NAMES.iter().enumerate() {
        let id = 0x5A00u16 + index as u16;
        let query = build_query(id, name)?;
        if let Err(error) = socket.send_to(&query, target) {
            last = format!("{name}: send failed: {error}");
            continue;
        }
        let mut response = [0u8; 1232];
        match socket.recv_from(&mut response) {
            Ok((len, _)) if validate_response(id, &response[..len]) => return Ok(()),
            Ok(_) => last = format!("{name}: the answer was empty or malformed"),
            Err(error) => last = format!("{name}: {error}"),
        }
    }
    Err(last)
}

/// A minimal `A` query — no EDNS, nothing to negotiate.
fn build_query(id: u16, name: &str) -> Result<Vec<u8>, String> {
    let mut packet = Vec::with_capacity(name.len() + 18);
    packet.extend_from_slice(&id.to_be_bytes());
    packet.extend_from_slice(&[0x01, 0x00]); // standard query, recursion desired
    packet.extend_from_slice(&[0, 1, 0, 0, 0, 0, 0, 0]);
    for label in name.split('.') {
        if label.is_empty() || label.len() > 63 {
            return Err(format!("canary name '{name}' is not a valid domain"));
        }
        packet.push(label.len() as u8);
        packet.extend_from_slice(label.as_bytes());
    }
    packet.push(0);
    packet.extend_from_slice(&[0, 1, 0, 1]); // type A, class IN
    Ok(packet)
}

/// Whether a response is an answer to *this* query: same id, a response, no
/// error code, at least one record.
fn validate_response(id: u16, packet: &[u8]) -> bool {
    if packet.len() < 12 {
        return false;
    }
    let response_id = u16::from_be_bytes([packet[0], packet[1]]);
    let is_response = packet[2] & 0x80 != 0;
    let rcode = packet[3] & 0x0F;
    let answers = u16::from_be_bytes([packet[6], packet[7]]);
    response_id == id && is_response && rcode == 0 && answers > 0
}

/// Whether the front-end is accepting queries, and where.
pub fn status() -> RecursiveDnsStatus {
    match SERVICE.lock().as_ref() {
        Some(service) => RecursiveDnsStatus {
            running: true,
            listen: Some(service.address()),
        },
        None => RecursiveDnsStatus {
            running: false,
            listen: None,
        },
    }
}

/// The address to bind, checked before any socket exists.
///
/// A wildcard bind is rejected for the same reason it would be useless: the
/// address this returns becomes a nameserver entry in the engine's config, and
/// neither `0.0.0.0:53` nor `[::]:53` is an address a client can dial. An
/// address on a real interface is rejected because a recursive resolver
/// answering remote clients is an open resolver — the amplification and
/// cache-poisoning surface every DNS hardening checklist is about. Sharing this
/// resolver with the LAN is a feature with its own access control if it is ever
/// wanted, not something a listen string should grant by accident.
fn requested_address(listen: &str) -> Result<SocketAddr, String> {
    let address = listen
        .to_socket_addrs()
        .map_err(|error| format!("invalid listen address '{listen}': {error}"))?
        .next()
        .ok_or_else(|| format!("listen address '{listen}' did not resolve"))?;

    if address.ip().is_loopback() {
        return Ok(address);
    }

    Err(format!(
        "refusing to bind {address}: the recursive resolver is published to the engine as a \
         nameserver, so it listens on loopback only - a reachable bind would hand out an open \
         recursive resolver"
    ))
}

// The front-end is process-wide state and cargo runs test functions in
// parallel, so the tests that bind or read it take this lock.
#[cfg(test)]
mod tests {
    use super::*;

    use std::io::{Read, Write};
    use std::net::{TcpStream, UdpSocket};
    use std::time::{Duration, Instant};

    /// Serialises the tests that touch the global front-end.
    static FRONT_END_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn lock_front_end() -> std::sync::MutexGuard<'static, ()> {
        FRONT_END_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    const MALFORMED_QUERY: [u8; 4] = [0xAB, 0xCD, 0x01, 0x00];

    fn client_timeout() -> Duration {
        Duration::from_secs(5)
    }

    #[test]
    fn front_end_lifecycle() {
        let _guard = lock_front_end();

        let _ = stop();
        assert!(!status().running);

        let address = start("127.0.0.1:0", None).expect("loopback bind succeeds");
        assert!(
            address.starts_with("127.0.0.1:"),
            "unexpected bound address: {address}"
        );
        assert!(
            !address.ends_with(":0"),
            "port 0 must come back resolved to a real port: {address}"
        );

        let snapshot = status();
        assert!(snapshot.running);
        assert_eq!(snapshot.listen.as_deref(), Some(address.as_str()));

        // Starting again while running reports the existing listener.
        assert_eq!(
            start("127.0.0.1:0", None).expect("idempotent start"),
            address
        );

        stop().expect("front-end stops");
        assert!(!status().running);
        assert_eq!(status().listen, None);

        // Stopping a stopped front-end is a no-op, not an error.
        stop().expect("second stop is a no-op");
    }

    #[test]
    fn only_loopback_may_be_reached() {
        let _guard = lock_front_end();

        let _ = stop();
        for refused in ["0.0.0.0:0", "[::]:0", "203.0.113.1:0"] {
            let error = start(refused, None).expect_err("a non-loopback bind must be refused");
            assert!(
                error.contains("loopback"),
                "the refusal for {refused} must say why: {error}"
            );
        }
        assert!(
            !status().running,
            "a refused bind must leave nothing running"
        );
    }

    #[test]
    fn unresolvable_listen_string_is_rejected() {
        let _guard = lock_front_end();

        let _ = stop();
        let error = start("not an address", None).expect_err("garbage must be refused");
        assert!(
            error.contains("invalid listen address"),
            "unexpected error: {error}"
        );
        assert!(!status().running);
    }

    /// The canary is what decides whether the front-end may be published to
    /// the engine; its query builder and answer check are pure and tested
    /// without a network.
    #[test]
    fn canary_queries_are_well_formed_and_answers_are_vetted() {
        let query = build_query(0x1234, "www.qq.com").expect("valid name");
        assert_eq!(&query[..2], &[0x12, 0x34], "id is carried");
        assert_eq!(query[2] & 0x80, 0, "a query must not have QR set");
        assert_eq!(query[3] & 0x0F, 0, "rcode is zero in a query");
        assert!(query.ends_with(&[0, 1, 0, 1]), "type A, class IN");
        assert!(build_query(1, "bad..name").is_err());
        assert!(build_query(1, &"a".repeat(64)).is_err());

        let mut response = query.clone();
        response[2] |= 0x80; // QR
        response[6] = 0;
        response[7] = 1; // one answer
        assert!(validate_response(0x1234, &response));
        assert!(!validate_response(0x1235, &response), "a foreign id");
        let mut nxdomain = response.clone();
        nxdomain[3] = 0x03;
        assert!(!validate_response(0x1234, &nxdomain), "an error code");
        let mut empty = response.clone();
        empty[7] = 0;
        assert!(!validate_response(0x1234, &empty), "no records");
        assert!(
            !validate_response(0x1234, &response[..8]),
            "truncated header"
        );
    }

    #[test]
    fn udp_answers_a_query_it_cannot_parse() {
        let _guard = lock_front_end();

        let _ = stop();
        let address = start("127.0.0.1:0", None).expect("loopback bind succeeds");

        let client = UdpSocket::bind("127.0.0.1:0").expect("client socket");
        client
            .set_read_timeout(Some(client_timeout()))
            .expect("timeout");
        client
            .send_to(&MALFORMED_QUERY, &address)
            .expect("the query goes out");

        let mut response = [0u8; 512];
        let (len, _) = client.recv_from(&mut response).expect("an answer arrives");
        assert!(len >= 12, "a DNS answer carries at least a header: {len}");

        let header = &response[..4];
        assert_eq!(header[..2], MALFORMED_QUERY[..2], "the id must be echoed");
        assert_eq!(header[2] & 0x80, 0x80, "QR must be set");
        assert_eq!(header[3] & 0x0F, 1, "an unparseable query is FORMERR");

        stop().expect("front-end stops");
    }

    #[test]
    fn tcp_answers_a_query_it_cannot_parse() {
        let _guard = lock_front_end();

        let _ = stop();
        let address = start("127.0.0.1:0", None).expect("loopback bind succeeds");

        let mut stream = TcpStream::connect(&address).expect("connect");
        stream
            .set_read_timeout(Some(client_timeout()))
            .expect("timeout");

        // RFC 1035 §4.2.2: the query is length-prefixed, and so is the answer.
        let mut framed = Vec::with_capacity(MALFORMED_QUERY.len() + 2);
        framed.extend_from_slice(&(MALFORMED_QUERY.len() as u16).to_be_bytes());
        framed.extend_from_slice(&MALFORMED_QUERY);
        stream.write_all(&framed).expect("the query goes out");

        let mut prefix = [0u8; 2];
        stream
            .read_exact(&mut prefix)
            .expect("a length prefix arrives");
        let mut response = vec![0u8; u16::from_be_bytes(prefix) as usize];
        stream
            .read_exact(&mut response)
            .expect("the answer arrives");

        assert_eq!(response[..2], MALFORMED_QUERY[..2], "the id must be echoed");
        assert_eq!(response[2] & 0x80, 0x80, "QR must be set");
        assert_eq!(response[3] & 0x0F, 1, "an unparseable query is FORMERR");

        stop().expect("front-end stops");
    }

    /// Guards the blocking-worker design against a regression back to polling.
    /// The bound is generous — a poll interval healthy for a battery would
    /// still sit far below it — but a loop that has to wait out a timeout
    /// before it notices the stop flag cannot pass.
    #[test]
    fn stop_does_not_wait_for_traffic() {
        let _guard = lock_front_end();

        let _ = stop();
        let _ = start("127.0.0.1:0", None).expect("loopback bind succeeds");

        let began = Instant::now();
        stop().expect("an idle front-end stops immediately");
        let elapsed = began.elapsed();

        assert!(
            elapsed < Duration::from_millis(500),
            "stop() took {elapsed:?}; an idle front-end must not wait for traffic"
        );
        assert!(!status().running);
    }

    /// The interesting half of the [`stop`] contract: it waits for the
    /// listeners to close rather than detaching their threads, so the port is
    /// immediately reusable. A front-end that returned early would fail here
    /// with `AddrInUse`.
    #[test]
    fn stopping_releases_the_port() {
        let _guard = lock_front_end();

        let _ = stop();
        let address = start("127.0.0.1:0", None).expect("loopback bind succeeds");
        stop().expect("front-end stops");

        assert_eq!(
            start(&address, None).expect("the port is free again"),
            address,
            "a restarted front-end must bind the very address it gave back"
        );
        stop().expect("front-end stops");
    }
}
