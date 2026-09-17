# VeloGuard

<p align="center">
  <img src="assets/veloguard.png" width="128" height="128" alt="VeloGuard Logo" style="border-radius: 12px;">
</p>

<p align="center">
  Cross-platform proxy client built with Flutter and Rust<br>
  <a href="README.md">中文</a>
</p>

## Implemented Scope

- Flutter Material Design 3 UI with light/dark themes, dynamic color, Google Fonts, responsive navigation, and component/page motion.
- A single Rust bridge layer: the proxy engine, DNS, TUN data path, and every proxy protocol come from [corduit](https://crates.io/crates/corduit) 0.1.9, and this repository no longer reimplements them. The bridge owns sync/async adaptation, DTO mapping, and platform entry points.
- Explicit configuration downgrades: a node whose protocol corduit cannot build is dropped and its references fall back to `DIRECT`, and a rule type corduit has no rule for is skipped — every downgrade is reported through `onWarning`, never silent.
- Optional local recursion: with it enabled, [RecurseX](https://crates.io/crates/recurse-x) resolves from the root servers iteratively and corduit's DNS upstreams point at that front-end.
- Rule sets (`rule-providers`) are owned by the Dart side: `RuleProviderService` downloads, validates, normalises, and caches them in the app's private directory, then refreshes each one on the interval the profile declares (86400 seconds by default). The engine only ever receives local `file` providers, a failed refresh keeps the last good copy, and a rule set that is missing takes its `RULE-SET` rules out of the profile the way Clash does — with a warning, and without failing the rest of the config.
- The GeoIP database ships with the installer (`assets/Country.mmdb`), is unpacked into the app support directory at start-up, and is registered with the engine; a failure to unpack or register is recorded, and `GEOIP` rules simply do not match while it is missing — never a silent downgrade.
- Shared Rust TUN packet processing for Android, Windows, and Linux, with platform-owned device lifecycles.
- Generated app icons for Windows, macOS, Linux, Android, iOS, and HarmonyOS NEXT from `assets/veloguard.png`.

## Protocol Status

The protocol implementations live in corduit 0.1.9. This repository wires them into Flutter and has not run real-server interoperability tests itself.

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
| Linux | Present | GNOME settings path (every `gsettings` exit code is checked) | IPv4 TUN path provided by corduit | Needs root/device testing; the data path points the default route at the TUN and exempts only proxy server addresses, so engine-dialled direct traffic can loop back into the tunnel — rule/direct modes are not claimed until that is verified on hardware |
| macOS | Present | `networksetup` path | No Network Extension | Full-tunnel support cannot be claimed |
| iOS | Present | N/A | No Packet Tunnel Extension | Application shell only |
| HarmonyOS NEXT | Project skeleton | N/A | Explicitly returns `OHOS_VPN_UNSUPPORTED` | Not releasable |

## Routing Modes

`rule` / `global` / `direct` are decided inside the engine: the inbounds, the TUN data path, and the Android VPN all hand their connections to one router, so switching modes never requires rebuilding the tunnel.

| Platform | What a mode switch does | Notes |
| --- | --- | --- |
| Android | `set_android_proxy_mode` (engine runtime mode) plus the notification text | The VPN route is always `0.0.0.0/0` and the engine decides per dial; every port-53 query that enters the tunnel is answered by the netstack's fake-IP resolver |
| Windows | `set_windows_proxy_mode` | Switching to `global` while the route table is not in global mode is retried through `enable_tun_mode_with_mode("global")`, which rebuilds the routes |
| Linux / macOS | `set_proxy_mode` (engine runtime mode) | The Linux TUN data path dials through the local SOCKS inbound, so the mode applies at dial time |
| System proxy | Independent of the mode | Points at the local mixed port; Linux checks every `gsettings` exit code, and Windows snapshots the previous proxy settings before enabling and restores them on disable |

Rule sets refresh at start-up, after a profile update, and on a 15-minute due check. Only providers whose declared interval (one day by default) has elapsed actually make a network request, and those requests carry `If-None-Match` / `If-Modified-Since`; a 304 means the cached copy is current. A refreshed rule set lands on a content-addressed file name, which changes the config, so the running engine loads the new content on the next `reload_corduit`.

### Proxy group semantics

`proxy-groups` in a profile is a nested structure: the members of a `select` group may themselves be nodes or other groups, and the engine walks that chain one level at a time when it dials (depth is capped at 10). Two consequences matter in practice:

- **Only a group that a rule refers to decides the exit.** Changing the selection of a group that no rule points at, and that no other group references, changes nothing about the traffic. A typical airport profile defines a dozen groups (streaming, Steam, Cloudflare, and so on), and most of them only serve specific rules.
- **A group's default member is the first entry of its list.** Until a selection is made, the engine uses the first member the way Clash does, so “the first connection used the first node in the list” is the documented default rather than a lost selection. The app persists the selection per group and re-sends every group once the engine reports ready, and again after a profile switch.

When an exit does not match expectations, check in this order: which rule matched the traffic → the group that rule names → that group's selected member → whether the member is a node or another group. After every selection the app reads the effective member back from the engine, logs `Selection mismatch`, and retries when the two disagree.

## Idle Cost

A proxy client has nothing to carry most of the time, so the cost of an idle connection sets both power draw and how responsive the whole device feels. The project holds two hard constraints here, and both are enforced in code and covered by tests:

- **A read never re-enters without having received data.** The engine's idle wait is built on the `Notify` latch, and that latch answers only “was a notification observed” — it cannot distinguish a latched wake (which never blocked at all) from a timeout. `read_blocking` therefore uses `wait_latched` and backs off 1 ms only when a latched wake finds the receive buffer still empty; a wake that carried data returns immediately, and the timeout path is untouched.
- **No data means no wake-up is claimed.** `push_recv_data` returns early when the receive buffer is full or when the payload is empty (a pure ACK, a zero-window probe) and no longer sets the latch; `close` notifies once, on the open→closed transition.

The accompanying constraint is thread ownership: `relay_with` joins both of the direction threads it started on every path out of the function, and releases both sides before joining when one direction panics, so it cannot return while a thread still holds the transports and their sockets.

- **Pick an error kind by its contract, not by its label.** `std::io::Write::write_all` retries `ErrorKind::Interrupted` **without a bound** (its contract is “a signal interrupted the call and the data is fine”). Mapping “the session was cancelled” onto `Interrupted` turns every failed frame write into an infinite “allocate an error string, retry immediately, fail again” loop: nothing in that loop can block, so the thread sits on a full core with an empty `wchan`. Cancellation now maps to `ConnectionAborted`, which is terminal.

The three constraints above, measured on a device with the tunnel up (same handset, same subscription, same measurement window):

| Observable | Before | After |
| --- | --- | --- |
| Process `utime` (per 10 s) | 7.00 cores | **0.01 cores** |
| Process `stime` | 0.05 cores | 0.01 cores |
| `procs_running` | 118 | **1** |
| `PSI cpu some avg10` | 78.58% | **5.68%** |
| `corduit-relay-up` / `-down` threads | 136 / 41 | **8 / 8** |
| Running threads with an empty `wchan` | 117 | **0** |
| Proxy still usable | Yes (HK egress) | Yes (HK egress) |

### Verifying on a device

A spin shows up as **high user CPU, almost no system time, and no I/O growth** at the same time. None of the commands below need root:

```bash
# 1) System-wide CPU stall accounting (Pressure Stall Information). Sustained high values mean something is starving the CPU.
adb shell cat /proc/pressure/cpu

# 2) Run-queue length. Sustained high values are what the user feels as lag.
adb shell grep procs_running /proc/stat

# 3) Per-process user/system time, twice, and subtract (units: 100 Hz ticks).
adb shell 'P=$(pidof com.blueokanna.veloguard); awk "{print \$14, \$15}" /proc/$P/stat; sleep 15; awk "{print \$14, \$15}" /proc/$P/stat'

# 4) I/O growth. Compare with (3): CPU climbing while the byte count does not is a spin.
adb shell cat /proc/$(pidof com.blueokanna.veloguard)/io

# 5) Per-thread attribution: an empty wchan (shown as 0) means the thread is on the CPU in userspace, blocked in no syscall.
adb shell 'P=$(pidof com.blueokanna.veloguard); for t in /proc/$P/task/*; do echo "$(cat $t/comm) $(cat $t/wchan)"; done | sort | uniq -c | sort -rn'
```

The bar: with the tunnel idle, `procs_running` should stay in the single digits, and threads that are accounted as running should show a kernel sleep symbol in `wchan` rather than an empty one.

## Known Limitations

These are stored today but do not change runtime behaviour; they are listed so they are not mistaken for working features:

- Every field on the DNS settings page other than “local recursive resolution” (`useRecursiveResolver`, which starts RecurseX and points the engine's upstreams at it). The engine takes its DNS configuration from the profile's `dns` section (`enable` / `listen` / `nameservers` / `fallback` / `enhanced-mode`), and corduit's `DnsConfig` has no `nameserver-policy`, `fallback-filter`, `hosts`, or `prefer-h3` field.
- The hosts mapping on the General settings page, for the same reason: there is no hosts table in the engine's DNS configuration.
- The system proxy bypass list reaches Windows (`ProxyOverride`) and Linux (`ignore-hosts`); the macOS `networksetup` path currently only sets or clears the proxies themselves.

## Architecture

```text
Flutter UI / Provider
        |
Flutter Rust Bridge (generated bindings)
        |
lib-veloguard (the only bridge crate, rooted at rust/: async adaptation, DTO mapping, platform entry points)
        |
corduit 0.1.9 (engine: config, routing, inbounds, outbounds, DNS, TUN, all protocols)
        +-- courierust (HTTP/1.1 · HTTP/2 · HTTP/3 · WebSocket · TLS stack)
        +-- nextjson / rustbinary (config and binary codecs)
RecurseX 0.1.0 (optional local recursive DNS front-end, lifecycle owned by the bridge)
```

corduit is synchronous while the Dart surface stays `Future`-based, so the bridge dispatches every engine call onto a blocking worker (`run`). Starting the proxy, probing latency, or toggling TUN therefore never stalls the Flutter isolate.

Clear ownership boundaries matter more than adding macros, generics, or complex lifetimes without a measurable benefit. These Rust features should be used only for useful zero-cost abstractions, ownership modeling, or meaningful deduplication.

## Prerequisites

- Flutter SDK (Dart `^3.12.0`; CI uses Flutter 3.47.2)
- Rust ≥ 1.88 (edition 2021; `rust-toolchain.toml` pins 1.97.0 so local and CI lint with the same compiler)
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

The corduit dependency in `rust/Cargo.toml` carries a `path` (a sibling `../Corduit`) during local development. A CI checkout has no such directory, so before pushing, confirm CI resolves the crates.io version: drop the `path`, or have the workflow check that repository out first. Otherwise CI fails while resolving dependencies instead of failing later with a readable compile error.

## Icons

The single source is `assets/veloguard.png` and must be square and at least 1024x1024. On Windows run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/generate_icons.ps1
```

The script generates and validates Android, iOS, macOS, Windows, Linux, Web, and HarmonyOS assets. Generated icons should not be edited manually.

## Automated Verification

Every push and pull request runs Dart formatting, Flutter analysis and tests, an Android debug APK build, Android release lint (`./gradlew :app:lintRelease`, scoped to this app module — an unqualified `lintRelease` also lints plugin sources that live outside this repository), Rust formatting, Clippy with warnings denied, and all workspace tests. The release workflow runs the same gates first and only publishes when every one of them passes.

An automated build is not evidence of VPN behavior or protocol interoperability. Android VPN traffic, privileged Windows/Linux TUN routing, Apple Network Extension, HarmonyOS VPN FD handling, and real-server protocol compatibility remain subject to the release gates below.

## GitHub Release Configuration

Pushing a `vMAJOR.MINOR.PATCH` tag — or dispatching the release workflow from the default branch — runs the full quality gate first, then builds and publishes the stable release without further manual steps. A release carries:

- `VeloGuard-<tag>-android-debug.apk` — four-ABI debug build for diagnosis.
- `VeloGuard-<tag>-android-release.apk` — four-ABI optimized build for installation.
- `VeloGuard-<tag>-windows-x64-setup.exe` and `-windows-x64-portable.zip` — Inno Setup installer and a no-installation archive.
- `VeloGuard-<tag>-macos-universal.dmg` and `-macos-universal.zip` — universal (Apple silicon + Intel) disk image and archive; the app is unsigned, so the first launch is right-click → Open.
- `VeloGuard-<tag>-linux-x64.deb` and `-linux-x64.tar.gz` — Debian package and relocatable bundle.
- `update-manifest.json` and `SHA256SUMS` — the checksum-verified metadata the in-app updater reads.

The Android release APK is signed with the project's release key only when these repository Actions secrets are configured (`VELOGUARD_KEYSTORE_BASE64` is the base64 encoding of the keystore file, e.g. `base64 -w0 veloguard.jks`):

- `VELOGUARD_KEYSTORE_BASE64`
- `VELOGUARD_KEYSTORE_PASSWORD`
- `VELOGUARD_KEY_ALIAS`
- `VELOGUARD_KEY_PASSWORD`

Without them the release APK falls back to the debug key: it installs, but it can only upgrade installs that the debug key signed — configure the keystore before the first public stable release.

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
