# ArcadiaPlus

<p align="center">
  <img src="assets/arcadiaplus.png" width="128" height="128" alt="ArcadiaPlus Logo" style="border-radius: 12px;">
</p>

<p align="center">
  Cross-platform proxy client built with Flutter and Rust<br>
  <a href="README.md">中文</a>
</p>

## What This Is

ArcadiaPlus is a cross-platform proxy client: Flutter owns the interface and the per-platform takeover, and the Rust side is a single FFI bridge — the proxy engine, DNS, the TUN data path, and every protocol come from [corduit](https://crates.io/crates/corduit).

It reads Clash-shaped profiles (`proxies`, `proxy-groups`, `rules`, `rule-providers`, `dns`), translates them into the rule table the engine executes, and shows what that engine is doing: the table itself, per-rule hit counts, what conversion dropped, and when each rule set last refreshed. It ships no servers, nodes, or subscriptions — you supply the configuration, and lawful use is on you.

The sections below state what the current build actually does, including the platforms where support cannot yet be claimed.

<br>

### 📸 Product Screenshot
<details open>
<summary><b>💻 Windows PC </b></summary>
<br>
<div align="center">
  <img width="48%" src="https://github.com/user-attachments/assets/73f4119d-a59e-4d88-b9df-2777ca0ff53b" />
  <img width="48%" src="https://github.com/user-attachments/assets/e6650f71-1018-46a5-a6a9-8d9d663bb8b3" />
  <br><br>
  <img width="48%" src="https://github.com/user-attachments/assets/63ee8199-4e72-4fb9-8ae9-a02689c234ff" />
  <img width="48%" src="https://github.com/user-attachments/assets/a28545de-b4e5-47a3-b040-80e2136a844c" />
</div>
</details>
<br>
<details open>
<summary><b>📱 Android </b></summary>
<br>
<div align="center">
<img width="260" src="https://github.com/user-attachments/assets/21ef5262-a39c-40c6-9565-8ad7b02a5c26" />
&nbsp;&nbsp;&nbsp;&nbsp;
<img width="260" src="https://github.com/user-attachments/assets/a92930ff-03fd-43c2-a210-b08173f1c388" />
</div>
</details>

## Implemented Scope

- Flutter Material Design 3 UI with light/dark themes, dynamic color, Google Fonts, responsive navigation, and component/page motion.
- A single Rust bridge layer: the proxy engine, DNS, TUN data path, and every proxy protocol come from [corduit](https://crates.io/crates/corduit) 0.3.5, and this repository no longer reimplements them. The bridge owns sync/async adaptation, DTO mapping, and platform entry points.
- Runtime configuration uses strict validation: missing required rule sets, unsupported rule types and missing outbounds prevent startup. Offline previews can show conversion warnings; runtime routing is never changed by silently skipping rules.
- Optional local recursion: with it enabled, [RecurseX](https://crates.io/crates/recurse-x) resolves from the root servers iteratively and corduit's DNS upstreams point at that front-end.
- Rule sets (`rule-providers`) are owned by Dart: `RuleProviderService` downloads, validates, normalises and caches them in the app's private directory, refreshing at the profile's interval (86400 seconds by default). The engine receives local `file` providers. Failed downloads, empty content and unsupported entries preserve the last complete cache. A required rule set without a valid cache prevents startup.
- The GeoIP database ships with the installer (`assets/Country.mmdb`), is unpacked into the app support directory at start-up, and is registered with the engine; a failure to unpack or register is recorded, and `GEOIP` rules simply do not match while it is missing — never a silent downgrade.
- Shared Rust TUN packet processing for Android, Windows, and Linux, with platform-owned device lifecycles.
- Generated app icons for Windows, macOS, Linux, Android, iOS, and HarmonyOS NEXT from `assets/arcadiaplus.png`.

## Startup diagnostics and interface behavior

Start with the error details retained on the home screen when startup fails. Original configuration and VPN errors are logged; cleanup no longer replaces them with a generic missing-profile message. The home screen shows a running service only after the engine confirms it and, on Android, the VPN data path is established.

Fresh installs and older settings without an encryption choice follow subscription DNS. Existing strict-encryption choices remain intact. Profiles without upstreams use the built-in encrypted endpoints. Preferred encryption upgrades known public resolvers but preserves private and unsupported subscription endpoints, so plaintext queries remain possible and local recursion is compatible. Strict encryption separately constrains primary, fallback, bootstrap and domain-policy resolvers. Failed compatibility checks preserve the previous mode. The DNS page uses the runtime converter for preflight checks and offers start/restart to apply changes.

Public resolvers are upgraded only to verified endpoints of the same operator. For example, `119.29.29.29` uses DNSPod DoT with the `dot.pub` certificate identity, as documented in the [Tencent Cloud integration guide](https://cloud.tencent.com/document/product/302/110784). Strict mode rejects subscriptions that depend on private plaintext resolvers such as `tcp://private-resolver:8080`. Supply a compatible encrypted endpoint or disable strict protection to retain subscription routing; this never disables certificate verification or replaces private policies with public resolvers.

Local recursion starts and stops with the proxy, listening only on loopback. Both UDP and TCP must bind before the address is published. Startup does not depend on public website probes. The forwarding layer preserves local precedence, a recovery budget and a brief failure cooldown. The DNS page distinguishes saved settings, listener state and actual query counters. Startup errors appear in both logs and the status card.

VPN DNS distinguishes NODATA, NXDOMAIN and query failures: a name without an AAAA record receives NOERROR with no answer; a nonexistent name receives NXDOMAIN; transport failures receive SERVFAIL. Normal empty answers retain their type and do not trigger system-DNS queries outside subscription policy.

The proxy page's automatic layout uses available width; explicit one/two-column choices are respected. Narrow cards put names below icons and grow with text scaling. Mobile navigation floats above the page, blurring only its own background; list padding and floating actions share navigation clearance. List entrances reuse the page timeline. Background state and reduced-motion preferences use the global motion switch; performance needs measurements on target devices in profile mode.

`ExpressiveShape` reuses page timelines. `AnimatedExpressiveShape` creates a controller on its first state change. Home status, empty states, selected nodes and DNS status share cached shapes and spring parameters. Interrupted transitions retain progress and velocity, animate the clip region and stop when settled.

## Dashboard caching, resource management and color

An application-owned controller retains the exit IP result and any in-flight lookup across navigation. Returning to Home does not repeat a completed lookup for one hour, including failed lookups. An actual node selection, proxy port or routing mode change invalidates the cache; manual refresh remains available. Synchronizing an unchanged selection does not invalidate it. Backgrounding cancels unfinished work and rejects late replies; an interrupted lookup can retry on resume, while completed results keep their remaining lifetime. DNS queries have been removed from Home and remain available in the DNS tab on the connections page.

Cold startup loads settings and native libraries. The engine is built when starting the service, visiting the proxy page or inspecting rules. Profile lists retain metadata only; YAML belongs to its configuration file. Legacy preference copies are removed only after checking the file, recovering missing files from the backup first. The node page retains only nodes and groups, without a duplicate DNS policy or rule table, and reuses parsed results when the subscription is unchanged. Disposing the connections page releases its Dart snapshot. A bounded LRU cache retains scroll state for up to 12 destinations; node search and layout preferences are stored separately. Retained decoded images are capped at 16 MiB on mobile and 32 MiB on desktop, and unused images are evicted when backgrounded. Replacing a wallpaper evicts all supported decoded sizes for that file.

File maintenance runs at startup and on foreground entry, at most once a day. It removes abandoned rule download temporary files and unselected wallpaper copies older than 24 hours, preserving active rules and the current wallpaper. Motion uses Flutter's frame scheduler and native navigation timeline. Pages, MD3E shapes and visible rows share progress; pushed pages no longer allocate a second entrance controller. Reduced motion and background suspension remain supported. See the [Material 3 motion specification](https://m3.material.io/styles/motion/overview/how-it-works).

The ten presets reference the supplied *PANTON 3.0 C* color-chart PDF. Seeds were sampled from its MuPDF 1.28.2 sRGB rendering, then passed to `ColorScheme.fromSeed` for MD3 light and dark roles. The PDF uses CMYK print simulations: these are screen approximations, not official Pantone RGB definitions or print calibration guarantees. The theme picker includes the reference number. Optional dynamic color still uses the system palette.

| Preset ID | Reference | Screen seed | PDF page |
| --- | --- | --- | --- |
| default | 286 C | `#0060A9` | 6 |
| ocean | 3005 C | `#0081C4` | 7 |
| forest | 347 C | `#009A66` | 8 |
| sunset | 179 C | `#F15C2A` | 3 |
| purple | 2587 C | `#6351A2` | 5 |
| teal | 320 C | `#00A1B2` | 7 |
| rose | 213 C | `#EC0B6D` | 4 |
| amber | 123 C | `#FDB826` | 1 |
| indigo | 2756 C | `#173B8D` | 6 |
| cyan | 3125 C | `#00B5C8` | 7 |

Exit assessments, traffic descriptions and palette names cover all 11 locales, with separate Simplified and Traditional Chinese copy. Regression tests cover the one-hour cache boundary, real TCP/UDP outbound accounting, safe cache cleanup, light/dark text contrast and page layout. Image cache budgets are not process memory guarantees. Compare PSS/RSS and frame timings using profile/release builds on the same device and configuration; `scripts/android-profile.ps1` captures samples. See [Flutter memory analysis](https://docs.flutter.dev/tools/devtools/memory).

## Rules

Conversion translates the profile rule by rule. The vocabulary it can express:

| Type | Semantics |
| --- | --- |
| `DOMAIN` / `DOMAIN-SUFFIX` / `DOMAIN-KEYWORD` / `DOMAIN-REGEX` | Domain matching; the regular expression is compiled by the engine as written, so inline flags such as `(?-i)` behave the way Clash makes them behave |
| `GEOIP` | Country matching; `LAN` / `PRIVATE` need no database, and every other code needs `Country.mmdb` (shipped with the installer; when it is missing the reason is recorded and the rules never match) |
| `IP-CIDR` / `IP-CIDR6` / `SRC-IP-CIDR` | Address ranges; `no-resolve` travels with the rule, so it only ever sees the address the client supplied and forces no lookup |
| `DST-PORT` / `SRC-PORT` / `IN-PORT` | Ports and port ranges (`80,443,1000-2000`) |
| `IN-TYPE` / `IN-NAME` / `IN-USER` | Which inbound the connection arrived on, which protocol it spoke, and which user it authenticated as (compared case-insensitively) |
| `PROCESS-NAME` / `PROCESS-PATH` | Process matching |
| `NETWORK` | `tcp` / `udp` |
| `RULE-SET` | References a `rule-providers` entry; the engine only reads local files, so downloading, validating, caching, and refreshing happen on the Dart side |
| `GEOSITE` | Matches the provider with the same name; `cn`, `geolocation-!cn`, `category-ads-all` and `private` can use the corresponding Loyalsoldier data; other categories require compatible rule sets |
| `AND` / `OR` / `NOT` | Logical composition with nested conditions, as in `AND,((DOMAIN-SUFFIX,a.com),(NETWORK,tcp)),PROXY` |
| `MATCH` / `FINAL` | Catch-all rule |

Unsupported runtime rules such as `SCRIPT`, `PROCESS-PATH-REGEX` and `SUB-RULE` produce an error and stop loading. Unsupported binary rule sets are never treated as text. Failed refreshes preserve the last valid cache; required rule sets without a valid cache must be supplied before startup.

The Rules entry in settings (`/rules`) shows the engine's table with each rule's **live hit count**, every conversion warning from the current profile, and each rule set's readiness, entry count, and last refresh. Hit counts are why this screen exists: a rule that never fires, or one that fires for everything, is visible instead of inferred. The table is read a window at a time: the Rust side keeps the snapshot and answers window and search requests (the top page quietly re-reads the hit counts every five seconds), and the screen builds only the rows it shows — a subscription with an inline ACL can hold tens of thousands of rules, and decoding all of them on the UI isolate while building a row per entry is exactly how the diagnostic page used to take the whole app down with it. The search box scans the full table in Rust and returns the total match count plus the first 500 matches.

## Protocol Status

This build uses the crates.io releases of Corduit 0.3.5 and RecurseX 0.2.6. `rust/Cargo.lock` pins versions and checksums. Enabled features include `hysteria`, `hysteria2`, `tuic`, `reality`, `shadowtls`, `wireguard`, `quic` and `tls13`. CI verifies that the bridge and engine share the resolver, socket factory and Android JNI dependency identities.

| Protocol | Implementation | Notes |
| --- | --- | --- |
| HTTP / SOCKS5 | corduit | Inbound and outbound paths inside the engine |
| Shadowsocks | corduit | AEAD and stream ciphers; the SIP003 plugins `obfs` (simple-obfs http/tls), `v2ray-plugin` (websocket with mux framing, on by default — matching the reference server and mihomo; `mux: false` turns it off; `skip-cert-verify` and custom `headers` pass through) and `shadow-tls` (v3) are implemented natively, so nodes carrying them convert normally (unimplemented plugins and options are refused by name); a plugin shapes TCP only, so its node runs with UDP disabled |
| ShadowsocksR | corduit | Stream ciphers plus the protocol/obfs plugin layers; `auth_chain_*`, `random_head`, AEAD methods and the exotic block ciphers are refused by name with the reason |
| VMess / VLESS / Trojan | corduit | WebSocket, gRPC and TLS transports |
| Hysteria 1 / Hysteria 2 / TUIC | corduit (`hysteria`, `hysteria2`, `tuic` features) | QUIC paths, all enabled in this build |
| Snell | corduit | v4/v5 record protocol; both `obfs: http` and `obfs: tls` are implemented from the reference (the TLS obfuscation's ClientHello and record framing are byte-aligned with sing-snell / Surge 6.4.4); v6 and pre-v4 are refused by name |
| WireGuard | corduit (`wireguard` feature) | Tunnel path, enabled in this build |
| ShadowTLS | corduit (`shadowtls` feature) | The v3 tunnel: a hand-written engine config can use `type: shadowtls`, and the subscription-side `plugin: shadow-tls` works too — the plugin path reuses the same handshake and framing |
| shadowquic / `ssh`-style types | Unsupported | The bridge drops such nodes during conversion, rewrites references, and raises a warning |

A protocol can move to “supported” only after interoperability tests against mainstream servers, TCP and UDP coverage, authentication failure tests, reconnect tests, and target-platform integration tests.

## Platform Status

| Platform | UI shell | System proxy | Full-tunnel VPN/TUN | Current conclusion |
| --- | --- | --- | --- | --- |
| Android | Present | N/A | `VpnService` path implemented | Requires device, ABI, and long-running regression tests |
| Windows | Present | Implemented | Wintun path implemented | Requires Windows 10/11 tests with elevation |
| Linux | Present | GNOME settings path (every `gsettings` exit code is checked) | IPv4 TUN path provided by corduit | TUN currently permits global mode only and explicitly rejects rule/direct; root/device testing is still required |
| macOS | Present | `networksetup` path | No Network Extension | Full-tunnel support cannot be claimed |
| iOS | Present | N/A | No Packet Tunnel Extension | Application shell only |
| HarmonyOS NEXT | Present | N/A | `VpnExtensionAbility` tunnel with the engine data path implemented | Requires a HarmonyOS NEXT device (authorization prompt, tunnel, engine routing); not claimed before that verification |

## Routing Modes

Global mode uses the `GLOBAL` selector on the proxy page, with selections saved per profile. If absent, the app builds it from available nodes instead of selecting the first domestic/direct group. With no usable nodes, traffic is rejected. An explicitly configured `GLOBAL` preserves its members and choice, including user-configured `DIRECT`.

RecurseX 0.2.6 / courierust 1.1.2 currently require the DoH/DoH3 connection IP and certificate IP identity to match; independent hostname identity overrides are unsupported. Defaults use Alibaba DoH endpoints with IP certificates. Known public hostname endpoints are converted to compatible verified endpoints of the same operator with a warning. Unknown private DoH configurations fail explicitly: use a supported IP endpoint or DoT/DoQ, never disabled certificate verification.

`rule` / `global` / `direct` are decided inside the engine: the inbounds, the TUN data path, and the Android VPN all hand their connections to one router, so switching modes never requires rebuilding the tunnel.

| Platform | What a mode switch does | Notes |
| --- | --- | --- |
| Android | `set_android_proxy_mode` (engine runtime mode) plus the notification text | The VPN route is always `0.0.0.0/0` and the engine decides per dial; every port-53 query that enters the tunnel is answered by the netstack's fake-IP resolver |
| Windows | `set_windows_proxy_mode` | Switching to `global` while the route table is not in global mode is retried through `enable_tun_mode_with_mode("global")`, which rebuilds the routes |
| Linux / macOS | `set_proxy_mode` (engine runtime mode) | Linux TUN permits global mode only; macOS has no TUN implementation, while its system proxy still supports engine routing |
| System proxy | Independent of the mode | Points at the local mixed port; Linux checks every `gsettings` exit code, and Windows snapshots the previous proxy settings before enabling and restores them on disable |

Rule sets are checked when the engine is prepared and after a profile update. While the service is running, checks also run on foreground entry and every 15 minutes. Opening a stopped dashboard does not build the engine or download rule sets. Only providers whose declared interval (one day by default) has elapsed actually make a network request, and those requests carry `If-None-Match` / `If-Modified-Since`; a 304 means the cached copy is current. A refreshed rule set lands on a content-addressed file name, which changes the config, so the running engine loads the new content on the next `reload_corduit`.

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
adb shell 'P=$(pidof com.blueokanna.arcadiaplus); awk "{print \$14, \$15}" /proc/$P/stat; sleep 15; awk "{print \$14, \$15}" /proc/$P/stat'

# 4) I/O growth. Compare with (3): CPU climbing while the byte count does not is a spin.
adb shell cat /proc/$(pidof com.blueokanna.arcadiaplus)/io

# 5) Per-thread attribution: an empty wchan (shown as 0) means the thread is on the CPU in userspace, blocked in no syscall.
adb shell 'P=$(pidof com.blueokanna.arcadiaplus); for t in /proc/$P/task/*; do echo "$(cat $t/comm) $(cat $t/wchan)"; done | sort | uniq -c | sort -rn'
```

The bar: with the tunnel idle, `procs_running` should stay in the single digits, and threads that are accounted as running should show a kernel sleep symbol in `wchan` rather than an empty one.

## Known Limitations

Gaps and boundaries worth knowing, so nothing here is mistaken for a feature it is not:

- The DNS surface the app edits is its settings page, applied only while “override DNS” is on — without it the profile's `dns` block wins. An override is not a whole-section replacement either: `nameserver-policy` and `default-nameserver` are still read from the profile (the first is a subscription's only way to resolve its own node domains, the second bootstraps upstreams written as host names such as `tls://doh.pub`), and the **bootstrap resolvers** list the page now offers comes before the profile's entries. The engine's wider DNS surface (`fallback-filter`, `fake-ip-range` / `-filter` / `-ttl`, `cache-size`, `hosts`) still passes through from the profile.
- The system proxy bypass list reaches Windows (WinINET), Linux (`ignore-hosts`) and macOS (`networksetup`). CIDR entries are expanded into exact wildcard patterns where required.

## System proxy and DNS connection behavior

Windows enables the system proxy after service startup by default; automatic activation can be disabled in Settings. Fresh installs and settings migrations include the following bypass entries while preserving custom entries, IPv6 loopback and link-local entries:

```text
localhost;127.*;192.168.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;*.local
```

Windows uses the WinINET connection API to snapshot, apply and verify settings, then restores the snapshot on disable. Reads use `INTERNET_PER_CONN_FLAGS_UI` to preserve the configured autodetection state. A dormant PAC URL retained by Windows no longer causes a successful activation to be rolled back; failed verification still restores the previous settings. This bypass list applies to the system proxy. TUN/VPN traffic follows tunnel routing and engine rules.

- **Prefer encrypted DNS** upgrades supported public resolvers to verified encrypted endpoints operated by the same provider. Private subscription resolvers, domain policies and bootstrap settings remain intact. This preference does not mean every DNS path is encrypted.
- **Strict encrypted DNS** requires encryption on every resolution path and rejects incompatible configurations before startup. It disables local recursion and never silently retries TLS failures over plaintext.
- **Local recursion** listens only on loopback and takes precedence while healthy; configured upstreams recover failures. Root and authoritative queries require reachable UDP/TCP port 53. A ready listener does not guarantee successful resolution for every name or DNSSEC chain validation.
- **Android DNS** inside the VPN is answered by the netstack. The app skips additional privileged low-port listeners; explicitly configured unprivileged listeners remain available. Local recursion continues to use its own ephemeral loopback port.

The Shadowsocks reader preserves partial salt, encrypted-length and payload state across read timeouts without resetting frames or nonces. Truncation and authentication errors still fail. DNS resolution and TCP dialing share one connection deadline. Groups do not count cancelled connections as node failures or mark nodes unavailable after they have delivered payload; session lifetime no longer overwrites probe latency. Automatic groups emit `retired` once when crossing the failure threshold and recover after a success. Manual groups continue to honor the selected member.

These fixes cannot eliminate network blocking, invalid node credentials or server-initiated disconnects. Keep the first DNS/TLS/handshake error preceding `retired` and identify the affected protocol and node. Windows settings interaction and Android network transitions still require device validation.

## Architecture

```text
Flutter UI / Provider
        |
Flutter Rust Bridge (generated bindings)
        |
lib-arcadiaplus (the only bridge crate, rooted at rust/: async adaptation, DTO mapping, platform entry points)
        |
corduit 0.3.4 (engine: config, routing, inbounds, outbounds, DNS, TUN, all protocols)
        +-- courierust (HTTP/1.1 · HTTP/2 · HTTP/3 · WebSocket · TLS stack)
        +-- nextjson / rustbinary (config and binary codecs)
recurse-x 0.2.6 (optional local recursion: the resolver, plus the client-facing UDP/TCP DNS server whose lifecycle the bridge owns)
```

corduit is synchronous while the Dart surface stays `Future`-based, so the bridge dispatches every engine call onto a blocking worker (`run`). Starting the proxy, probing latency, or toggling TUN therefore never stalls the Flutter isolate.

Clear ownership boundaries matter more than adding macros, generics, or complex lifetimes without a measurable benefit. These Rust features should be used only for useful zero-cost abstractions, ownership modeling, or meaningful deduplication.

## Prerequisites

- Flutter SDK (Dart `^3.13.0`, Flutter `>=3.47.0 <3.48.0`; CI and the release workflow pin 3.47.2, the same line local development uses)
- Rust ≥ 1.88 (edition 2024; `rust-toolchain.toml` pins 1.97.0 so local and CI lint with the same compiler)
- Android: Android SDK, NDK, and JDK 17
- Windows: Visual Studio C++ toolchain, Wintun, and elevation
- macOS/iOS: Xcode and valid signing configuration
- HarmonyOS NEXT: DevEco Studio 5.0.5+ (or the same command-line tools CI uses) and the CPF-Flutter Flutter OHOS SDK; the HAP is also built by the `ohos` job in GitHub Actions — see [ohos/README.md](ohos/README.md)

## Build and Check

Home traffic cards wrap to fit the window and text scale. “Direct traffic” and “Proxy traffic” follow the final outbound transport, regardless of group names or destination country. Both include uploaded and downloaded payload, closed short connections and UDP, excluding protocol framing, TUN headers and retransmission overhead. Android and desktop use the same outbound counters, with totals derived from the same direct/proxy sample. The connection list no longer adds synthetic TUN aggregates labeled as proxy connections.

```bash
flutter pub get
flutter analyze
flutter test

cd rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

`pubspec.lock` is valid for exactly one Flutter version line: the SDK ships `test_api`, `matcher`, `vector_math`, `meta`, `intl`, and their versions move with the SDK line. A lockfile recorded on another line either fails `flutter pub get` outright or gets silently rewritten to the version you ran — and then the `flutter pub get --enforce-lockfile` step in CI fails. This repository is locked to Flutter 3.47.x (Dart 3.13), so check that your local Flutter falls inside `environment.flutter` and that the lockfile is untouched before pushing:

```bash
flutter pub get --enforce-lockfile
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

HarmonyOS NEXT HAPs are built by the `ohos` job in CI and by the DevEco/hvigor workflow in [ohos/README.md](ohos/README.md). CI additionally asserts that the HAP really contains `libapp.so`, `librust_lib_arcadiaplus.so` and `libarcadia_core.so`: a successful build proves the packaging chain, and the VPN data path (authorization prompt, tunnel, engine routing) is still verified device-by-device against that document's checklist.

Build the published crates.io engines directly; sibling Corduit and RecurseX checkouts are no longer required. CI and release builds use the committed lockfile with `--locked`. After upgrading dependencies, commit both `rust/Cargo.toml` and `rust/Cargo.lock`, then run `python scripts/check_engine_dependencies.py --offline` to verify checksums and shared dependency identities. Omit `--offline` when downloading dependencies for the first time. Local path, Git and source replacement overrides are rejected. The obsolete checkout action, revision pins and network patch have been removed; the Corduit 0.3.5 release includes those network fixes, and application regression tests exercise the published package.

## Disclaimer

- **Lawful use is the only permitted purpose.** ArcadiaPlus is a network tool. It ships no proxy servers, nodes, or subscriptions; you supply your own configuration and are responsible for it.
- **The compliance burden is yours.** Keep your use within the law of every jurisdiction that applies to you, the terms of the networks you rely on, and applicable export-control and sanctions rules. Using this software, or a change or new work based on it, to break the law is not a permitted purpose and violates the [license terms](LICENSE).
- **The authors and contributors accept no liability.** As far as the law allows, they are not liable for any direct or indirect loss arising from use or inability to use this software, nor for any consequence of anyone using it unlawfully, whether or not you authorized that use.
- **This is not legal advice.** The warnings here and in the app describe risk only; they are not a legal opinion. Consult a qualified lawyer when you need one.
- **No warranty.** The software comes as is, without any express or implied warranty, including merchantability, fitness for a particular purpose, and non-infringement (see *No Liability* in `LICENSE`).

## License

**PolyForm Perimeter License 1.0.1** — see [`LICENSE`](LICENSE): the text is the official [PolyForm Perimeter 1.0.1](https://polyformproject.org/licenses/perimeter/1.0.1), with one additional term appended by the licensor.

What that means in practice:

- **Free for any purpose except competing products.** Reading, building, modifying, self-hosting, embedding in internal or customer systems, teaching, and shipping alongside non-competing software are all allowed. What is not allowed is providing others a product that substitutes for this software's functionality or value — including as a service interface, and including a port to another language (see [Noncompete](https://polyformproject.org/licenses/perimeter/1.0.1/#noncompete) and [Competition](https://polyformproject.org/licenses/perimeter/1.0.1/#competition)).
- **Not an OSI-approved open-source license**, but a *source-available* license: you can read and modify the source under the terms above, and anyone you pass a copy to receives these same terms.
- **Keep the required notice.** When you distribute the software or any part of it, pass along the full `LICENSE` text (or the official link above) and the `Required Notice: Copyright 2026 blueokanna and HyphenTeam (https://github.com/blueokanna/ArcadiaPlus)` line it carries (see *Notices*).
- **No warranty, no liability** (as far as the law allows), and the appended term extends the same limit to anyone using this software, or a work based on it, to break the law (see *Additional Term Adopted by the Licensor* at the end of `LICENSE`).
