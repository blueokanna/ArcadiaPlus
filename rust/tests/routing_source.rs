use corduit::engine::config::{Config, OutboundConfig, OutboundType, RuleConfig, RuleType};
use corduit::engine::routing::{RouteRequest, Router, proxy_mode, set_runtime_proxy_mode};
use parking_lot::RwLock;
use std::sync::Arc;

#[test]
fn source_cidr_never_matches_the_destination_address() {
    // Keep runtime state in this integration-test process, separate from other
    // routing tests that change global mode and provider tables.
    set_runtime_proxy_mode(proxy_mode::RULE);
    let config = Config {
        outbounds: vec![
            OutboundConfig {
                tag: "DIRECT".into(),
                outbound_type: OutboundType::Direct,
                server: None,
                port: None,
                options: Default::default(),
            },
            OutboundConfig {
                tag: "REJECT".into(),
                outbound_type: OutboundType::Reject,
                server: None,
                port: None,
                options: Default::default(),
            },
        ],
        rules: vec![
            RuleConfig {
                rule_type: RuleType::SrcIpCidr,
                payload: "192.0.2.0/24".into(),
                outbound: "REJECT".into(),
                ..RuleConfig::default()
            },
            RuleConfig {
                rule_type: RuleType::Match,
                outbound: "DIRECT".into(),
                ..RuleConfig::default()
            },
        ],
        ..Config::default()
    };
    let router = Router::new(Arc::new(RwLock::new(config))).unwrap();
    for (source, destination, expected, index) in [
        ("192.0.2.10", "203.0.113.10", "REJECT", 0),
        ("203.0.113.10", "192.0.2.10", "DIRECT", 1),
    ] {
        let decision = router.route(&RouteRequest {
            src_ip: Some(source.parse().unwrap()),
            dst_ip: Some(destination.parse().unwrap()),
            dst_port: Some(443),
            ..RouteRequest::default()
        });
        assert_eq!(decision.outbound, expected);
        assert_eq!(decision.rule_index, Some(index));
    }
    set_runtime_proxy_mode(proxy_mode::CONFIG);
}
