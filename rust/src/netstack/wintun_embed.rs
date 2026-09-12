#[cfg(windows)]
use crate::netstack::error::{NetStackError, Result};

#[cfg(windows)]
use std::path::PathBuf;

#[cfg(windows)]
use tracing::{debug, info, warn};

#[cfg(windows)]
use once_cell::sync::OnceCell;

#[cfg(windows)]
static WINTUN_INSTANCE: OnceCell<wintun_bindings::Wintun> = OnceCell::new();

#[cfg(windows)]
const WINTUN_DLL_BYTES: Option<&[u8]> = None;

/// Wintun download URL
#[cfg(windows)]
const WINTUN_DOWNLOAD_URL: &str = "https://www.wintun.net/builds/wintun-0.14.1.zip";

/// Hosts allowed to serve the archive (the vendor plus its own CDN).
#[cfg(windows)]
const WINTUN_ALLOWED_HOSTS: &[&str] = &["wintun.net", "www.wintun.net"];

/// Redirect hops the downloader will follow before giving up.
#[cfg(windows)]
const WINTUN_MAX_REDIRECTS: usize = 3;

/// Refuse a download whose host is not on the vendor allow-list.
///
/// Checked before every hop, so an injected redirect cannot move the download
/// to an attacker's host that would then serve a DLL for us to load.
#[cfg(windows)]
fn ensure_allowed_host(url: &str) -> Result<()> {
    let parsed = corduit::common::url::Url::parse(url).map_err(|error| {
        NetStackError::TunError(format!("Refusing unparsable download URL '{url}': {error}"))
    })?;

    if parsed.scheme() != "https" {
        return Err(NetStackError::TunError(format!(
            "Refusing non-HTTPS download URL '{url}'"
        )));
    }

    let host = parsed
        .host_str()
        .unwrap_or_default()
        .trim_start_matches("www.")
        .to_ascii_lowercase();

    if WINTUN_ALLOWED_HOSTS
        .iter()
        .map(|allowed| allowed.trim_start_matches("www."))
        .any(|allowed| allowed == host)
    {
        return Ok(());
    }

    Err(NetStackError::TunError(format!(
        "Refusing archive from unexpected host '{host}'"
    )))
}

/// Hard ceiling for the archive we are willing to buffer in memory.
#[cfg(windows)]
const WINTUN_ARCHIVE_LIMIT: usize = 8 * 1024 * 1024;

/// Opt-in switch for the in-app downloader (`1`, `true`, `yes`).
#[cfg(windows)]
const WINTUN_ALLOW_DOWNLOAD_ENV: &str = "VELOGUARD_ALLOW_WINTUN_DOWNLOAD";

/// SHA-256 (hex) of the **extracted** `wintun.dll` that the caller expects.
#[cfg(windows)]
const WINTUN_SHA256_ENV: &str = "VELOGUARD_WINTUN_SHA256";

/// Get the path where wintun.dll should be located
#[cfg(windows)]
pub fn get_wintun_dll_path() -> Result<PathBuf> {
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            return Ok(exe_dir.join("wintun.dll"));
        }
    }
    Ok(std::env::current_dir()
        .map_err(|e| NetStackError::TunError(format!("Failed to get current directory: {}", e)))?
        .join("wintun.dll"))
}

/// Check if wintun.dll exists at the expected location
#[cfg(windows)]
pub fn is_wintun_available() -> bool {
    get_wintun_dll_path().map(|p| p.exists()).unwrap_or(false)
}

/// Extract embedded wintun.dll to the executable directory
#[cfg(windows)]
pub fn extract_wintun_dll() -> Result<PathBuf> {
    let dll_path = get_wintun_dll_path()?;

    if dll_path.exists() {
        debug!("wintun.dll already exists at {:?}", dll_path);
        return Ok(dll_path);
    }

    match WINTUN_DLL_BYTES {
        Some(bytes) => {
            info!("Extracting embedded wintun.dll to {:?}", dll_path);
            std::fs::write(&dll_path, bytes).map_err(|e| {
                NetStackError::TunError(format!("Failed to write wintun.dll: {}", e))
            })?;
            info!("wintun.dll extracted successfully ({} bytes)", bytes.len());
            Ok(dll_path)
        }
        None => {
            warn!("No embedded wintun.dll available");
            warn!("Please download from https://www.wintun.net/ or use download_wintun_dll()");
            Err(NetStackError::TunNotAvailable)
        }
    }
}

/// Ensure wintun.dll is available
#[cfg(windows)]
pub fn ensure_wintun_available() -> Result<PathBuf> {
    if is_wintun_available() {
        get_wintun_dll_path()
    } else {
        extract_wintun_dll()
    }
}

/// Download wintun.dll from the official source
/// Download `wintun.dll` from the vendor archive and install it next to the
/// current executable.
///
/// # Why this is opt-in
///
/// The archive is fetched over HTTPS, but this process has no way to verify
/// *what* the vendor served: the DLL is not signed with a certificate chain we
/// can validate here, and a hijacked DNS answer or compromised mirror would
/// otherwise be able to drop arbitrary native code into the process image
/// directory — code that `load_wintun` then loads into this process. So the
/// downloader refuses to run unless the operator explicitly accepts the trade
/// and pins the artifact:
///
/// * `VELOGUARD_ALLOW_WINTUN_DOWNLOAD=1` — acknowledge that a network download
///   will be trusted;
/// * `VELOGUARD_WINTUN_SHA256=<hex>` — SHA-256 of the **extracted**
///   `wintun.dll`; the bytes are hashed before anything touches the disk and a
///   mismatch aborts the install.
///
/// Callers that cannot provide a hash should ship Wintun with the application
/// (or point users at the vendor's signed installer) instead of calling this.
#[cfg(windows)]
pub async fn download_wintun_dll() -> Result<PathBuf> {
    use crate::crypto::Sha256;
    use std::io::Write;

    let dll_path = get_wintun_dll_path()?;

    if dll_path.exists() {
        return Ok(dll_path);
    }

    let allow_download = std::env::var(WINTUN_ALLOW_DOWNLOAD_ENV)
        .map(|value| {
            let value = value.trim().to_ascii_lowercase();
            value == "1" || value == "true" || value == "yes"
        })
        .unwrap_or(false);
    if !allow_download {
        return Err(NetStackError::TunError(format!(
            "Refusing to download wintun.dll implicitly. Install Wintun from the \
             vendor (https://www.wintun.net/) and place wintun.dll next to the \
             executable, or set {WINTUN_ALLOW_DOWNLOAD_ENV}=1 together with \
             {WINTUN_SHA256_ENV}=<sha256 of the extracted dll> to accept a \
             network download."
        )));
    }

    let expected_hash = std::env::var(WINTUN_SHA256_ENV)
        .map_err(|_| {
            NetStackError::TunError(format!(
                "{WINTUN_SHA256_ENV} must pin the SHA-256 of the extracted wintun.dll \
                 before a download is allowed"
            ))
        })?
        .trim()
        .to_ascii_lowercase();
    if expected_hash.len() != 64 || !expected_hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(NetStackError::TunError(format!(
            "{WINTUN_SHA256_ENV} must be a 64 character hex digest"
        )));
    }

    info!("Downloading wintun.dll from {}...", WINTUN_DOWNLOAD_URL);

    // Redirects are followed by hand rather than by the client, because each
    // hop is a decision: the archive is native code that will be loaded into
    // this process, so a hop that leaves the vendor's hosts must be refused
    // before the body is read, not classified afterwards.
    let mut url = WINTUN_DOWNLOAD_URL.to_string();
    let mut hops = 0usize;
    let archive_bytes = loop {
        ensure_allowed_host(&url)?;

        let exchange = crate::http::exchange(
            &url,
            crate::http::RequestOptions {
                body_limit: WINTUN_ARCHIVE_LIMIT,
                max_redirects: 0,
            },
        )
        .await
        .map_err(|error| NetStackError::TunError(format!("Failed to download wintun: {error}")))?;

        if !exchange.is_redirect() {
            break exchange.into_body();
        }

        let location = exchange.location.ok_or_else(|| {
            NetStackError::TunError(format!("{url} redirected without a Location header"))
        })?;
        hops += 1;
        if hops > WINTUN_MAX_REDIRECTS {
            return Err(NetStackError::TunError(format!(
                "wintun download exceeded {WINTUN_MAX_REDIRECTS} redirects"
            )));
        }
        url = crate::http::resolve_redirect(&url, &location)
            .map_err(|error| NetStackError::TunError(format!("Refusing redirect: {error}")))?;
    };

    info!("Downloaded {} bytes, extracting...", archive_bytes.len());

    let cursor = std::io::Cursor::new(archive_bytes);
    let mut archive = zip::ZipArchive::new(cursor)
        .map_err(|e| NetStackError::TunError(format!("Failed to open zip: {e}")))?;

    #[cfg(target_arch = "x86_64")]
    let dll_name = "wintun/bin/amd64/wintun.dll";
    #[cfg(target_arch = "aarch64")]
    let dll_name = "wintun/bin/arm64/wintun.dll";
    #[cfg(target_arch = "x86")]
    let dll_name = "wintun/bin/x86/wintun.dll";

    let mut dll_file = archive
        .by_name(dll_name)
        .map_err(|e| NetStackError::TunError(format!("Failed to find {dll_name}: {e}")))?;

    let mut dll_bytes = Vec::new();
    std::io::Read::read_to_end(&mut dll_file, &mut dll_bytes)
        .map_err(|e| NetStackError::TunError(format!("Failed to read DLL: {e}")))?;

    let actual_hash = crate::crypto::hex::encode(Sha256::digest(&dll_bytes));
    if actual_hash != expected_hash {
        return Err(NetStackError::TunError(format!(
            "wintun.dll SHA-256 mismatch (expected {expected_hash}, got {actual_hash}); \
             nothing was written to disk"
        )));
    }

    // Write through a temporary file so a crash or a full disk cannot leave a
    // half written DLL behind for the loader to pick up.
    let staging = dll_path.with_extension("dll.part");
    {
        let mut output_file = std::fs::File::create(&staging).map_err(|e| {
            NetStackError::TunError(format!("Failed to create {}: {e}", staging.display()))
        })?;
        output_file.write_all(&dll_bytes).map_err(|e| {
            NetStackError::TunError(format!("Failed to write {}: {e}", staging.display()))
        })?;
        output_file.sync_all().map_err(|e| {
            NetStackError::TunError(format!("Failed to flush {}: {e}", staging.display()))
        })?;
    }
    std::fs::rename(&staging, &dll_path).map_err(|e| {
        let _ = std::fs::remove_file(&staging);
        NetStackError::TunError(format!("Failed to install {}: {e}", dll_path.display()))
    })?;

    info!(
        "wintun.dll verified (sha256 {}) and installed at {:?} ({} bytes)",
        actual_hash,
        dll_path,
        dll_bytes.len()
    );
    Ok(dll_path)
}

/// Load the wintun library, downloading if necessary
#[cfg(windows)]
pub async fn load_wintun() -> Result<&'static wintun_bindings::Wintun> {
    if let Some(wintun) = WINTUN_INSTANCE.get() {
        return Ok(wintun);
    }

    let dll_path = match ensure_wintun_available() {
        Ok(path) => path,
        Err(_) => download_wintun_dll().await?,
    };

    info!("Loading wintun.dll from {:?}", dll_path);

    let wintun = unsafe {
        wintun_bindings::load_from_path(&dll_path)
            .map_err(|e| NetStackError::TunError(format!("Failed to load wintun.dll: {}", e)))?
    };

    info!("Wintun library loaded successfully");

    let _ = WINTUN_INSTANCE.set(wintun);
    Ok(WINTUN_INSTANCE.get().unwrap())
}

/// Load wintun synchronously
#[cfg(windows)]
pub fn load_wintun_sync() -> Result<&'static wintun_bindings::Wintun> {
    if let Some(wintun) = WINTUN_INSTANCE.get() {
        return Ok(wintun);
    }

    let dll_path = ensure_wintun_available()?;
    info!("Loading wintun.dll from {:?}", dll_path);

    let wintun = unsafe {
        wintun_bindings::load_from_path(&dll_path)
            .map_err(|e| NetStackError::TunError(format!("Failed to load wintun.dll: {}", e)))?
    };

    info!("Wintun library loaded successfully");

    let _ = WINTUN_INSTANCE.set(wintun);
    Ok(WINTUN_INSTANCE.get().unwrap())
}

/// Get the loaded wintun instance
#[cfg(windows)]
pub fn get_wintun() -> Option<&'static wintun_bindings::Wintun> {
    WINTUN_INSTANCE.get()
}

// Non-Windows stubs
#[cfg(not(windows))]
pub fn is_wintun_available() -> bool {
    true
}

#[cfg(not(windows))]
pub fn ensure_wintun_available() -> Result<std::path::PathBuf> {
    Ok(std::path::PathBuf::new())
}

#[cfg(not(windows))]
use crate::netstack::error::Result;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(windows)]
    fn test_get_wintun_path() {
        let path = get_wintun_dll_path();
        assert!(path.is_ok());
        assert!(path.unwrap().ends_with("wintun.dll"));
    }
}
