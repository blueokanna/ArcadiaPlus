# Changelog

## 1.0.3

- Fixed legacy VMess subscriptions ("the node works in Clash but every connection dies within a quarter second here"): servers configured with `alterId > 0` expect the pre-AEAD handshake, and an AEAD-only client is dropped without a single byte of error — no WARN, no RST cause, nothing a log can show. The engine now mirrors what Clash-family clients do: `alterId > 0` selects the legacy handshake (`HMAC-MD5` over the timestamp with one of the derived alter IDs, the whole request header sealed with AES-128-CFB keyed by `MD5(uuid ‖ salt)` and a timestamp-derived IV, a four-byte CFB response header), one alter ID picked per connection from the same `MD5` chain the server derives, while the body keeps the standard chunked GCM framing (only the response keys switch from SHA-256 to MD5 derivation). Verified against the live subscription: a request through the engine now returns the node's exit IP, cross-checked against the user's Clash Verge on the same machine and node. Covered by NIST SP 800-38A CFB vectors, independently pinned MD5 vectors, a server-side-style decode test of the legacy header, and an end-to-end legacy downlink test.
- Fixed subscription DNS delivery: a `nameserver-policy` written with a scalar value (`+.example.com: tcp://…`, which Clash accepts) was silently dropped because the converter only understood the list form — the engine then received an empty policy, fell back to public DNS and every node domain answer became NXDOMAIN or a decoy. Scalar and list forms of `nameserver`, `fallback` and every `nameserver-policy` value now normalise through one helper, with a regression test.
- Pinned the engine's DNS resolver to the engine itself: the resolver was only configured inside the FFI config conversion path, so `start_proxy_from_yaml` / `reload_config_from_yaml` (which parse the engine config directly) ran without it. Configuration now lives at the single chokepoint every engine start crosses (`Corduit::new` / `reload`), and after log initialization so the startup line lands in the log buffer.
- Fixed subscription node connectivity end to end: profiles route their own node domains through a private `nameserver-policy` resolver (typically a TCP DNS like `tcp://<host>:8080` under `+.v51124-6.qpon`), and the engine resolved those names through the system resolver instead — a public lookup answers NXDOMAIN (an instant, error-less drop) or a decoy address (a black hole). The engine now keeps a process-wide resolver fed from the profile's DNS settings: `nameserver-policy` first (longest suffix wins, `+.`/`*.`/bare keys all understood, five-minute positive cache), then `nameservers`, with the system resolver only as a fallback when no engine DNS is configured. Outbound sockets (TCP, UDP and QUIC) are now protected from the engine's own tunnel via `VpnService.protect` before connect/bind, HTTP CONNECT relay failures log at warning level with outbound, target and cause (instead of a silent debug line), and the routine peer-close `Proxy->App: EOF` notice dropped from info to debug so normal connection closes stop looking like errors.
- Fixed VMess end to end (corduit 0.1.6), verified against a reference Xray server over plain TCP, ChaCha20-Poly1305, WebSocket, WebSocket + TLS 1.3, TCP + TLS 1.3 and the VMess UDP command. Five root causes were removed: the AEAD request header's encrypted length field carried the ciphertext size instead of the plaintext header size, so a v2ray/xray server read sixteen bytes past the header, failed the GCM open and drained the connection — every tunneled connection stalled briefly and then died as a bare `Proxy->App: EOF`; the response header was pre-read before relaying, deadlocking against servers that (per the reference implementation) buffer it until the first target payload arrives (the downlink now consumes it lazily through a resumable framing state machine); the ChaCha20-Poly1305 key was derived as `key‖key` instead of `MD5(key)‖MD5(MD5(key))`; WebSocket + TLS advertised `h2` in its ALPN offer, so the server negotiated HTTP/2 and the HTTP/1.1 upgrade became a protocol error (WebSocket now offers `http/1.1` only, raw TLS keeps `h2` + `http/1.1`, and an explicit `alpn` option — now read from the top level, not just `quic-opts` — still wins); and stream closes now emit the AEAD end-of-stream chunk (`[0x00,0x10]` plus tag, not `[0x00,0x00]`), UDP response chunks advance their own receive counter instead of reusing nonce zero, and the handshake and response-header reads are bounded by a wall-clock deadline that actually fires. Unimplemented transports (`h2`, `grpc`, `kcp`, `quic`) are now rejected at configuration time instead of silently falling back to raw TCP. Relay failures inside the SOCKS5 inbound are reported at warning level with outbound, target and cause instead of surfacing only as an unexplained EOF.

- Collapsed the bridge into a single crate rooted at `rust/`: cargokit (`manifestDir`), the bridge generator (`rust_root`), and the generated dylib loader (`ioDirectory`) all point at that directory instead of the removed `rust/veloguard-lib` sub-crate.
- Restored the pieces the flattened manifest had dropped along the way: the `rust_lib_veloguard` library stem with `rlib`/`cdylib`/`staticlib` outputs (every platform loads the artifact by that name), and the Android-only `jni` and `tracing-android` dependencies that `android_jni.rs` and the logcat layer are compiled against.
- Scoped Android release lint to the app module (`./gradlew :app:lintRelease`) in both workflows: a bare `lintRelease` also runs the lint task of every Flutter plugin in the pub cache, and `shared_preferences_android` 2.4.27 fails its own lint with `MemberExtensionConflict` on AGP 8.14, which no change in this repository can fix.
- Added rule set ownership on the Dart side: providers are downloaded over TLS with conditional requests, cached under the app support directory, normalised from YAML `payload:` documents into the line format the engine parses, and refreshed daily (or on the declared interval) before the profile is converted; the engine now always receives local `file` providers, so an unreachable rule source can no longer abort start-up.
- A `RULE-SET` rule whose provider has no local copy is skipped with a warning instead of failing engine validation, matching Clash's behaviour for an unloaded provider.
- Registered the bundled `Country.mmdb` with the engine: the asset is unpacked into the app support directory and exported through `CORDUIT_GEOIP_DB` before the engine starts, and `GEOIP` rules now match instead of silently doing nothing.
- Fixed Android mode handling: the VPN route is always `0.0.0.0/0` and the engine decides rule/global/direct per connection, so switching modes no longer changes which traffic is captured; the notification reports the new mode, and tunnel establishment runs off the main thread.
- Fixed mode switching on Linux and macOS, where `setProxyMode` reported failure while the engine had already applied the mode; Windows global mode rebuilds the TUN routes when the route table is not in global mode yet.
- Unified system proxy handling into one implementation: Windows snapshots and restores the previous WinINET settings (including the bypass list), Linux checks every `gsettings` exit code instead of assuming success, and macOS reports `networksetup` failures.
- Made the TUN switch drive the real tunnel, and removed the placeholder TUN stack selector, the UWP toggle that only ran a fixed Edge command, the unused UWP/auto-start/dead service paths, and the unused `autoStart` storage APIs.
- Hardened the Android manifest: `allowBackup` is off (proxy credentials must not leave the device), `QUERY_ALL_PACKAGES` and the unused boot/wake permissions are gone, and the network security policy now denies cleartext except for loopback and private ranges.
- Trimmed status polling: connections are polled every third tick, the always-empty subscription list call is gone, and system info refreshes every five seconds instead of three.
- Keyed the bundled GeoIP database install on an FNV-1a content fingerprint: a `Country.mmdb` rebuilt for a new release can keep its byte length, and the previous size-only check would then have kept serving the stale copy.
- Took the engine fixes that make the bundled database readable: the MMDB reader had the metadata pointer base and the pointer width classes wrong (the latter made every lookup miss), a two-letter-only country code type that dropped the customized `GOOGLE`/`CLOUDFRONT` provider labels, and a VMess AEAD handshake that never consumed the response header.
- Stopped the TUN relay from dropping live connections. A socket read/write timeout arrives as `EAGAIN` (`WouldBlock`, logged as "Try again") on Android and Linux and as `TimedOut` on Windows; the relay only recognised the Windows spelling, so any connection that stayed quiet for the handshake timeout was closed with a `Proxy read error` warning. Transient errors now keep polling, a peer that stops reading is given a full minute of no progress before the write fails, and peers that hang up are reported at debug level instead of warning on every browser-aborted request.

## 1.0.2

- Replaced the in-repository proxy core with corduit 0.1.5. `veloguard-core`, `veloguard-dns`, `veloguard-netstack`, and `veloguard-protocol` are gone; the workspace now contains the Flutter Rust Bridge adapter only.
- Dispatched every engine call onto a blocking worker, so corduit's synchronous APIs never stall the Flutter isolate.
- Moved the Dart bridge API to corduit naming: `initializeCorduit`, `startCorduit`, `stopCorduit`, `reloadCorduit`, `getCorduitStatus`.
- Rewrote configuration conversion to corduit's contract: `outbound_type`, `inbound_type`, and `rule_type` keys with a JSON `options` string, plus explicit downgrades and warnings when a protocol or a rule type has no corduit counterpart.
- Forwarded the Android `VpnService` JNI entry points to corduit so the engine's own JNI state and socket-protect callback are the ones in play; starting the Android VPN no longer fails its readiness checks.
- Routed three engine calls around upstream stubs: `get_connections` serves the tracker-backed active connections, `close_connection` closes by connection id, and the log level is owned by the bridge's reloadable subscriber.
- Dropped the raw-YAML fallback in the profile startup path: every corduit config entry point parses JSON, so a failed conversion now surfaces instead of retrying with text the engine cannot read.
- Fixed Windows Flutter builds on machines with a standalone Rust installation on PATH: cargokit now prefers the rustup shim, keeping cargo and rustc on the same toolchain.
- Fixed the Windows runner build failing with `RC2176` on `app_icon.ico`: PowerShell enumerated the generated byte arrays, so the icon directory table recorded one byte per entry instead of the real image size.
- Added the RecurseX recursive DNS front-end with start/stop/status APIs and a DNS settings toggle.
- Upgraded flutter_rust_bridge to 2.13.0 on both sides and added ffigen for the web bindings.
- Trimmed the workspace dependency list to corduit, RecurseX, flutter_rust_bridge, tokio, tracing, once_cell, parking_lot, and jni on Android.
- Relicensed the project under the PolyForm Perimeter License 1.0.1 plus the licensor's no-unlawful-use term, and aligned the in-app license name, about strings, disclaimer text, and platform metadata in all eleven locales with the new terms.
- Merged the earlier single-crate iteration back into the bridge workspace: the corduit 0.1.5 bridge stays the engine surface, cargokit and the bridge generator point at `rust/veloguard-lib` again, the Rust toolchain is pinned to 1.97.0 so local builds lint with the same compiler as CI, and the iteration's UI fixes (a proxy-aware IP check that follows the configured mixed port, the `file_picker` 12 reader) plus its CI action bumps and the pub-host lockfile step were kept.

## 1.0.1

- Added push and pull-request CI for Flutter, Android, and the complete Rust workspace.
- Made stable release validation fail explicitly when immutable release assets already exist.
- Restored Android release lint checks and validated partial signing configuration.
- Replaced platform status placeholders with native runtime results.
- Removed unused WireGuard and VPN connection-count placeholder APIs.
- Replaced the unfinished profile editor action with a validated configuration editor.
- Enforced Android release lint, hardened certificate trust, and removed obsolete permissions.
- Removed fake OHOS VPN success paths and the unused Android TUN placeholder API.
- Preserved TLS certificate validation when checking the proxied exit IP.

## 1.0.0

- Fixed proxy-page rendering crashes caused by invalid animated shadow values.
- Added dual-stack IPv4 and IPv6 listener support across HTTP, SOCKS5, mixed, and TUN paths.
- Added an animated in-app startup logo and removed the white startup flash.
- Added persisted rule/global proxy mode selection before service startup.
- Added live VeloGuard process memory reporting with a three-second refresh interval.
- Added checksum-verified stable-release update checks using release tag, publication date, and SHA256.
- Added validated HTTP and TLS traffic sniffing settings.
- Unified the interface on Material Design 3 with the bundled Roboto font.
- Added manual stable-release dispatch with immutable versioned assets.
- Fixed Classical `PROCESS-NAME` and trailing rule modifier handling.
- Added centralized Material 3 shape tokens and removed continuous proxy-card marquees.
- Localized update status and installation prompts across all supported languages.
