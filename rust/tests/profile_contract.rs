//! The document this app's converter emits, checked against the real engine.
//!
//! `config_converter.dart` has its own tests, but they assert the document it
//! builds; they cannot assert that the engine accepts it. A rule type the engine
//! spells differently, a group option it stopped reading, or a provider shape it
//! rejects would pass every Dart test and then fail at start-up on a phone —
//! with the profile refused rather than degraded. These tests hand the same
//! shapes to the engine and read them back through the API the bridge exposes,
//! so the two sides of the contract are checked by the same toolchain that
//! builds them.
//!
//! The engine is one process-global instance, so this file holds a single test;
//! running the document through `test_config`, `initialize_corduit` and
//! `start_corduit` in that order also checks the three entry points agree.

use std::path::{Path, PathBuf};

use corduit::api as engine_api;
use corduit::engine::config::{OutboundType, RuleType};

fn free_port() -> u16 {
    std::net::TcpListener::bind(("127.0.0.1", 0))
        .expect("bind a probe port")
        .local_addr()
        .expect("probe address")
        .port()
}

/// A local `domain` provider, in the form `RuleProviderService` writes: one
/// suffix per line, no header.
fn local_ruleset() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "arcadia-profile-contract-{}.rules",
        std::process::id()
    ));
    std::fs::write(&path, "+.example.test\n").expect("write the ruleset");
    path
}

/// The document `ConfigConverter` produces for a small but complete profile.
///
/// Field order and spelling follow the converter: `type`-less rule objects with
/// `rule_type`, options carried as JSON strings, providers as file entries.
fn document(port: u16, ruleset: &Path) -> String {
    let ruleset = String::from_utf8(
        nextjson::to_vec(&ruleset.to_string_lossy().to_string()).expect("a path encodes as JSON"),
    )
    .expect("the encoder emits UTF-8");

    format!(
        r#"{{
  "general": {{"mode":"rule","mixed_port":{port},"allow_lan":false,"bind_address":"127.0.0.1","log_level":"warn","ipv6":false,"tcp_concurrent":false}},
  "dns": {{"enable":false,"listen":"127.0.0.1:0","nameservers":[],"fallback":[],"enhanced_mode":"normal"}},
  "inbounds": [{{"inbound_type":"mixed","tag":"mixed","listen":"127.0.0.1","port":{port},"options":"{{}}"}}],
  "outbounds": [
    {{"outbound_type":"direct","tag":"DIRECT","server":null,"port":null,"options":"{{}}"}},
    {{"outbound_type":"reject","tag":"REJECT","server":null,"port":null,"options":"{{}}"}},
    {{"outbound_type":"selector","tag":"PROXY","server":null,"port":null,"options":"{{\"outbounds\":[\"DIRECT\",\"REJECT\"]}}"}},
    {{"outbound_type":"selector","tag":"GLOBAL","server":null,"port":null,"options":"{{\"outbounds\":[\"DIRECT\"]}}"}},
    {{"outbound_type":"url-test","tag":"AUTO","server":null,"port":null,"options":"{{\"outbounds\":[\"DIRECT\",\"REJECT\"],\"url\":\"https://example.test/204\",\"interval\":120,\"timeout\":4000,\"tolerance\":150}}"}},
    {{"outbound_type":"load-balance","tag":"LB","server":null,"port":null,"options":"{{\"outbounds\":[\"DIRECT\",\"REJECT\"],\"strategy\":\"consistent-hashing\"}}"}}
  ],
  "rule_providers": [{{"name":"domestic","type":"file","behavior":"domain","path":{ruleset},"interval":86400}}],
  "rules": [
    {{"rule_type":"geoip","payload":"CN","outbound":"DIRECT","process_name":null}},
    {{"rule_type":"domain_suffix","payload":"ads.example","outbound":"REJECT","process_name":null}},
    {{"rule_type":"rule_set","payload":"domestic","outbound":"DIRECT","process_name":null}},
    {{"rule_type":"proxy_mode","payload":"global","outbound":"PROXY","process_name":null}},
    {{"rule_type":"match","payload":"","outbound":"PROXY","process_name":null}}
  ]
}}"#
    )
}

#[test]
fn the_engine_accepts_the_document_the_converter_emits() {
    let ruleset = local_ruleset();
    let port = free_port();
    let document = document(port, &ruleset);

    // `test_config` builds an engine from the document and throws it away, which
    // is exactly the "would this profile start" question the app asks before it
    // replaces the running configuration.
    assert!(
        engine_api::test_config(document.clone()).expect("validation runs"),
        "the converter's document must build an engine"
    );

    engine_api::initialize_corduit(document).expect("the engine initialises from the document");

    let groups = engine_api::get_proxy_groups().expect("proxy groups are readable");
    for (tag, kind, members) in [
        ("PROXY", OutboundType::Selector, vec!["DIRECT", "REJECT"]),
        ("AUTO", OutboundType::Urltest, vec!["DIRECT", "REJECT"]),
        ("LB", OutboundType::Loadbalance, vec!["DIRECT", "REJECT"]),
    ] {
        let group = groups
            .iter()
            .find(|group| group.tag == tag)
            .unwrap_or_else(|| panic!("group {tag} is missing from the engine"));
        assert_eq!(
            OutboundType::parse(&group.group_type),
            Some(kind),
            "group {tag} must keep the type the converter asked for, got {}",
            group.group_type
        );
        assert_eq!(group.proxies, members, "group {tag} must keep its members");
    }

    let rules = engine_api::get_rules().expect("the rule table is readable");
    let find = |kind: RuleType, payload: &str| {
        rules
            .iter()
            .any(|rule| RuleType::parse(&rule.rule_type) == Some(kind) && rule.payload == payload)
    };
    assert!(find(RuleType::Geoip, "CN"), "the GEOIP rule must survive");
    assert!(
        find(RuleType::RuleSet, "domestic"),
        "a provider reference must arrive as rule-set, not as a rule the engine ignores"
    );
    assert!(
        find(RuleType::ProxyMode, "global"),
        "the mode guard must survive as proxy-mode"
    );
    assert_eq!(
        rules
            .last()
            .and_then(|rule| RuleType::parse(&rule.rule_type)),
        Some(RuleType::Match),
        "the catch-all must stay last"
    );

    engine_api::start_corduit().expect("the listeners start on the document");
    assert!(
        engine_api::is_proxy_running().expect("running state is readable"),
        "the engine must report itself running after start"
    );
    engine_api::stop_corduit().expect("the engine stops");

    let _ = std::fs::remove_file(&ruleset);
}
