//! App/core contract tests. Hermetic tests never contact public DNS.
use corduit::dns::engine_resolver::{EngineDnsSettings, EngineResolver};
use recurse_x::{Message, RData, Record, RrClass, RrType};
use std::net::{TcpListener, UdpSocket};
use std::time::Duration;

#[test]
fn healthy_local_recursion_does_not_race_the_recovery_resolver() {
    let primary = UdpSocket::bind("127.0.0.1:0").unwrap();
    primary
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let recovery = UdpSocket::bind("127.0.0.1:0").unwrap();
    recovery
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let engine = EngineResolver::from_settings(EngineDnsSettings {
        nameservers: vec![
            primary.local_addr().unwrap().to_string(),
            recovery.local_addr().unwrap().to_string(),
        ],
        ..EngineDnsSettings::default()
    })
    .unwrap();
    let worker = std::thread::spawn(move || {
        let mut bytes = [0; 4096];
        let (size, peer) = primary.recv_from(&mut bytes).unwrap();
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
        primary.send_to(&reply.to_bytes().unwrap(), peer).unwrap();
    });
    let answer = engine.resolve_ips("healthy.private.test", false);
    worker.join().unwrap();
    assert_eq!(answer.unwrap().len(), 1);
    assert!(
        recovery.recv_from(&mut [0; 4096]).is_err(),
        "healthy local recursion must not disclose the name to recovery DNS"
    );
}

#[test]
fn a_tls_failure_stays_an_error_without_plaintext_retry() {
    // A non-TLS peer on a configured TLS port: no real certificates or network.
    let tls = TcpListener::bind("127.0.0.1:0").unwrap();
    tls.set_nonblocking(true).unwrap();
    let addr = tls.local_addr().unwrap();
    let plaintext = UdpSocket::bind(addr).unwrap();
    plaintext
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let engine = EngineResolver::from_settings(EngineDnsSettings {
        nameservers: vec![format!("tls://{addr}#resolver.invalid")],
        ..EngineDnsSettings::default()
    })
    .unwrap();
    let result = engine.resolve_ips("privacy.invalid", false);
    assert!(result.is_err());
    assert!(
        plaintext.recv_from(&mut [0; 4096]).is_err(),
        "TLS failure must not become UDP on the same endpoint"
    );
}

#[test]
#[ignore = "public network: run explicitly to verify HTTPS DNS and certificates"]
fn public_https_dns_uses_the_actual_corduit_resolver() {
    let engine = EngineResolver::from_settings(EngineDnsSettings {
        nameservers: vec![
            "https://223.5.5.5/dns-query".into(),
            "https://223.6.6.6/dns-query".into(),
        ],
        ..EngineDnsSettings::default()
    })
    .unwrap();
    let addresses = engine
        .resolve_ips("example.com", false)
        .expect("verified DoH answer");
    assert!(!addresses.is_empty());
    println!("Verified HTTPS DNS returned {} A records", addresses.len());
}

#[test]
fn local_recursion_is_ready_without_contacting_a_public_probe() {
    use rust_lib_arcadiaplus::{api, recursive_dns};
    // Exercise the application's blocking-worker API, not just its bind helper.
    struct Cleanup;
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = recursive_dns::stop();
        }
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap();
    let address = runtime
        .block_on(api::start_recursive_dns("127.0.0.1:0".into(), None))
        .unwrap();
    let _cleanup = Cleanup;
    let status = runtime.block_on(api::get_recursive_dns_status()).unwrap();
    assert!(status.running);
    assert_eq!(status.listen.as_deref(), Some(address.as_str()));
    assert_eq!(
        status.upstream_queries, 0,
        "startup must not probe external websites"
    );
    let client = UdpSocket::bind("127.0.0.1:0").unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    client.connect(&address).unwrap();
    client.send(&[0x12, 0x34, 0x01, 0x00]).unwrap();
    let mut response = [0; 512];
    let size = client.recv(&mut response).unwrap();
    assert!(size >= 12);
    assert_eq!(&response[..2], &[0x12, 0x34]);
    assert_eq!(
        response[3] & 0x0f,
        1,
        "ready listener answers FORMERR locally"
    );
    runtime.block_on(api::stop_recursive_dns()).unwrap();
    assert!(
        !runtime
            .block_on(api::get_recursive_dns_status())
            .unwrap()
            .running
    );
}
