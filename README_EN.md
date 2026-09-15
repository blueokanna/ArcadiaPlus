# VeloGuard

<p align="center">
  <img src="assets/veloguard.png" width="128" height="128" alt="VeloGuard Logo" style="border-radius: 12px;">
</p>

<p align="center">
  Cross-platform proxy client built with Flutter and Rust<br>
  <a href="README.md">中文</a>
</p>

> Status: pre-release. The repository does not yet meet the bar for production support across all six target platforms and all requested protocols. This document describes only capabilities supported by code and verification evidence.

## Implemented Scope

- Flutter Material Design 3 UI with light/dark themes, dynamic color, Google Fonts, responsive navigation, and component/page motion.
- A single Rust bridge layer: the proxy engine, DNS, TUN data path, and every proxy protocol come from [corduit](https://crates.io/crates/corduit) 0.1.5, and this repository no longer reimplements them. The bridge owns sync/async adaptation, DTO mapping, and platform entry points.
- Explicit configuration downgrades: a node whose protocol corduit cannot build is dropped and its references fall back to `DIRECT`, and a rule type corduit has no rule for is skipped — every downgrade is reported through `onWarning`, never silent.
- Optional local recursion: with it enabled, [RecurseX](https://crates.io/crates/recurse-x) resolves from the root servers iteratively and corduit's DNS upstreams point at that front-end.
- Shared Rust TUN packet processing for Android, Windows, and Linux, with platform-owned device lifecycles.
- Generated app icons for Windows, macOS, Linux, Android, iOS, and HarmonyOS NEXT from `assets/veloguard.png`.

## Protocol Status

The protocol implementations live in corduit 0.1.5. This repository wires them into Flutter and has not run real-server interoperability tests itself.

| Protocol | Implementation | Notes |
| --- | --- | --- |
| HTTP / SOCKS5 | corduit | Inbound and outbound paths inside the engine |
| Shadowsocks | corduit | AEAD and stream ciphers |
| VMess / VLESS / Trojan | corduit | WebSocket, gRPC, and TLS transports |
| TUIC / Hysteria 2 | corduit (`tuic`, `hysteria2` features) | QUIC paths, enabled in this build |
| WireGuard | corduit (`wireguard` feature) | Tunnel path, enabled in this build |
| ShadowsocksR / Hysteria v1 / shadowquic | Unsupported | The bridge drops such nodes during conversion, rewrites references, and raises a warning |

A protocol can move to “supported” only after interoperability tests against mainstream servers, TCP and UDP coverage, authentication failure tests, reconnect tests, and target-platform integration tests.

## Platform Status

| Platform | UI shell | System proxy | Full-tunnel VPN/TUN | Current conclusion |
| --- | --- | --- | --- | --- |
| Android | Present | N/A | `VpnService` path implemented | Requires device, ABI, and long-running regression tests |
| Windows | Present | Implemented | Wintun path implemented | Requires Windows 10/11 tests with elevation |
| Linux | Present | GNOME settings path | IPv4 global-mode path implemented | Requires root/device testing; rule/direct modes fail closed until socket marking or interface binding is implemented |
| macOS | Present | `networksetup` path | No Network Extension | Full-tunnel support cannot be claimed |
| iOS | Present | N/A | No Packet Tunnel Extension | Application shell only |
| HarmonyOS NEXT | Project skeleton | N/A | Explicitly returns `OHOS_VPN_UNSUPPORTED` | Not releasable |

## Architecture

```text
Flutter UI / Provider
        |
Flutter Rust Bridge (generated bindings)
        |
veloguard-lib (the only bridge crate: async adaptation, DTO mapping, platform entry points)
        |
corduit 0.1.5 (engine: config, routing, inbounds, outbounds, DNS, TUN, all protocols)
        +-- courierust (HTTP/1.1 · HTTP/2 · HTTP/3 · WebSocket · TLS stack)
        +-- nextjson / rustbinary (config and binary codecs)
RecurseX 0.1.0 (optional local recursive DNS front-end, lifecycle owned by the bridge)
```

corduit is synchronous while the Dart surface stays `Future`-based, so the bridge dispatches every engine call onto a blocking worker (`run`). Starting the proxy, probing latency, or toggling TUN therefore never stalls the Flutter isolate.

Clear ownership boundaries matter more than adding macros, generics, or complex lifetimes without a measurable benefit. These Rust features should be used only for useful zero-cost abstractions, ownership modeling, or meaningful deduplication.

## Prerequisites

- Flutter SDK compatible with Dart `^3.10.4`
- Stable Rust with edition 2021 and workspace resolver 3 support
- Android: Android SDK, NDK, and JDK 17
- Windows: Visual Studio C++ toolchain, Wintun, and elevation
- macOS/iOS: Xcode and valid signing configuration
- HarmonyOS NEXT: DevEco Studio, API 12 SDK, and Flutter OHOS toolchain

## Build and Check

```bash
flutter pub get
flutter analyze
flutter test

cd rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

The Dart bindings are generated from `flutter_rust_bridge.yaml`; after changing Rust `api`/`types`, regenerate them:

```bash
flutter_rust_bridge_codegen generate
```

Build each target on its supported host and SDK:

```bash
flutter build apk --release
flutter build windows --release
flutter build linux --release
flutter build macos --release
flutter build ios --release --no-codesign
```

Use the DevEco/hvigor workflow in [ohos/README.md](ohos/README.md) for HarmonyOS NEXT. A successful build validates the toolchain, not the unfinished VPN data path.

## Icons

The single source is `assets/veloguard.png` and must be square and at least 1024x1024. On Windows run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/generate_icons.ps1
```

The script generates and validates Android, iOS, macOS, Windows, Linux, Web, and HarmonyOS assets. Generated icons should not be edited manually.

## Automated Verification

Every push and pull request runs Dart formatting, Flutter analysis and tests, an Android debug APK build, Android release lint, Rust formatting, Clippy with warnings denied, and all workspace tests. The release workflow repeats those checks while creating a signed APK.

An automated build is not evidence of VPN behavior or protocol interoperability. Android VPN traffic, privileged Windows/Linux TUN routing, Apple Network Extension, HarmonyOS VPN FD handling, and real-server protocol compatibility remain subject to the release gates below.

## GitHub Release Configuration

Create these repository Actions secrets before manually dispatching a release or pushing a release tag:

- `VELOGUARD_KEYSTORE_BASE64`
- `VELOGUARD_KEYSTORE_PASSWORD`
- `VELOGUARD_KEY_ALIAS`
- `VELOGUARD_KEY_PASSWORD`

The `version` in `pubspec.yaml`, the top changelog section, and the `vMAJOR.MINOR.PATCH` tag must match. Manual releases can run only from the default branch. Existing releases are immutable, so the workflow fails instead of silently replacing or accepting existing assets.

## Release Gates

1. Replace or validate WireGuard, Hysteria 2, and TUIC with mature audited implementations; add Hysteria v1 and NaiveProxy.
2. Validate Linux global route takeover/restoration in an isolated network and add loop-free rule/direct modes, IPv6, DNS leak protection, and network-change recovery; implement Apple Network Extension and the complete HarmonyOS VPN FD lifecycle into Rust.
3. Add a containerized interoperability matrix for every protocol, covering TCP, UDP, IPv4, IPv6, reconnects, and authentication failures.
4. Complete signed release builds and installation, start/stop, sleep/resume, network-switch, and leak tests on all six platforms.

## Disclaimer

- **Lawful use is the only permitted purpose.** VeloGuard is a network tool. It ships no proxy servers, nodes, or subscriptions; you supply your own configuration and are responsible for it.
- **The compliance burden is yours.** Keep your use within the law of every jurisdiction that applies to you, the terms of the networks you rely on, and applicable export-control and sanctions rules. Using this software, or a change or new work based on it, to break the law is not a permitted purpose and violates the [license terms](LICENSE).
- **The authors and contributors accept no liability.** As far as the law allows, they are not liable for any direct or indirect loss arising from use or inability to use this software, nor for any consequence of anyone using it unlawfully, whether or not you authorized that use.
- **This is not legal advice.** The warnings here and in the app describe risk only; they are not a legal opinion. Consult a qualified lawyer when you need one.
- **No warranty.** The software comes as is, without any express or implied warranty, including merchantability, fitness for a particular purpose, and non-infringement (see *No Liability* in `LICENSE`).

## License

**PolyForm Perimeter License 1.0.1** — see [`LICENSE`](LICENSE): the text is the official [PolyForm Perimeter 1.0.1](https://polyformproject.org/licenses/perimeter/1.0.1), with one additional term appended by the licensor.

What that means in practice:

- **Free for any purpose except competing products.** Reading, building, modifying, self-hosting, embedding in internal or customer systems, teaching, and shipping alongside non-competing software are all allowed. What is not allowed is providing others a product that substitutes for this software's functionality or value — including as a service interface, and including a port to another language (see [Noncompete](https://polyformproject.org/licenses/perimeter/1.0.1/#noncompete) and [Competition](https://polyformproject.org/licenses/perimeter/1.0.1/#competition)).
- **Not an OSI-approved open-source license**, but a *source-available* license: you can read and modify the source under the terms above, and anyone you pass a copy to receives these same terms.
- **Keep the required notice.** When you distribute the software or any part of it, pass along the full `LICENSE` text (or the official link above) and the `Required Notice: Copyright 2026 blueokanna and HyphenTeam (https://github.com/blueokanna/Courierust)` line it carries (see *Notices*).
- **No warranty, no liability** (as far as the law allows), and the appended term extends the same limit to anyone using this software, or a work based on it, to break the law (see *Additional Term Adopted by the Licensor* at the end of `LICENSE`).
