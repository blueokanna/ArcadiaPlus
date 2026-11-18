//! Geo database installation, shared by every entry point that feeds the
//! engine's Geo rules.
//!
//! The engine reads three file shapes and decides which one it is holding from
//! the bytes rather than the name: a MaxMind `Country.mmdb` and a v2ray
//! `geoip.dat` both answer address ownership, a `geosite.dat` answers category
//! membership. A profile may ship either family, so this module keeps the
//! decision in one place instead of leaving every caller to guess.
//!
//! # Why installation is verified
//!
//! Registering a path only *records* it. The router loads the file much later,
//! inside `initialize_corduit`, and one it cannot read leaves `GEOIP` and
//! `GEOSITE` rules silent: every such rule falls through to the next one, the
//! engine keeps routing, and the only trace is a log line nobody is reading on
//! a phone. Running the engine's own installer here — on the blocking worker
//! that called us, before anything is registered — turns that into an error the
//! caller can surface, and the engine's own reason is kept in the message so a
//! truncated download and a wrong file read differently.
//!
//! The half a file feeds matters: `geosite.dat` belongs to the category setter
//! and the address databases to the address setter, and the router reads the
//! two defaults separately. A `geosite.dat` handed to the address setter would
//! still load, but only because both setters end in the same content sniffing —
//! relying on that would break the moment the defaults diverge.

use std::path::Path;

use corduit as engine;
use engine::engine::geo::DatabaseKind;
use engine::engine::geoip::{self, GeoIpDatabase};

/// Install `path` as a Geo database and report which kind it was.
///
/// The returned kind is what the router will answer from: [`DatabaseKind::Mmdb`]
/// or [`DatabaseKind::GeoIp`] for the address half, [`DatabaseKind::GeoSite`]
/// for the category half.
pub(crate) fn install(path: &Path) -> Result<DatabaseKind, String> {
    if !path.is_file() {
        return Err(format!("Geo database not found at {}", path.display()));
    }

    let mut probe = GeoIpDatabase::new();
    match probe.install_file(path) {
        Ok(DatabaseKind::GeoSite) => {
            geoip::set_default_geosite_path(path).map_err(|error| error.to_string())?;
            Ok(DatabaseKind::GeoSite)
        }
        Ok(kind @ (DatabaseKind::Mmdb | DatabaseKind::GeoIp)) => {
            geoip::set_default_database_path(path).map_err(|error| error.to_string())?;
            Ok(kind)
        }
        // `install_file` refuses anything it cannot classify, so this arm only
        // runs if the engine grows a kind this module has not been taught.
        Ok(kind) => Err(format!(
            "{} is a '{}' database, which this build has no setter for",
            path.display(),
            kind.as_str()
        )),
        // The engine's own reason is the useful half of this message: it names
        // which of the three formats it wanted, or what parsing the file failed
        // on. Restating it would only bury that.
        Err(error) => Err(format!(
            "{} cannot be used as a Geo database ({error}); expected a MaxMind \
             Country.mmdb, a geoip.dat or a geosite.dat",
            path.display()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "arcadia-geo-database-{}-{name}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).expect("scratch directory");
        directory.join("database.dat")
    }

    /// A minimal well-formed `geosite.dat`: one category holding one plain
    /// domain. Written by hand because the point is to test the installer, not
    /// to ship a copy of the community database.
    fn geosite_payload() -> Vec<u8> {
        fn length_delimited(field: u8, body: &[u8]) -> Vec<u8> {
            let mut out = vec![field << 3 | 2];
            out.push(u8::try_from(body.len()).expect("short body"));
            out.extend_from_slice(body);
            out
        }

        let domain = length_delimited(2, b"example.com");
        let mut entry = length_delimited(1, b"arcadia-test");
        entry.extend_from_slice(&length_delimited(2, &domain));
        length_delimited(1, &entry)
    }

    #[test]
    fn a_geosite_database_is_installed_into_the_category_half() {
        let path = scratch("geosite");
        std::fs::write(&path, geosite_payload()).expect("write fixture");

        assert_eq!(
            install(&path).expect("a well-formed geosite file installs"),
            DatabaseKind::GeoSite
        );

        std::fs::remove_file(&path).expect("remove fixture");
    }

    #[test]
    fn a_missing_file_names_the_path() {
        let missing = std::env::temp_dir().join("arcadia-geo-database-does-not-exist.dat");
        let error = install(&missing).expect_err("a missing file cannot install");
        assert!(
            error.contains("Geo database not found"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn an_unreadable_payload_is_refused_with_the_formats_it_wanted() {
        let path = scratch("garbage");
        std::fs::write(&path, b"this is not a geo database").expect("write fixture");

        let error = install(&path).expect_err("garbage must be refused");
        for expected in [
            "cannot be used as a Geo database",
            "Country.mmdb",
            "geosite.dat",
        ] {
            assert!(
                error.contains(expected),
                "the refusal must name {expected}: {error}"
            );
        }

        std::fs::remove_file(&path).expect("remove fixture");
    }

    /// A truncated database is the case that separates "not a database" from
    /// "a database this build cannot finish reading": the engine parses the
    /// trailer and fails on the metadata that should follow it, and the message
    /// has to carry that reason rather than call the file an unknown format.
    #[test]
    fn a_truncated_maxmind_database_reports_the_parse_failure() {
        let path = scratch("truncated");
        let mut payload = vec![0u8; 64];
        payload.extend_from_slice(b"\xab\xcd\xefMaxMind.com");
        std::fs::write(&path, &payload).expect("write fixture");

        let error = install(&path).expect_err("a database with no metadata cannot install");
        assert!(
            error.contains("Country.mmdb") && error.contains("MaxMind"),
            "the refusal must name the metadata problem: {error}"
        );

        std::fs::remove_file(&path).expect("remove fixture");
    }
}
