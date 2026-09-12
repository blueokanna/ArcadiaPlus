# VeloGuard

<p align="center">
  <img src="assets/veloguard.png" width="128" height="128" alt="VeloGuard logo" style="border-radius: 12px;">
</p>

<p align="center">
  Cross-platform proxy client built with Flutter + Rust<br>
  <a href="README.md">简体中文</a>
</p>

```text
   ┌─ rust/src ────────────────────────────────────────────────┐
   │  api.rs        ← the only ABI (Flutter Rust Bridge)       │
   │  ├─ core/      ← config, routing, inbounds, outbounds     │
   │  ├─ dns/       ← upstream resolution, cache, fake-IP      │
   │  ├─ netstack/  ← TUN, user-space TCP/IP, NAT              │
   │  └─ protocol/  ← wire protocols and transports            │
   └───────────────────────────────────────────────────────────┘
       One crate, one src tree, five layers, dependencies point down.
```

## What this is

A desktop/mobile proxy client that wires TUN capture, protocol outbounds, DNS policy and a
Flutter UI together. On the Rust side only `crate::api` is exported: the UI never touches an
internal type, and no lower layer ever calls back into the UI.

Config parsing **fails closed**. Unknown inbound/outbound/rule types, empty payloads, invalid
domains and patterns that do not compile are rejected while the config is still being loaded —
there is no "did not understand it, so route it DIRECT" fallback anywhere.

## The in-house crate stack

We do not re-implement what you already maintain:

| crate | version | role in this repo |
| --- | --- | --- |
| `corduit` | 0.1.4 | Engine substrate. Besides `dns::bogon` (its CIDR tables are re-used instead of kept here), **every cryptographic primitive** lives here: hashes, HMAC, HKDF, AES-GCM, ChaCha20-Poly1305, X25519, base64/hex, the ChaCha20 CSPRNG, and URL parsing (`common::url`) |
| `rustbinary` | 0.1.8 (via `corduit`) | **Not used directly**: 0.1.8's legacy profile emits a schema-annotated encoding (field names plus type tags) that is no longer the byte layout the TUIC v5 handshake needs. That packet is encoded in `protocol/tuic` under a frozen unit test |
| `nextjson` + `nextjson-derive` | 0.1.4 | Parses the Dart-facing config JSON (`initialize_veloguard` / `reload_config` / rule providers) and derives the DTOs |
| `tzcraft` | 0.1.2 | Log timestamps: system zone → civil time |
| `recurse-x` | 0.1.0 | DNS name validation for the fail-closed config checks |
| `courierust` | 1.0.4 | The HTTP/HTTPS/TLS egress: subscriptions, rule lists, update downloads and the latency probe all go through `crate::http`, which drives its client (connection pool, HTTP/2, TLS 1.2/1.3). The server-side surfaces (inbound CONNECT, DoH server, h2, ws) are still being migrated |

Cryptography has exactly one path:

- `crate::crypto` is the only door, and everything behind it comes from `corduit::crypto`. There is
  deliberately **no** `sha2`, `aes-gcm`, `chacha20poly1305`, `hkdf`, `blake2`, `blake3`,
  `x25519-dalek`, `md-5`, `sha1`, `base64`, `rand` or `reqwest` in the manifest: a second
  implementation of a primitive is a second place for a bug to live.
- The one exception is the OS entropy source (`getrandom`). It is a syscall wrapper, not a crypto
  implementation — the kernel CSPRNG is the root of trust and cannot be rewritten in user space.
  A process-wide CSPRNG (ChaCha20 keystream over an OS seed, re-seeded every 64 KiB) supplies the
  values that must not repeat: DNS transaction IDs, VMess masks and padding, WireGuard source
  ports, TCP initial sequence numbers.
- Protocol bytes stay in protocol files: WireGuard's `mac1` (keyed BLAKE2s-128), the SS2022 subkey
  derivation and the TUIC auth packet each have tests that freeze their bytes.
- The Dart side is honest about its state: Rust is fully on our own stack, but the three bridge helpers that would have
  moved subscriptions and hashing over too (`fetchSubscription`, `fetchText`, `sha256FileHex`) were implemented and then
  withdrawn — FRB 2.12.0 generates invalid Dart bindings for this crate (see below), so those two capabilities still ride
  on Dart's `http` / `crypto` until the bridge is upgraded.
- **Upstream codegen blocker:** with the codegen CLI and the Dart package both at 2.12.0, running `generate` on the
  merged crate emits a `frb_generated.io.dart` with a syntax error (a `$allocator<WireSyncRust2DartSse>` fragment whose
  function header is missing). The working procedure is therefore "regenerate the Rust glue, then restore the Dart
  bindings"; do not re-run codegen blindly, and check `flutter analyze` before trusting its output.

Two details worth stating out loud:

- `corduit` pins `tun-rs = 2.5.7` exactly, so this repo pins it too. `tun-rs` 2.x is a single
  semver line, so two versions cannot coexist — the resolver rejects it outright.
- `rustbinary`'s codec traits come from `nextjson` (`NsonSerialize` / `NsonDeserialize`), so upgrading
  changes trait bounds — and measuring it showed that 0.1.8's "legacy" output is no longer the old
  byte layout. The TUIC auth packet is therefore encoded in this repo again, with a unit test that
  freezes the `version || uuid || token` byte sequence. That test exists for exactly this: stop a
  dependency bump before it rewrites protocol bytes.
- `courierust`'s client is **synchronous** (it owns its threads and pools), so `crate::http` runs it
  inside `spawn_blocking` and keeps an async surface for callers. Its trust roots come from the
  platform store; `VELOGUARD_TRUST_ROOTS_PEM` can name an extra PEM bundle for platforms without one.

## Protocol status

| Protocol | Status | Notes |
| --- | --- | --- |
| HTTP / SOCKS5 | Implemented | TCP outbound; still needs end-to-end testing in a release build |
| Shadowsocks | Experimental | Own TCP/UDP crypto path with unit tests; no real-server interop evidence |
| VMess | Experimental | Own protocol and transports; no Xray interop tests |
| VLESS | Experimental | Own TCP/UDP/TLS path; no Xray interop tests |
| Trojan | Experimental | Own TCP/UDP/TLS path; no interop tests against a standard server |
| WireGuard | Not production ready | Handshake/crypto and UDP paths exist; the TCP path lacks a full TCP/IP state machine, retransmission and congestion control |
| TUIC v5 | Experimental | Quinn-based implementation; no compatibility tests against a real TUIC server |
| Hysteria 2 | Not production ready | The current custom QUIC auth/framing has not been shown to match the Hysteria 2 standard |
| Hysteria v1 | Not implemented | No longer mis-mapped to Hysteria 2; config fails explicitly |
| NaiveProxy | Not implemented | Config fails explicitly and never silently bypasses the proxy |

Reaching "supported" requires at least: interop tests against official or mainstream servers,
both TCP and UDP coverage, auth-failure tests, reconnect tests, and integration tests on every
target platform. Every "experimental" above means exactly that.

## Platform status

| Platform | UI shell | System proxy | Global TUN/VPN | Verdict |
| --- | --- | --- | --- | --- |
| Android | Yes | n/a | `VpnService` path implemented | Needs device, ABI and long-connection regression tests |
| Windows | Yes | Implemented | Wintun path implemented | Needs admin rights and real Windows 10/11 testing |
| Linux | Yes | GNOME settings path | IPv4-only global mode path implemented | Still needs root/real-hardware validation; rule/direct modes refuse to run until socket mark or physical-NIC binding lands |
| macOS | Yes | `networksetup` path | No Network Extension | Global proxy support cannot be claimed |
| iOS | Yes | n/a | No Packet Tunnel Extension | App shell only |
| HarmonyOS NEXT | Scaffold | n/a | Returns `OHOS_VPN_UNSUPPORTED` explicitly | Not shippable |

## Security posture

- **No bare `unsafe` in the data path.** `unsafe` appears only at platform FFI boundaries
  (TUN / Wintun / JNI / process enumeration); every other occurrence is in generated FRB glue.
- **Wintun is never downloaded implicitly.** A runtime download requires
  `VELOGUARD_ALLOW_WINTUN_DOWNLOAD=1` *and* `VELOGUARD_WINTUN_SHA256=<hex>` pinning the SHA-256
  of the extracted DLL. On mismatch nothing is written to disk. Installation goes through a
  temp file plus rename, and the archive has a hard size ceiling. If verification is not
  possible, the user is told to install Wintun from the vendor instead.
- **Fail closed.** Invalid domain rules, uncompilable regexes and unknown protocol types are
  rejected at load time rather than degrading silently once traffic is flowing.
- **No telemetry by default.** With the `jaeger` feature off, no reporting code is even compiled in; with it on, traces go to the OTLP endpoint *you* configure. Logs stay local and in the UI ring buffer.
- **Not audited.** This is engineering code, not a third-party-audited cryptographic product.
  Report vulnerabilities privately instead of opening a public issue first.

## Requirements

- Flutter SDK with Dart `^3.10.4`
- Rust stable **≥ 1.88**, `edition = 2024`
- Android: Android SDK, NDK, JDK 17
- Windows: Visual Studio C++ toolchain; Wintun and admin rights
- macOS/iOS: Xcode with a valid signing setup
- HarmonyOS NEXT: DevEco Studio, API 12 SDK, Flutter OHOS toolchain

## Build and check

```bash
flutter pub get
flutter analyze
flutter test

cd rust
cargo check --all-targets
cargo test
cargo clippy --all-targets
cargo fmt --check
```

Platform builds must run on the matching host with the matching SDK:

```bash
flutter build apk --release
flutter build windows --release
flutter build linux --release
flutter build macos --release
flutter build ios --release --no-codesign
```

HarmonyOS NEXT uses the DevEco/hvigor flow described in [ohos/README.md](ohos/README.md).
A successful build only proves the toolchain works; it does not prove the VPN data path does.

## Icons

The single source of truth is `assets/veloguard.png` (square, at least 1024x1024). On Windows:

```powershell
.\scripts\generate_icons.ps1
```

## License

[PolyForm Perimeter License 1.0.0](LICENSE): read it, modify it, distribute it, use it
internally or commercially — but you may **not** ship a product that competes with it
(the Noncompete clause). `LICENSE` is authoritative.

---

## Disclaimer

**By using this software you confirm that you have read, understood and accepted all of the
following. If you disagree, stop using it and delete every copy immediately.**

1. **No warranty.** The software is provided "AS IS", without any express or implied warranty,
   including merchantability, fitness for a particular purpose, non-infringement, and
   uninterrupted or error-free operation.
2. **Use at your own risk.** Proxying, tunnelling, TUN capture, DNS rewriting and traffic
   interception all have real side effects. Use it on your own devices and networks, in
   environments you are authorised to manage.
3. **Compliance is your responsibility.** You must determine and follow the laws and
   regulations that apply to you (export control, sanctions, telecommunications and network
   security rules) as well as the terms of service of anything you connect to. Do not use it
   for unauthorised access, attacks, evading lawful oversight, or any illegal purpose.
4. **Limitation of liability.** To the maximum extent permitted by law, the authors and
   contributors are not liable for any direct, indirect, incidental, special, punitive or
   consequential damages, including data loss, device damage, business interruption, lost
   profits, administrative penalties or legal consequences.
5. **Implementation status.** See "Protocol status" above. Anything marked
   experimental/not-production-ready has not been validated against official or mainstream
   servers; do not put it on a critical path.
6. **Upstream churn.** Upstream protocols, server implementations and dependencies can change
   at any time, breaking connections, changing fingerprints or regressing performance. No
   compatibility or follow-up is promised.
7. **No affiliation.** This project is not affiliated with, sponsored by, or endorsed by any
   protocol, organisation or commercial service mentioned here. Names and trademarks belong to
   their respective owners.
8. **Not audited.** No third-party security audit has been performed; nothing here is a
   security guarantee. Assess your own risk and test thoroughly before production use.
9. **Distribution limits.** This repository ships no servers, subscriptions or nodes, and
   recommends none. When you redistribute the software you must keep `LICENSE` and this
   disclaimer intact, and honour the PolyForm Perimeter noncompete clause.
