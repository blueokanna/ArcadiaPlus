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
//! Socket and queue waits use RecurseX's bounded shutdown polling. Idle loops
//! can wake every 100 ms; this is not a zero-wakeup service. An in-progress
//! resolution may finish within its remaining deadline before workers join.
//!
//! The resolver is created in [`start`] and torn down in [`stop`], so its
//! cache lasts exactly as long as one run of the proxy. That is deliberate:
//! its maintenance thread wakes ten times a second (a one-second interval
//! sliced into 100 ms sleeps so shutdown is noticed promptly), and an idle
//! phone must not pay that for a cache nobody is querying. The front-end is
//! started with the proxy and stopped with it, so the cache is warm exactly
//! while it is worth having.

use std::net::SocketAddr;
use std::thread::JoinHandle;

use parking_lot::Mutex;
use recurse_x::cache::persist::PersistConfig;
use recurse_x::{Resolver, ResolverConfig, Server, ServerConfig};

use crate::types::RecursiveDnsStatus;

/// Bound per-connection TCP worker threads on mobile devices.
const MAX_TCP_CONNECTIONS: usize = 16;

/// Bound the backlog independently of resolver concurrency.
const UDP_QUEUE: usize = 64;

/// TCP and UDP have independent port reservations; retry only ephemeral binds.
const PORT_BIND_ATTEMPTS: usize = 8;

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
        udp_workers: 1,
        udp_handlers: 4,
        udp_queue: UDP_QUEUE,
        max_tcp_connections: MAX_TCP_CONNECTIONS,
        ..ServerConfig::default()
    }
}

// These are client budgets, including every cache tier and negative answers.
fn resolver_config() -> ResolverConfig {
    ResolverConfig {
        cache: recurse_x::cache::CacheConfig {
            hot_capacity: 512,
            warm_capacity: 4096,
            cold_capacity: 1024,
            nx_capacity: 1024,
            ..Default::default()
        },
        engine: recurse_x::resolver::EngineConfig {
            query_budget_ms: 4_000,
            ..Default::default()
        },
        max_inflight: 128,
        max_prefetch_per_tick: 4,
        max_concurrent_refreshes: 2,
        ..Default::default()
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

    corduit::dns::transport::install();
    let requested = requested_address(listen)?;
    let mut config = resolver_config();
    if let Some(path) = cache_path.filter(|path| !path.is_empty()) {
        config.persist = Some(PersistConfig::new(path, CACHE_SNAPSHOT_INTERVAL_MS));
    }
    let resolver = Resolver::new(config);
    let (server, bound) = bind_front_end(&resolver, requested)?;

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

fn bind_front_end(
    resolver: &Resolver,
    requested: SocketAddr,
) -> Result<(Server, SocketAddr), String> {
    let attempts = if requested.port() == 0 {
        PORT_BIND_ATTEMPTS
    } else {
        1
    };
    for attempt in 1..=attempts {
        let server = Server::with_config(resolver.clone(), server_config());
        // Let TCP choose first: Windows may reserve a TCP port that its UDP
        // allocator still offers. Keep the listener open while binding UDP.
        let bound = match server.bind_tcp(requested) {
            Ok(bound) => bound,
            Err(error) => {
                server.shutdown();
                server.join();
                return Err(format!("cannot bind TCP on {requested}: {error}"));
            }
        };
        match server.bind_udp(bound) {
            Ok(_) => return Ok((server, bound)),
            Err(error) => {
                // A bind can fail after spawning some workers. Join every
                // partial attempt before retrying or returning to the caller.
                server.shutdown();
                server.join();
                let retryable = matches!(
                    error.kind(),
                    std::io::ErrorKind::AddrInUse | std::io::ErrorKind::PermissionDenied
                );
                if !retryable || attempt == attempts {
                    return Err(format!("cannot bind UDP on {bound}: {error}"));
                }
            }
        }
    }
    unreachable!("every final bind attempt returns a result")
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
    let mut slot = SERVICE.lock();
    let Some(service) = slot.take() else {
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

// Readiness is the successful UDP/TCP bind, not the reachability of two
// unrelated public websites. Temporary delegation failures must not tear down
// the listener: the engine's loopback-first group already reserves a recovery
// budget, uses the profile upstreams, and cools down a failing local resolver.
// Running means listening; actual resolution health is reported by counters.

/// Whether the front-end is accepting queries, and where.
pub fn status() -> RecursiveDnsStatus {
    match SERVICE.lock().as_ref() {
        Some(service) => {
            let stats = service.resolver.stats().snapshot();
            RecursiveDnsStatus {
                running: true,
                listen: Some(service.address()),
                queries: stats.queries,
                cache_hits: stats.cache_hits,
                upstream_queries: stats.upstream_queries,
                // Upstream SERVFAIL retries are not failed client queries.
                failures: stats.errors,
            }
        }
        None => RecursiveDnsStatus {
            running: false,
            listen: None,
            queries: 0,
            cache_hits: 0,
            upstream_queries: 0,
            failures: 0,
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
    let address: SocketAddr = listen
        .parse()
        .map_err(|error| format!("invalid listen address '{listen}': {error}"))?;

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
    use std::net::{TcpListener, TcpStream, UdpSocket};
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

    #[test]
    fn listen_validation_never_resolves_a_hostname() {
        assert!(requested_address("localhost:53").is_err());
        assert!(requested_address("private.example:53").is_err());
        assert!(requested_address("127.0.0.1:0").is_ok());
        assert!(requested_address("[::1]:0").is_ok());
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

    #[test]
    fn udp_bind_failure_releases_the_partial_tcp_listener() {
        let _guard = lock_front_end();
        stop().unwrap();
        let probe = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = probe.local_addr().unwrap();
        let occupied = UdpSocket::bind(address).unwrap();
        drop(probe);

        let error = start(&address.to_string(), None).expect_err("UDP port is occupied");
        assert!(error.contains("cannot bind UDP"), "{error}");
        assert!(!status().running);
        let released = TcpListener::bind(address).expect("partial TCP listener was closed");
        drop((released, occupied));
    }
}
