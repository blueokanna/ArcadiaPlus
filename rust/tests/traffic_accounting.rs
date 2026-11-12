//! Loopback traffic through real leaf transports and nested selectors. No
//! external node, DNS resolver or synthetic byte counter is used in this test.
use corduit::engine::config::{Config, OutboundConfig, OutboundType};
use corduit::engine::outbound::{OutboundManager, OutboundProxy, TargetAddr, UdpReplySink};
use parking_lot::RwLock;
use rust_lib_arcadiaplus::TrafficStats;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream, UdpSocket};
use std::sync::{Arc, mpsc};
use std::time::Duration;

fn config(tag: &str, kind: OutboundType, port: Option<u16>) -> OutboundConfig {
    OutboundConfig {
        tag: tag.into(),
        outbound_type: kind,
        server: port.map(|_| "127.0.0.1".into()),
        port,
        options: Default::default(),
    }
}

fn group(tag: &str, member: &str) -> OutboundConfig {
    let mut value = config(tag, OutboundType::Selector, None);
    value
        .options
        .insert("outbounds".into(), vec![member.into()].into());
    value
}

fn exchange(proxy: Arc<dyn OutboundProxy>, target: TargetAddr, upload: &[u8], reply: &[u8]) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    client
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let (inbound, _) = listener.accept().unwrap();
    let relay = std::thread::spawn(move || proxy.relay_tcp(Box::new(inbound), target));
    client.write_all(upload).unwrap();
    let mut received = vec![0; reply.len()];
    client.read_exact(&mut received).unwrap();
    assert_eq!(received, reply);
    client.shutdown(Shutdown::Both).unwrap();
    relay.join().unwrap().unwrap();
}

#[test]
fn actual_leaf_routes_own_payload_bytes_and_bridge_totals_match() {
    let tracker = corduit::engine::global_tracker();
    tracker.reset();
    let direct_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let direct_target = TargetAddr::Ip(direct_listener.local_addr().unwrap());
    let direct_peer = std::thread::spawn(move || {
        let (mut stream, _) = direct_listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut payload = [0; 11];
        stream.read_exact(&mut payload).unwrap();
        assert_eq!(&payload, b"direct-body");
        stream.write_all(b"direct-response").unwrap();
    });
    let http_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let http_port = http_listener.local_addr().unwrap().port();
    let proxy_peer = std::thread::spawn(move || {
        let (mut stream, _) = http_listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            assert!(head.len() < 4096);
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            head.push(byte[0]);
        }
        assert!(head.starts_with(b"CONNECT 203.0.113.1:443 "));
        stream
            .write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            .unwrap();
        let mut payload = [0; 10];
        stream.read_exact(&mut payload).unwrap();
        assert_eq!(&payload, b"proxy-body");
        stream.write_all(b"proxy-response-longer").unwrap();
    });

    // Deliberately misleading tags: attribution must use the transport type.
    let manager = OutboundManager::new(Arc::new(RwLock::new(Config {
        outbounds: vec![
            config("PROXY-looking-direct", OutboundType::Direct, None),
            config("DIRECT-looking-proxy", OutboundType::Http, Some(http_port)),
            group("inner-direct", "PROXY-looking-direct"),
            group("outer-direct", "inner-direct"),
            group("inner-proxy", "DIRECT-looking-proxy"),
            group("outer-proxy", "inner-proxy"),
        ],
        ..Config::default()
    })))
    .unwrap();
    let direct = manager.get_proxy("outer-direct").unwrap();
    exchange(
        direct.clone(),
        direct_target,
        b"direct-body",
        b"direct-response",
    );
    direct_peer.join().unwrap();
    assert_eq!(tracker.route_totals(), (11, 15, 0, 0));
    exchange(
        manager.get_proxy("outer-proxy").unwrap(),
        TargetAddr::Ip("203.0.113.1:443".parse().unwrap()),
        b"proxy-body",
        b"proxy-response-longer",
    );
    proxy_peer.join().unwrap();
    assert_eq!(tracker.route_totals(), (11, 15, 10, 21));

    let udp = UdpSocket::bind("127.0.0.1:0").unwrap();
    udp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let target = TargetAddr::Ip(udp.local_addr().unwrap());
    let peer = std::thread::spawn(move || {
        let mut buffer = [0; 128];
        let (size, source) = udp.recv_from(&mut buffer).unwrap();
        assert_eq!(&buffer[..size], b"udp-upload");
        udp.send_to(b"udp-response", source).unwrap();
    });
    let (tx, rx) = mpsc::channel();
    let sink = UdpReplySink::new(move |_, payload| tx.send(payload.to_vec()).unwrap());
    direct.udp_submit(&target, b"udp-upload", &sink).unwrap();
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(5)).unwrap(),
        b"udp-response"
    );
    peer.join().unwrap();
    assert_eq!(tracker.route_totals(), (21, 27, 10, 21));
    let sample: TrafficStats = corduit::api::get_traffic_stats().unwrap().into();
    assert_eq!((sample.upload, sample.download), (31, 48));
    assert_eq!(sample.upload, sample.direct_upload + sample.proxy_upload);
    assert_eq!(
        sample.download,
        sample.direct_download + sample.proxy_download
    );
    assert_eq!(corduit::api::get_connection_stats().unwrap().1, 31);
    assert_eq!(corduit::api::get_connection_stats().unwrap().2, 48);
}
