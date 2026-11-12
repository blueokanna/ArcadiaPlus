use corduit::dns::engine_resolver::{self, EngineDnsSettings};
use std::io::Read;
use std::net::{TcpListener, ToSocketAddrs};
use std::time::Duration;

#[test]
fn encrypted_lookup_failure_does_not_use_the_system_answer() {
    assert!(
        ("localhost", 80)
            .to_socket_addrs()
            .unwrap()
            .next()
            .is_some()
    );
    for role in ["primary", "bootstrap", "fallback"] {
        assert_encrypted_failure(role);
    }
}

fn assert_encrypted_failure(role: &str) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    listener.set_nonblocking(true).unwrap();
    let peer = std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    let mut header = [0; 3];
                    stream.read_exact(&mut header).unwrap();
                    return header;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        std::time::Instant::now() < deadline,
                        "no encrypted connection arrived"
                    );
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => panic!("accept: {e}"),
            }
        }
    });
    let endpoint = format!("tls://127.0.0.1:{port}#resolver.test");
    let mut settings = EngineDnsSettings::default();
    match role {
        "primary" => settings.nameservers = vec![endpoint],
        "bootstrap" => {
            settings.nameservers = vec!["tls://resolver.test".into()];
            settings.default_nameserver = vec![endpoint];
        }
        "fallback" => {
            settings.nameservers = vec!["tls://127.0.0.1:1#unused.test".into()];
            settings.fallback = vec![endpoint];
            settings.fallback_domain = vec!["localhost".into()];
        }
        _ => unreachable!(),
    }
    engine_resolver::configure(settings);
    let result = corduit::common::socket::resolve_host("localhost", 80, Duration::from_secs(8));
    engine_resolver::clear();
    assert!(
        result.is_err(),
        "failed encrypted {role} lookup bypassed DNS policy: {result:?}"
    );
    let header = peer
        .join()
        .unwrap_or_else(|_| panic!("no TLS handshake for {role}; resolver returned {result:?}"));
    assert_eq!(header[0], 0x16, "expected a TLS handshake record");
    assert_eq!(header[1], 0x03, "expected a TLS record version");
}
