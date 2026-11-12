//! Private, versioned restart state for Android's foreground VPN service.
//! Only a successfully started tunnel arms persistence. Explicit disconnects
//! disarm it before any native teardown, so service recreation cannot reconnect.

use nextjson::{NsonDeserialize, NsonSerialize};
use parking_lot::Mutex;
use std::collections::BTreeMap;
use std::io::{BufWriter, Read, Write};
use std::path::{Path, PathBuf};

const MAX_SNAPSHOT: u64 = 32 * 1024 * 1024;

#[derive(Default, Clone, NsonSerialize, NsonDeserialize)]
struct Snapshot {
    version: u32,
    config: String,
    selections: BTreeMap<String, String>,
    mode: i32,
    geoip: Option<String>,
    recursion: Option<(String, Option<String>)>,
}

#[derive(Default)]
struct Store {
    path: Option<PathBuf>,
    state: Snapshot,
}

static STORE: Mutex<Store> = Mutex::new(Store {
    path: None,
    state: Snapshot {
        version: 1,
        config: String::new(),
        selections: BTreeMap::new(),
        mode: 3,
        geoip: None,
        recursion: None,
    },
});

pub(crate) fn configuration(config: String) {
    let mut store = STORE.lock();
    store.state.config = config;
    checkpoint(&mut store);
}

pub(crate) fn geoip(path: String) {
    STORE.lock().state.geoip = Some(path);
}
pub(crate) fn recursion(listen: String, cache: Option<String>) {
    STORE.lock().state.recursion = Some((listen, cache));
}
pub(crate) fn clear_recursion() {
    STORE.lock().state.recursion = None;
}

pub(crate) fn changed() {
    checkpoint(&mut STORE.lock());
}

fn capture(state: &mut Snapshot) -> Result<(), String> {
    state.mode = corduit::api::get_proxy_mode().map_err(|e| e.to_string())?;
    state.selections = corduit::api::get_proxy_groups()?
        .into_iter()
        .filter(|group| group.group_type == "selector" || group.group_type == "select")
        .map(|group| (group.tag, group.selected))
        .collect();
    Ok(())
}

fn checkpoint(store: &mut Store) {
    let Some(path) = &store.path else { return };
    if let Err(error) = capture(&mut store.state).and_then(|()| write_snapshot(path, &store.state))
    {
        tracing::error!("Cannot save VPN restart state: {error}");
    }
}

pub(crate) fn arm(path: &Path) -> Result<(), String> {
    let mut store = STORE.lock();
    if store.state.config.is_empty() {
        return Err("No configuration available for VPN restart".into());
    }
    capture(&mut store.state)?;
    write_snapshot(path, &store.state)?;
    store.path = Some(path.to_owned());
    Ok(())
}

pub(crate) fn disarm() {
    let mut store = STORE.lock();
    if let Some(path) = store.path.take()
        && let Err(error) = std::fs::remove_file(path)
        && error.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!("Cannot remove disconnected VPN restart state: {error}");
    }
}

fn write_snapshot(path: &Path, state: &Snapshot) -> Result<(), String> {
    write_snapshot_with_limit(path, state, MAX_SNAPSHOT)
}

/// Enforce the encoded size while streaming; JSON escaping can expand input.
struct SnapshotWriter<W> {
    output: W,
    remaining: u64,
}

impl<W: Write> nextjson::Write for SnapshotWriter<W> {
    fn write_all(&mut self, bytes: &[u8]) -> nextjson::Result<()> {
        if bytes.len() as u64 > self.remaining {
            return Err(nextjson::Error::custom(
                "VPN restart state exceeds size limit",
            ));
        }
        self.output
            .write_all(bytes)
            .map_err(|e| nextjson::Error::custom(e.to_string()))?;
        self.remaining -= bytes.len() as u64;
        Ok(())
    }

    fn flush(&mut self) -> nextjson::Result<()> {
        self.output
            .flush()
            .map_err(|e| nextjson::Error::custom(e.to_string()))
    }
}

/// NextJson buffers one string before flushing it. Keep each escaped fragment
/// small while preserving the existing version-1 JSON format and its decoder.
fn write_json_string(writer: &mut impl nextjson::Write, mut value: &str) -> nextjson::Result<()> {
    writer.write_all(b"\"")?;
    while !value.is_empty() {
        let mut end = value.len().min(4096);
        while !value.is_char_boundary(end) {
            end -= 1;
        }
        let encoded = nextjson::to_vec(&value[..end])?;
        writer.write_all(&encoded[1..encoded.len() - 1])?;
        value = &value[end..];
    }
    writer.write_all(b"\"")
}

fn write_optional_string(
    writer: &mut impl nextjson::Write,
    value: Option<&str>,
) -> nextjson::Result<()> {
    match value {
        Some(value) => write_json_string(writer, value),
        None => writer.write_all(b"null"),
    }
}

fn write_snapshot_json(
    writer: &mut impl nextjson::Write,
    state: &Snapshot,
) -> nextjson::Result<()> {
    writer.write_all(b"{\"version\":")?;
    nextjson::to_writer(&mut *writer, &state.version)?;
    writer.write_all(b",\"config\":")?;
    write_json_string(writer, &state.config)?;
    writer.write_all(b",\"selections\":{")?;
    for (index, (group, member)) in state.selections.iter().enumerate() {
        if index > 0 {
            writer.write_all(b",")?;
        }
        write_json_string(writer, group)?;
        writer.write_all(b":")?;
        write_json_string(writer, member)?;
    }
    writer.write_all(b"},\"mode\":")?;
    nextjson::to_writer(&mut *writer, &state.mode)?;
    writer.write_all(b",\"geoip\":")?;
    write_optional_string(writer, state.geoip.as_deref())?;
    writer.write_all(b",\"recursion\":")?;
    if let Some((listen, cache)) = &state.recursion {
        writer.write_all(b"[")?;
        write_json_string(writer, listen)?;
        writer.write_all(b",")?;
        write_optional_string(writer, cache.as_deref())?;
        writer.write_all(b"]")?;
    } else {
        writer.write_all(b"null")?;
    }
    writer.write_all(b"}")?;
    writer.flush()
}

fn write_snapshot_with_limit(path: &Path, state: &Snapshot, limit: u64) -> Result<(), String> {
    let temporary = path.with_extension("pending");
    let mut options = std::fs::OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| {
        let file = options.open(&temporary).map_err(|e| e.to_string())?;
        let mut writer = SnapshotWriter {
            output: BufWriter::with_capacity(8192, file),
            remaining: limit,
        };
        write_snapshot_json(&mut writer, state).map_err(|e| e.to_string())?;
        writer
            .output
            .get_ref()
            .sync_all()
            .map_err(|e| e.to_string())?;
        drop(writer);
        std::fs::rename(&temporary, path).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

fn read_snapshot(path: &Path) -> Result<Snapshot, String> {
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    file.take(MAX_SNAPSHOT + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_SNAPSHOT {
        return Err("VPN restart state exceeds 32 MiB".into());
    }
    let snapshot: Snapshot =
        nextjson::from_slice(&bytes).map_err(|_| "Invalid VPN restart state")?;
    if snapshot.version != 1 || snapshot.config.is_empty() {
        return Err("Unsupported VPN restart state".into());
    }
    Ok(snapshot)
}

pub(crate) fn restore(path: &Path) -> Result<(), String> {
    if corduit::api::is_proxy_running().unwrap_or(false) {
        return Ok(());
    }
    let state = read_snapshot(path)?;
    // All saved selectors are restored before listeners or TUN accept traffic.
    let result = (|| {
        if let Some(path) = &state.geoip {
            corduit::engine::geoip::set_default_database_path(Path::new(path))
                .map_err(|e| e.to_string())?;
        }
        if let Some((listen, cache)) = &state.recursion {
            crate::recursive_dns::start(listen, cache.as_deref())?;
        }
        corduit::api::initialize_corduit(state.config.clone()).map_err(|e| e.to_string())?;
        for (group, member) in &state.selections {
            corduit::api::select_proxy(group.clone(), member.clone()).map_err(|e| e.to_string())?;
        }
        corduit::api::set_proxy_mode(state.mode).map_err(|e| e.to_string())?;
        corduit::api::start_corduit().map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = corduit::api::stop_corduit();
        let _ = crate::recursive_dns::stop();
        return result;
    }
    *STORE.lock() = Store {
        path: Some(path.to_owned()),
        state,
    };
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn large_strings_stream_in_bounded_fragments_and_preserve_utf8_and_escapes() {
        struct Capture {
            bytes: Vec<u8>,
            largest_write: usize,
        }
        impl nextjson::Write for Capture {
            fn write_all(&mut self, bytes: &[u8]) -> nextjson::Result<()> {
                self.largest_write = self.largest_write.max(bytes.len());
                self.bytes.extend_from_slice(bytes);
                Ok(())
            }
        }
        let text = format!("{}🙂\u{0001}\"\\\n", "a".repeat(4095)).repeat(256);
        let state = Snapshot {
            version: 1,
            config: text.clone(),
            selections: BTreeMap::from([(text.clone(), "节点🙂".into())]),
            mode: 2,
            geoip: Some("路径\\db".into()),
            recursion: Some(("127.0.0.1:5353".into(), Some(text.clone()))),
        };
        let mut capture = Capture {
            bytes: Vec::new(),
            largest_write: 0,
        };
        write_snapshot_json(&mut capture, &state).unwrap();
        assert!(capture.largest_write <= 4096 * 6);
        let decoded: Snapshot = nextjson::from_slice(&capture.bytes).unwrap();
        assert_eq!(decoded.config, state.config);
        assert_eq!(decoded.selections, state.selections);
        assert_eq!(decoded.geoip, state.geoip);
        assert_eq!(decoded.recursion, state.recursion);
        assert_eq!(decoded.mode, state.mode);
    }

    #[test]
    fn oversized_encoding_preserves_the_previous_snapshot() {
        let path = std::env::temp_dir().join(format!(
            "arcadia-snapshot-limit-{}.json",
            std::process::id()
        ));
        let previous = Snapshot {
            version: 1,
            config: "previous".into(),
            ..Snapshot::default()
        };
        write_snapshot(&path, &previous).unwrap();
        let replacement = Snapshot {
            config: "\u{0001}".repeat(128),
            ..previous.clone()
        };
        assert!(write_snapshot_with_limit(&path, &replacement, 256).is_err());
        assert_eq!(read_snapshot(&path).unwrap().config, "previous");
        assert!(!path.with_extension("pending").exists());
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn snapshot_round_trip_preserves_private_config_and_selections() {
        let directory = std::env::temp_dir().join(format!("arcadia-resume-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("session.json");
        let state = Snapshot {
            version: 1,
            config: "{\"password\":\"secret\"}".into(),
            selections: BTreeMap::from([("group".into(), "node".into())]),
            mode: 1,
            geoip: Some("/private/Country.mmdb".into()),
            recursion: Some(("127.0.0.1:5354".into(), None)),
        };
        write_snapshot(&path, &state).unwrap();
        let restored = read_snapshot(&path).unwrap();
        assert_eq!(restored.config, state.config);
        assert_eq!(restored.selections, state.selections);
        assert_eq!(restored.recursion, state.recursion);
        assert_eq!(restored.mode, 1);
        std::fs::write(&path, b"{\"version\":99}").unwrap();
        assert!(read_snapshot(&path).is_err());
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn restart_restores_engine_selection_and_explicit_stop_disarms_it() {
        let path =
            std::env::temp_dir().join(format!("arcadia-live-resume-{}.json", std::process::id()));
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let config = r#"{
          "general":{"mode":"rule","mixed_port":$PORT,"allow_lan":false,"bind_address":"127.0.0.1","log_level":"warn","ipv6":false,"tcp_concurrent":false},
          "dns":{"enable":false,"listen":"127.0.0.1:0","nameservers":[],"fallback":[],"enhanced_mode":"normal"},
          "inbounds":[{"inbound_type":"mixed","tag":"mixed","listen":"127.0.0.1","port":$PORT,"options":"{}"}],
          "outbounds":[{"outbound_type":"direct","tag":"DIRECT","options":"{}"},
            {"outbound_type":"reject","tag":"BLOCK","options":"{}"},
            {"outbound_type":"selector","tag":"choice","options":"{\"outbounds\":[\"DIRECT\",\"BLOCK\"]}"}],
          "rules":[{"rule_type":"match","payload":"","outbound":"choice"}] }"#.replace("$PORT", &port.to_string());
        corduit::api::initialize_corduit(config.clone()).unwrap();
        configuration(config);
        corduit::api::select_proxy("choice".into(), "BLOCK".into()).unwrap();
        corduit::api::set_proxy_mode(1).unwrap();
        corduit::api::start_corduit().unwrap();
        arm(&path).unwrap();
        assert_eq!(
            read_snapshot(&path)
                .unwrap()
                .selections
                .get("choice")
                .unwrap(),
            "BLOCK"
        );
        corduit::api::stop_corduit().unwrap();
        *STORE.lock() = Store::default(); // process death loses memory, not the file
        restore(&path).unwrap();
        assert!(corduit::api::is_proxy_running().unwrap());
        assert_eq!(corduit::api::get_proxy_mode().unwrap(), 1);
        assert_eq!(
            corduit::api::get_selected_proxy_in_group("choice".into())
                .unwrap()
                .as_deref(),
            Some("BLOCK")
        );
        disarm();
        corduit::api::stop_corduit().unwrap();
        assert!(!path.exists());
        assert!(restore(&path).is_err());
    }
}
