//! The database shipped in `assets/` is the only Geo data a release can rely
//! on, so it is checked twice: once as an artifact, against the engine's own
//! MaxMind reader, and once through a router that has to route a domestic
//! address with nothing but an IP to go on.
//!
//! # Why the routing assertion is unconditional
//!
//! Corduit 0.4.0 identified a MaxMind database by requiring the
//! `\xab\xcd\xefMaxMind.com` marker at *end-of-file*. A real database does not
//! end there: the marker opens the metadata map that follows it. So 0.4.0
//! classified `assets/Country.mmdb` as an unknown format, never loaded it, and
//! every `GEOIP` rule fell through — silently, because a rule that misses
//! simply hands the connection to the next one. 0.4.1 searches the 128 KiB
//! metadata window, the same window its reader uses.
//!
//! The dependency is pinned to that fix, so this test asserts the routing
//! rather than probing which engine it got. A kernel that cannot read the
//! shipped database is a broken release, and passing by asserting the
//! fall-through it causes would hide exactly the regression worth catching.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use corduit::engine::config::{Config, RuleConfig, RuleType};
use corduit::engine::geo::DatabaseKind;
use corduit::engine::geoip::{GeoIpDatabase, set_default_database_path};
use corduit::engine::mmdb::MmdbReader;
use corduit::engine::routing::{Router, proxy_mode, set_runtime_proxy_mode};
use parking_lot::RwLock;

/// Addresses the bundled database attributes to China, and one it does not.
const DOMESTIC: [&str; 3] = ["117.185.18.212", "119.147.96.223", "223.5.5.5"];
const FOREIGN: &str = "1.1.1.1";

fn bundled_database() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../assets/Country.mmdb")
}

/// A router whose first rule sends `CN` addresses `DIRECT`, with a catch-all
/// behind it so a rule that does not fire is visible as `PROXY`.
fn router_over(database: &Path) -> Router {
    set_default_database_path(database).expect("registration accepts any existing file");
    set_runtime_proxy_mode(proxy_mode::RULE);
    Router::new(Arc::new(RwLock::new(Config {
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
    .expect("a router over the shipped database")
}

fn route(router: &Router, address: &str) -> String {
    router.match_outbound(
        None,
        Some(address.parse().expect("a literal address")),
        Some(443),
        None,
    )
}

/// The artifact: a MaxMind database the engine's reader parses and answers from.
///
/// Independent of the router, so a corrupt file is reported as a corrupt file
/// rather than as a routing surprise.
#[test]
fn the_bundled_database_is_a_maxmind_database() {
    let path = bundled_database();
    let data = std::fs::read(&path).unwrap_or_else(|error| {
        panic!("the bundled GeoIP database is missing at {path:?}: {error}")
    });
    let reader = MmdbReader::open(data).expect("the bundled database must parse as MaxMind DB");

    for address in DOMESTIC {
        let ip = address.parse().expect("a literal address");
        let country = reader.lookup_country(ip);
        assert_eq!(
            country.as_ref().map(ToString::to_string).as_deref(),
            Some("CN"),
            "the bundled database must attribute {address} to CN"
        );
    }

    let foreign = FOREIGN.parse().expect("a literal address");
    let country = reader
        .lookup_country(foreign)
        .expect("the bundled database must know a public resolver");
    assert_ne!(
        country.to_string(),
        "CN",
        "the bundled database must not attribute {FOREIGN} to CN"
    );
}

/// The behaviour the artifact exists for: an address-only connection routed by
/// its country, through the engine's own classifier and installer.
#[test]
fn the_bundled_database_routes_addresses_by_country() {
    let database = bundled_database();

    let mut probe = GeoIpDatabase::new();
    assert_eq!(
        probe
            .install_file(&database)
            .expect("the engine must install the shipped database"),
        DatabaseKind::Mmdb,
        "the shipped file must install as a MaxMind database, not as a .dat"
    );
    drop(probe);

    let router = router_over(&database);

    for address in DOMESTIC {
        assert_eq!(
            route(&router, address),
            "DIRECT",
            "{address} is inside the bundled database's CN ranges"
        );
    }
    assert_eq!(
        route(&router, FOREIGN),
        "PROXY",
        "{FOREIGN} is outside them, so the catch-all decides"
    );

    set_runtime_proxy_mode(proxy_mode::CONFIG);
}
