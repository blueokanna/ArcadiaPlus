//! Exercise the engine selected by the app against a loopback wire peer.
//! The peer implements framing separately from the outbound codec; no public
//! server, subscription, DNS lookup or synthetic traffic counter is involved.
use corduit::crypto::aead::{Aead, Aes128Gcm, Aes256Gcm, ChaCha20Poly1305};
use corduit::crypto::digest::Digest;
use corduit::crypto::hash::{Md5, Sha1};
use corduit::crypto::kdf::Hkdf;
use corduit::engine::config::{OutboundConfig, OutboundType};
use corduit::engine::outbound::{OutboundProxy, ShadowsocksOutbound, TargetAddr};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::time::Duration;

const PASSWORD: &str = "loopback-only";
const TIMEOUT: Duration = Duration::from_secs(5);
const CIPHERS: [&str; 3] = ["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305"];

fn key_len(method: &str) -> usize {
    if method == "aes-128-gcm" { 16 } else { 32 }
}

fn cipher(method: &str, salt: &[u8]) -> Box<dyn Aead> {
    let mut master = Vec::new();
    let mut previous = Vec::new();
    while master.len() < key_len(method) {
        let mut md5 = Md5::new();
        md5.update(&previous);
        md5.update(PASSWORD.as_bytes());
        previous = md5.finalize().to_vec();
        master.extend_from_slice(&previous);
    }
    master.truncate(key_len(method));
    let mut key = vec![0; key_len(method)];
    Hkdf::<Sha1>::new(Some(salt), &master)
        .expand(b"ss-subkey", &mut key)
        .unwrap();
    match method {
        "aes-128-gcm" => Box::new(Aes128Gcm::new_from_slice(&key).unwrap()),
        "aes-256-gcm" => Box::new(Aes256Gcm::new_from_slice(&key).unwrap()),
        _ => Box::new(ChaCha20Poly1305::new_from_slice(&key).unwrap()),
    }
}

fn nonce(counter: u64) -> [u8; 12] {
    let mut nonce = [0; 12];
    nonce[..8].copy_from_slice(&counter.to_le_bytes());
    nonce
}

fn receive_upload(socket: &mut TcpStream, method: &str) -> Vec<u8> {
    socket.set_read_timeout(Some(TIMEOUT)).unwrap();
    socket.set_write_timeout(Some(TIMEOUT)).unwrap();
    let mut salt = vec![0; key_len(method)];
    socket.read_exact(&mut salt).unwrap();
    let cipher = cipher(method, &salt);
    let mut received = Vec::new();
    let mut counter = 0;
    loop {
        let mut length = [0; 18];
        if socket.read(&mut length[..1]).unwrap() == 0 {
            break;
        }
        socket.read_exact(&mut length[1..]).unwrap();
        let plain = cipher.decrypt(&nonce(counter), &length, &[]).unwrap();
        counter += 1;
        let size = u16::from_be_bytes(plain.try_into().unwrap()) as usize;
        assert!(size <= 0x3fff);
        let mut payload = vec![0; size + 16];
        socket.read_exact(&mut payload).unwrap();
        received.extend(cipher.decrypt(&nonce(counter), &payload, &[]).unwrap());
        counter += 1;
    }
    assert!(received.starts_with(&[1, 203, 0, 113, 1, 1, 187]));
    received.drain(..7);
    received
}

fn response(method: &str, data: &[u8]) -> Vec<u8> {
    let mut wire = vec![42; key_len(method)];
    let cipher = cipher(method, &wire);
    for (index, chunk) in data.chunks(0x3fff).enumerate() {
        let counter = index as u64 * 2;
        wire.extend(
            cipher
                .encrypt(&nonce(counter), &(chunk.len() as u16).to_be_bytes(), &[])
                .unwrap(),
        );
        wire.extend(cipher.encrypt(&nonce(counter + 1), chunk, &[]).unwrap());
    }
    wire
}

fn exchange(
    method: &'static str,
    upload: Vec<u8>,
    reply: Vec<u8>,
) -> (Vec<u8>, Result<(), String>) {
    let server = TcpListener::bind("127.0.0.1:0").unwrap();
    let outbound = ShadowsocksOutbound::new(OutboundConfig {
        tag: "loopback-ss".into(),
        outbound_type: OutboundType::Shadowsocks,
        server: Some("127.0.0.1".into()),
        port: Some(server.local_addr().unwrap().port()),
        options: HashMap::from([
            ("password".into(), PASSWORD.into()),
            ("cipher".into(), method.into()),
        ]),
    })
    .unwrap();
    let expected = upload.clone();
    let peer = std::thread::spawn(move || {
        let (mut socket, _) = server.accept().unwrap();
        // A response is deliberately withheld until FIN arrives. Dropping a
        // half-close under read-lock contention stalls this exchange.
        assert_eq!(receive_upload(&mut socket, method), expected);
        for chunk in reply.chunks(31) {
            if socket.write_all(chunk).is_err() {
                break;
            }
        }
    });
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    client.set_read_timeout(Some(TIMEOUT)).unwrap();
    client.set_write_timeout(Some(TIMEOUT)).unwrap();
    let (inbound, _) = listener.accept().unwrap();
    let relay = std::thread::spawn(move || {
        outbound
            .relay_tcp(
                Box::new(inbound),
                TargetAddr::Ip("203.0.113.1:443".parse().unwrap()),
            )
            .map_err(|error| error.to_string())
    });
    client.write_all(&upload).unwrap();
    client.shutdown(Shutdown::Write).unwrap();
    let mut received = Vec::new();
    client.read_to_end(&mut received).unwrap();
    let result = relay.join().unwrap();
    peer.join().unwrap();
    (received, result)
}

#[test]
fn all_ciphers_relay_large_response_after_client_half_close() {
    let upload: Vec<u8> = (0..65537).map(|n| (n % 251) as u8).collect();
    let download: Vec<u8> = (0..70001).map(|n| (n % 239) as u8).collect();
    for method in CIPHERS {
        let (received, result) = exchange(method, upload.clone(), response(method, &download));
        result.unwrap();
        assert_eq!(received, download, "{method}");
    }
}

#[test]
fn truncated_or_unauthenticated_response_releases_no_plaintext() {
    for method in CIPHERS {
        let mut truncated = response(method, b"must not escape");
        truncated.pop();
        let (received, result) = exchange(method, b"request".to_vec(), truncated);
        assert!(received.is_empty());
        assert!(result.unwrap_err().contains("encrypted payload"));
        let mut corrupted = response(method, b"must not escape");
        *corrupted.last_mut().unwrap() ^= 1;
        let (received, result) = exchange(method, b"request".to_vec(), corrupted);
        assert!(received.is_empty());
        assert!(result.unwrap_err().contains("AEAD decrypt failed"));
    }
}

#[test]
fn upstream_close_before_salt_remains_a_visible_failure() {
    let (received, result) = exchange("aes-128-gcm", b"request".to_vec(), Vec::new());
    assert!(received.is_empty());
    assert!(result.unwrap_err().contains("no salt received"));
}

#[test]
fn app_api_starts_socks5_and_routes_through_nested_groups_to_shadowsocks() {
    use rust_lib_arcadiaplus::api;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap();
    struct StopEngine<'a>(&'a tokio::runtime::Runtime);
    impl Drop for StopEngine<'_> {
        fn drop(&mut self) {
            let _ = self.0.block_on(api::stop_corduit());
        }
    }
    let _stop = StopEngine(&runtime);
    let server = TcpListener::bind("127.0.0.1:0").unwrap();
    let server_port = server.local_addr().unwrap().port();
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let config = format!(
        r#"{{
        "general": {{"mode":"rule", "bind_address":"127.0.0.1", "mixed_port":{port},
            "allow_lan":false, "log_level":"warn", "ipv6":false, "tcp_concurrent":false}},
        "dns": {{"enable":false, "listen":"127.0.0.1:0", "nameservers":[], "fallback":[], "enhanced_mode":"normal"}},
        "inbounds": [{{"inbound_type":"mixed", "tag":"mixed-in", "listen":"127.0.0.1", "port":{port}, "options":"{{}}"}}],
        "outbounds": [
            {{"outbound_type":"direct", "tag":"DIRECT", "options":"{{}}"}},
            {{"outbound_type":"shadowsocks", "tag":"ss-node", "server":"127.0.0.1", "port":{server_port},
              "options":"{{\"password\":\"{PASSWORD}\",\"cipher\":\"aes-256-gcm\"}}"}},
            {{"outbound_type":"selector", "tag":"inner", "options":"{{\"outbounds\":[\"ss-node\"]}}"}},
            {{"outbound_type":"selector", "tag":"outer", "options":"{{\"outbounds\":[\"inner\"]}}"}}
        ],
        "rules": [{{"rule_type":"match", "payload":"", "outbound":"outer"}}]
    }}"#
    );
    runtime.block_on(api::initialize_corduit(config)).unwrap();
    runtime.block_on(api::start_corduit()).unwrap();
    assert!(runtime.block_on(api::is_proxy_running()).unwrap());
    assert!(
        runtime
            .block_on(api::select_proxy_in_group("outer".into(), "inner".into()))
            .unwrap()
    );
    let peer = std::thread::spawn(move || {
        let (mut socket, _) = server.accept().unwrap();
        assert_eq!(receive_upload(&mut socket, "aes-256-gcm"), b"app-request");
        socket
            .write_all(&response("aes-256-gcm", b"app-response"))
            .unwrap();
    });
    let mut client = TcpStream::connect(("127.0.0.1", port)).unwrap();
    client.set_read_timeout(Some(TIMEOUT)).unwrap();
    client.set_write_timeout(Some(TIMEOUT)).unwrap();
    client.write_all(&[5, 1, 0]).unwrap();
    let mut greeting = [0; 2];
    client.read_exact(&mut greeting).unwrap();
    assert_eq!(greeting, [5, 0]);
    client
        .write_all(&[5, 1, 0, 1, 203, 0, 113, 1, 1, 187])
        .unwrap();
    let mut reply = [0; 10];
    client.read_exact(&mut reply).unwrap();
    assert_eq!(&reply[..2], &[5, 0]);
    client.write_all(b"app-request").unwrap();
    client.shutdown(Shutdown::Write).unwrap();
    let mut received = Vec::new();
    client.read_to_end(&mut received).unwrap();
    assert_eq!(received, b"app-response");
    peer.join().unwrap();
    runtime.block_on(api::stop_corduit()).unwrap();
    assert!(!runtime.block_on(api::is_proxy_running()).unwrap());
}
