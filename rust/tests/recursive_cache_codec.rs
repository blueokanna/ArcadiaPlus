//! Exercise the real persistence consumer of RustBinary in the app's feature
//! graph, rather than a stand-in DTO with a different serialization schema.
use recurse_x::cache::{
    persist, score::ScoreInputs, CacheConfig, CacheKey, LookupOutcome, SemanticCache,
};
use recurse_x::rrset::RrSet;
use recurse_x::{Name, RData, Rcode, Record, RrClass, RrType};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

const NOW: i128 = 1_700_000_000_000_000_000;
const SECOND: i128 = 1_000_000_000;

struct CacheFile(PathBuf);

impl CacheFile {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        Self(std::env::temp_dir().join(format!(
            "arcadiaplus-codec-{}-{}.bin",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )))
    }
}

impl Drop for CacheFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
        let _ = std::fs::remove_file(self.0.with_extension("tmp"));
    }
}

fn key(name: &str, rr_type: RrType) -> CacheKey {
    CacheKey::plain(Name::from_ascii(name).unwrap(), rr_type, RrClass::IN)
}

fn populated_cache() -> SemanticCache {
    let mut cache = SemanticCache::new(CacheConfig::default());
    let key = key("codec.example", RrType::A);
    let mut records = RrSet::new(key.name.clone(), RrType::A, RrClass::IN, 300);
    records.add_record(Record {
        name: key.name.clone(),
        rr_type: RrType::A,
        class: RrClass::IN,
        ttl: 300,
        rdata: RData::A("192.0.2.19".parse().unwrap()),
    });
    cache.insert_positive(&key, records, NOW, ScoreInputs::default(), false);
    cache.insert_nxdomain(
        &Name::from_ascii("missing.example").unwrap(),
        Rcode::NXDOMAIN,
        None,
        60,
        NOW,
    );
    cache
}

#[test]
fn dns_cache_roundtrip_preserves_records_expiry_and_negative_answers() {
    let file = CacheFile::new();
    persist::save_to(&populated_cache(), &file.0, (NOW / SECOND) as i64).unwrap();
    let mut restored = SemanticCache::new(CacheConfig::default());
    assert_eq!(
        persist::load_from(&mut restored, &file.0, NOW + 20 * SECOND).unwrap(),
        2
    );
    let LookupOutcome::Fresh(entry) =
        restored.lookup(&key("codec.example", RrType::A), NOW + 20 * SECOND)
    else {
        panic!("expected a fresh cached record");
    };
    assert_eq!(entry.expires, NOW + 300 * SECOND);
    assert_eq!(
        entry.rrset().unwrap().records[0].rdata,
        RData::A("192.0.2.19".parse().unwrap())
    );
    assert!(
        !entry.validated,
        "persistence must not invent DNSSEC validation"
    );
    let LookupOutcome::NxDomain { expires, soa } =
        restored.lookup(&key("missing.example", RrType::AAAA), NOW + 20 * SECOND)
    else {
        panic!("negative cache entry was lost");
    };
    assert_eq!(expires, NOW + 60 * SECOND);
    assert!(soa.is_none());
}

#[test]
fn invalid_cache_frames_are_rejected_without_replacing_live_entries() {
    let file = CacheFile::new();
    let valid = persist::encode(&populated_cache(), (NOW / SECOND) as i64).unwrap();
    let mut trailing = valid.clone();
    trailing.push(0);
    for bytes in [valid[..valid.len() - 1].to_vec(), trailing, vec![0xfe]] {
        std::fs::write(&file.0, bytes).unwrap();
        let mut live = populated_cache();
        assert!(persist::load_from(&mut live, &file.0, NOW).is_err());
        assert!(live.lookup(&key("codec.example", RrType::A), NOW).is_hit());
    }
    std::fs::write(&file.0, &valid).unwrap();
    assert!(persist::load_from_limit(
        &mut populated_cache(),
        &file.0,
        NOW,
        (valid.len() - 1) as u64
    )
    .is_err());
}
