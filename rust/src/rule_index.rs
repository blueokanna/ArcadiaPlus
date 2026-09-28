//! A windowed view over the engine's rule table.
//!
//! `corduit::api::get_rules()` builds the whole table in one call — every
//! rule, its payload and its live hit count — and hands it across the FFI
//! boundary as a single message. A profile with an inline ACL list makes that
//! message tens of thousands of entries long, and its decode runs on the
//! Flutter UI isolate: the frame that receives it stalls for as long as the
//! decode takes, which is the "rule diagnostics freezes the app" report this
//! module exists to remove.
//!
//! Nothing about a diagnostic table needs every row at once, so the bridge
//! keeps one snapshot and serves windows and searches from it. The snapshot
//! is the *engine's* table, not a copy of a copy: it is refreshed when it is
//! older than [`SNAPSHOT_TTL`] or when the screen asks for a refresh, which is
//! also how a rule that starts firing while the screen is open becomes
//! visible.

use std::sync::Arc;
use std::time::{Duration, Instant};

use corduit as engine;
use parking_lot::Mutex;

use crate::types::{RuleDto, RuleSearchResultDto, RuleWindowDto};

const SNAPSHOT_TTL: Duration = Duration::from_secs(5);

pub const MAX_WINDOW: u32 = 500;
pub const MAX_SEARCH: u32 = 500;

struct Snapshot {
    taken_at: Instant,
    rules: Arc<Vec<engine::RuleDto>>,
}

/// The current snapshot, in a mutex rather than a channel: reads outnumber
/// writes, the critical section is a pointer swap, and the lock is never held
/// across the engine call.
static SNAPSHOT: Mutex<Option<Snapshot>> = Mutex::new(None);

fn snapshot(force: bool) -> Result<Arc<Vec<engine::RuleDto>>, String> {
    {
        let slot = SNAPSHOT.lock();
        if !force {
            if let Some(current) = slot.as_ref() {
                if current.taken_at.elapsed() < SNAPSHOT_TTL {
                    return Ok(Arc::clone(&current.rules));
                }
            }
        }
    }

    let fresh = Arc::new(engine::api::get_rules()?);
    let mut slot = SNAPSHOT.lock();
    *slot = Some(Snapshot {
        taken_at: Instant::now(),
        rules: Arc::clone(&fresh),
    });
    Ok(fresh)
}

/// Rules `offset..offset + limit` of the engine's table, with the total so a
/// screen can render its own paging state.
///
/// `refresh` bypasses the snapshot, which is what the screen's refresh action
/// and its pull-to-refresh pass: a diagnostic table that cannot be made to
/// re-read the engine is a screenshot, not a diagnostic.
pub fn window(offset: u32, limit: u32, refresh: bool) -> Result<RuleWindowDto, String> {
    let rules = snapshot(refresh)?;
    let (total, offset, slice) = slice(&rules, offset, limit);
    Ok(RuleWindowDto {
        total,
        offset,
        total_matches: total_matches(&rules),
        rules: slice,
    })
}

/// Case-insensitive substring match over type, payload and outbound.
///
/// The scan runs on the snapshot in Rust, so only the matches cross the
/// boundary: a query that matches every rule costs one bounded message, not
/// the whole table again.
pub fn search(needle: &str, limit: u32) -> Result<RuleSearchResultDto, String> {
    let rules = snapshot(false)?;
    let (matched, truncated, hits) = find(&rules, needle, limit);
    Ok(RuleSearchResultDto {
        matched,
        truncated,
        rules: hits,
    })
}

/// The clamped slice `offset..offset + limit` of [rules].
///
/// Pure so the boundary arithmetic — an offset past the end, a limit larger
/// than the table, a table that shrank between two windows — is tested
/// without an engine: those are exactly the cases a scrolling screen walks
/// through.
fn slice(rules: &[engine::RuleDto], offset: u32, limit: u32) -> (u32, u32, Vec<RuleDto>) {
    let total = u32::try_from(rules.len()).unwrap_or(u32::MAX);
    let offset = offset.min(total);
    let limit = limit.clamp(1, MAX_WINDOW);
    let end = offset.saturating_add(limit).min(total);
    let window = rules[offset as usize..end as usize]
        .iter()
        .map(RuleDto::from)
        .collect();
    (total, offset, window)
}

/// Every rule matching [needle], with the total count and whether the
/// returned list was cut off.
///
/// An empty query matches nothing: a search box that answers the empty string
/// with the whole table is a slower way of not filtering.
fn find(rules: &[engine::RuleDto], needle: &str, limit: u32) -> (u32, bool, Vec<RuleDto>) {
    let query = needle.trim().to_lowercase();
    if query.is_empty() {
        return (0, false, Vec::new());
    }

    let limit = limit.clamp(1, MAX_SEARCH);
    let mut matched: u32 = 0;
    let mut found = Vec::new();
    for rule in rules {
        if matches(rule, &query) {
            matched = matched.saturating_add(1);
            if found.len() < limit as usize {
                found.push(RuleDto::from(rule));
            }
        }
    }
    (matched, matched as usize > found.len(), found)
}

/// Hit counts summed over the whole table.
///
/// Saturating: the sum of counters the engine itself saturates is not a
/// number anyone can act on, and wrapping would turn a long-running total
/// into a small one.
fn total_matches(rules: &[engine::RuleDto]) -> u64 {
    rules
        .iter()
        .fold(0u64, |sum, rule| sum.saturating_add(rule.matched_count))
}

fn matches(rule: &engine::RuleDto, query: &str) -> bool {
    rule.rule_type.to_lowercase().contains(query)
        || rule.payload.to_lowercase().contains(query)
        || rule.outbound.to_lowercase().contains(query)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(rule_type: &str, payload: &str, outbound: &str) -> engine::RuleDto {
        engine::RuleDto {
            rule_type: rule_type.to_string(),
            payload: payload.to_string(),
            outbound: outbound.to_string(),
            matched_count: 0,
        }
    }
    fn table() -> Vec<engine::RuleDto> {
        vec![
            rule("DOMAIN-SUFFIX", "github.com", "Proxy"),
            rule("DOMAIN", "example.org", "DIRECT"),
            rule("IP-CIDR", "10.0.0.0/8", "DIRECT"),
            rule("MATCH", "", "Proxy"),
        ]
    }

    #[test]
    fn a_window_is_clamped_to_the_table() {
        let rules = table();

        let (total, offset, window) = slice(&rules, 0, 2);
        assert_eq!((total, offset), (4, 0));
        assert_eq!(window.len(), 2);
        assert_eq!(window[1].payload, "example.org");

        // Past the end: an empty window, still with the true total.
        let (total, offset, window) = slice(&rules, 99, 10);
        assert_eq!((total, offset), (4, 4));
        assert!(window.is_empty());

        // A limit of zero is a caller mistake, not an empty page.
        let (_, _, window) = slice(&rules, 1, 0);
        assert_eq!(window.len(), 1);
        assert_eq!(window[0].payload, "example.org");
    }

    #[test]
    fn hit_counts_are_summed_with_saturation() {
        let mut rules = table();
        rules[0].matched_count = 2;
        rules[1].matched_count = 3;
        assert_eq!(total_matches(&rules), 5);

        rules[2].matched_count = u64::MAX;
        assert_eq!(total_matches(&rules), u64::MAX);
    }

    #[test]
    fn search_is_case_insensitive_and_bounded() {
        let rules = table();

        let (matched, truncated, hits) = find(&rules, "PROXY", 10);
        assert_eq!(matched, 2);
        assert!(!truncated);
        assert_eq!(hits.len(), 2);

        let (matched, truncated, hits) = find(&rules, "direct", 1);
        assert_eq!(matched, 2);
        assert!(truncated);
        assert_eq!(hits.len(), 1);

        let (matched, _, hits) = find(&rules, "  ", 10);
        assert_eq!(matched, 0);
        assert!(hits.is_empty());
    }

    #[test]
    fn matching_covers_type_payload_and_outbound() {
        let candidate = rule("DOMAIN-SUFFIX", "GitHub.com", "Proxy");
        assert!(matches(&candidate, "github"));
        assert!(matches(&candidate, "proxy"));
        assert!(matches(&candidate, "domain-suffix"));
        assert!(!matches(&candidate, "baidu"));
    }
}
