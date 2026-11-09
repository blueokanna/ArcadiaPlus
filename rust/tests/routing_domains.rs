use corduit::engine::config::{Config, OutboundConfig, OutboundType, RuleConfig, RuleType};
use corduit::engine::routing::{
    Router, proxy_mode, set_runtime_proxy_mode, set_runtime_rule_providers,
};
use corduit::engine::rule_provider::{RuleProviderBehavior, RuleProviderConfig, RuleProviderType};
use parking_lot::RwLock;
use std::sync::Arc;

#[test]
fn bilibili_domain_set_routes_direct_without_overriding_prior_rejections() {
    let file = std::env::temp_dir().join(format!(
        "arcadia-domain-routing-{}.rules",
        std::process::id()
    ));
    std::fs::write(&file, "+.bilibili.com\n+.bilivideo.com\n+.biliapi.net\n").unwrap();
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            set_runtime_rule_providers(Vec::new());
            set_runtime_proxy_mode(proxy_mode::CONFIG);
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let _cleanup = Cleanup(file.clone());
    set_runtime_rule_providers(vec![RuleProviderConfig {
        name: "cn".into(),
        provider_type: RuleProviderType::File,
        behavior: RuleProviderBehavior::Domain,
        url: None,
        path: Some(file.to_string_lossy().into_owned()),
        interval: 86400,
    }]);
    set_runtime_proxy_mode(proxy_mode::RULE);
    let config = Config {
        outbounds: vec![
            outbound("Domestic", OutboundType::Selector),
            outbound("DIRECT", OutboundType::Direct),
            outbound("REJECT", OutboundType::Reject),
            outbound("PROXY", OutboundType::Socks5),
            outbound("GLOBAL", OutboundType::Selector),
        ],
        rules: vec![
            RuleConfig {
                rule_type: RuleType::DomainSuffix,
                payload: "ads.bilibili.com".into(),
                outbound: "REJECT".into(),
                ..RuleConfig::default()
            },
            RuleConfig {
                rule_type: RuleType::Geosite,
                payload: "cn".into(),
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
    };
    let router = Router::new(Arc::new(RwLock::new(config))).unwrap();
    let route = |domain| {
        router.match_outbound(
            Some(domain),
            Some("203.0.113.1".parse().unwrap()),
            Some(443),
            None,
        )
    };
    assert_eq!(route("api.bilibili.com"), "DIRECT");
    assert_eq!(route("video.bilivideo.com"), "DIRECT");
    assert_eq!(route("ads.bilibili.com"), "REJECT");
    assert_eq!(route("bilibili.com.evil.test"), "PROXY");
    assert_eq!(route("example.net"), "PROXY");

    // Exercise mode changes on the same router, including returning to rule
    // mode; global must bypass even a preceding REJECT rule.
    set_runtime_proxy_mode(proxy_mode::GLOBAL);
    for domain in ["api.bilibili.com", "ads.bilibili.com", "weixin.qq.com"] {
        assert_eq!(route(domain), "GLOBAL");
    }
    set_runtime_proxy_mode(proxy_mode::RULE);
    assert_eq!(route("api.bilibili.com"), "DIRECT");
    assert_eq!(route("ads.bilibili.com"), "REJECT");

    let empty = Router::new(Arc::new(RwLock::new(Config::default()))).unwrap();
    set_runtime_proxy_mode(proxy_mode::GLOBAL);
    assert_eq!(
        empty.match_outbound(Some("example.com"), None, Some(443), None),
        "REJECT"
    );
}

fn outbound(tag: &str, outbound_type: OutboundType) -> OutboundConfig {
    OutboundConfig {
        tag: tag.into(),
        outbound_type,
        server: None,
        port: None,
        options: Default::default(),
    }
}
