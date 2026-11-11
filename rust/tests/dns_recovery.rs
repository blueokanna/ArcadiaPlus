//! Exercise Corduit's real resolver plan through the shared RecurseX patch.
use corduit::dns::engine_resolver::{EngineDnsSettings, EngineResolver};
use recurse_x::{Message, RData, Record, RrClass, RrType, observation};
use std::net::{IpAddr, UdpSocket};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

#[test]
fn engine_recovers_from_dead_loopback_and_exports_real_query_results() {
    observation::configure(16);
    let dead = UdpSocket::bind("127.0.0.1:0").unwrap();
    let good = UdpSocket::bind("127.0.0.1:0").unwrap();
    let settings = EngineDnsSettings {
        nameservers: vec![
            dead.local_addr().unwrap().to_string(),
            good.local_addr().unwrap().to_string(),
        ],
        ..EngineDnsSettings::default()
    };
    let stop = Arc::new(AtomicBool::new(false));
    let dead_seen = Arc::new(AtomicUsize::new(0));
    let mut workers = Vec::new();
    for (socket, answer) in [(dead, false), (good, true)] {
        socket
            .set_read_timeout(Some(Duration::from_millis(30)))
            .unwrap();
        let stopped = stop.clone();
        let seen = dead_seen.clone();
        workers.push(std::thread::spawn(move || {
            let mut bytes = [0; 4096];
            while !stopped.load(Ordering::Relaxed) {
                let Ok((size, peer)) = socket.recv_from(&mut bytes) else {
                    continue;
                };
                if !answer {
                    seen.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
                let mut reply = Message::parse(&bytes[..size]).unwrap();
                reply.flags.qr = true;
                reply.flags.ra = true;
                reply.answers.push(Record {
                    name: reply.question().unwrap().qname.clone(),
                    rr_type: RrType::A,
                    class: RrClass::IN,
                    ttl: 60,
                    rdata: RData::A("203.0.113.42".parse().unwrap()),
                });
                socket.send_to(&reply.to_bytes().unwrap(), peer).unwrap();
            }
        }));
    }
    let engine = EngineResolver::from_settings(settings).unwrap();
    let began = Instant::now();
    let first = engine.resolve_ips("first.recovery.test", false);
    let second = engine.resolve_ips("second.recovery.test", false);
    stop.store(true, Ordering::Relaxed);
    for worker in workers {
        worker.join().unwrap();
    }
    assert_eq!(first.unwrap(), ["203.0.113.42".parse::<IpAddr>().unwrap()]);
    assert_eq!(second.unwrap(), ["203.0.113.42".parse::<IpAddr>().unwrap()]);
    assert!(began.elapsed() < Duration::from_secs(5));
    assert_eq!(
        dead_seen.load(Ordering::Relaxed),
        1,
        "second lookup bypasses the failed service"
    );
    let snapshot = observation::snapshot();
    assert_eq!(
        snapshot.events.len(),
        2,
        "Corduit uses the same observation collector as the bridge"
    );
    for event in snapshot.events {
        assert_eq!(event.path, "forward");
        assert_eq!(event.answers, ["203.0.113.42"]);
        assert_eq!(event.outcome, "NOERROR");
        assert!(!event.from_cache);
    }
}
