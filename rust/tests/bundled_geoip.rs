use corduit::engine::config::{Config, RuleConfig, RuleType};
use corduit::engine::geoip::set_default_database_path;
use corduit::engine::routing::{Router, proxy_mode, set_runtime_proxy_mode};
use parking_lot::RwLock;
use std::path::Path;
use std::sync::Arc;

#[test]
fn bundled_database_routes_domestic_ip_only_connections_direct() {
    // Test the data shipped inside the app, not an OS-installed MMDB or a
    // synthetic country matcher. TUN clients often arrive with only an IP.
    let database = Path::new(env!("CARGO_MANIFEST_DIR")).join("../assets/Country.mmdb");
    set_default_database_path(database).unwrap();
    set_runtime_proxy_mode(proxy_mode::RULE);
    let router = Router::new(Arc::new(RwLock::new(Config {
        rules: vec![
            RuleConfig {
                rule_type: RuleType::Geoip,
                payload: "CN".into(),
                outbound: "DIRECT".into(),
                ..RuleConfig::default()
            },
            RuleConfig {
                rule_type: RuleType::Match,
                outbound: "PROXY".into(),
                ..RuleConfig::default()
            },
        ],
        ..Config::default()
    })))
    .unwrap();
    for address in ["117.185.18.212", "119.147.96.223", "223.5.5.5"] {
        assert_eq!(
            router.match_outbound(None, Some(address.parse().unwrap()), Some(443), None),
            "DIRECT",
            "{address}"
        );
    }
    assert_eq!(
        router.match_outbound(None, Some("1.1.1.1".parse().unwrap()), Some(443), None),
        "PROXY"
    );
}
