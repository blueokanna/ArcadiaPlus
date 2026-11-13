# ArcadiaPlus

<p align="center"><img src="assets/arcadiaplus.png" width="112" height="112" alt="ArcadiaPlus"></p>

A cross-platform proxy client built with Flutter and Rust, with a Material 3 interface, profile management, policy routing and connection diagnostics.

[中文](README.md) · [Releases](https://github.com/blueokanna/ArcadiaPlus/releases) · [Documentation](https://github.com/blueokanna/ArcadiaPlus/wiki) · [Issues](https://github.com/blueokanna/ArcadiaPlus/issues)

## Features

- Import Clash-style subscriptions and local configurations; manage updates, nodes and policy groups.
- Rule, global and direct routing modes, with rule hits, connection details, DNS activity and traffic views.
- Proxy protocols and TUN processing supplied by Corduit; optional local recursive DNS supplied by RecurseX.
- Material 3 dynamic colors, light and dark themes, custom backgrounds, responsive navigation and interruptible shape motion.
- Android VPN foreground service, desktop system proxies and native platform integration, as detailed below.

See the [user guide](https://github.com/blueokanna/ArcadiaPlus/wiki/User-Guide) for protocols, rule types and configuration semantics. ArcadiaPlus does not supply nodes, servers or subscriptions.

## Screenshots

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

## Platform Status

| Platform | UI shell | System proxy | Full-tunnel VPN/TUN | Current conclusion |
| --- | --- | --- | --- | --- |
| Android | Present | N/A | `VpnService` path implemented | Requires device, ABI, and long-running regression tests |
| Windows | Present | Implemented | Wintun path implemented | Requires Windows 10/11 tests with elevation |
| Linux | Present | GNOME settings path (every `gsettings` exit code is checked) | IPv4 TUN path provided by corduit | TUN currently permits global mode only and explicitly rejects rule/direct; root/device testing is still required |
| macOS | Present | `networksetup` path | No Network Extension | Full-tunnel support cannot be claimed |
| iOS | Present | N/A | No Packet Tunnel Extension | Application shell only |
| HarmonyOS NEXT | Present | N/A | `VpnExtensionAbility` tunnel with the engine data path implemented | Requires a HarmonyOS NEXT device (authorization prompt, tunnel, engine routing); not claimed before that verification |

## Getting started

Download a package for your platform from [Releases](https://github.com/blueokanna/ArcadiaPlus/releases). Import a configuration, select a node, grant the required platform permissions and connect. Logs are available in Settings; see [troubleshooting](https://github.com/blueokanna/ArcadiaPlus/wiki/Troubleshooting) for diagnosis.

## Build from source

Use Flutter 3.47.x, Dart 3.13 and the pinned Rust toolchain. Android requires JDK 17 and NDK 28.2.13676358.

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --release
python scripts/check_android_page_sizes.py build/app/outputs/flutter-apk/app-release.apk
```

See [development](https://github.com/blueokanna/ArcadiaPlus/wiki/Development) for signing, other platforms and dependency checks, and [16 KB compatibility](https://github.com/blueokanna/ArcadiaPlus/wiki/Android-16-KB) for Android native-library requirements and verification.

## License

PolyForm Perimeter License 1.0.1 with repository-specific additional terms. Read [LICENSE](LICENSE) before use, modification or distribution, and retain the copyright notice.
