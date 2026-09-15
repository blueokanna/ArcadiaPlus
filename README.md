# VeloGuard

<p align="center">
  <img src="assets/veloguard.png" width="128" height="128" alt="VeloGuard 图标" style="border-radius: 12px;">
</p>

<p align="center">
  Flutter + Rust 跨平台代理客户端<br>
  <a href="README_EN.md">English</a>
</p>

> 状态：预发布。本仓库尚未达到在全部六个目标平台与全部协议上提供生产支持的标准。本文档只描述代码与验证证据支持的能力。

## 当前实现

- Flutter Material Design 3 UI：明暗主题、动态颜色、Google Fonts、响应式导航和页面/组件动画。
- Rust 侧只留一层 FFI：代理引擎、DNS、TUN 数据路径与全部代理协议都由 [corduit](https://crates.io/crates/corduit) 0.1.5 提供，本仓库不再重复实现协议；桥接层负责同步/异步适配、DTO 映射与平台入口。
- 配置转换采用显式降级：corduit 无法构建的协议节点会被丢弃、引用回落 `DIRECT`，corduit 没有对应类型的规则会被跳过——每次降级都通过 `onWarning` 上报，不静默处理。
- 可选本地递归解析：开启后由 [RecurseX](https://crates.io/crates/recurse-x) 从根服务器迭代解析，corduit 的 DNS 上游指向该前端。
- Android、Windows、Linux 共用 Rust TUN 数据包处理器，各平台独立管理设备生命周期。
- Windows、macOS、Linux、Android、iOS、HarmonyOS NEXT 的应用图标均由 `assets/veloguard.png` 统一生成。

## 协议状态

协议实现位于 corduit 0.1.5；本仓库只负责把它们接进 Flutter，并未对真实服务端互操作做验证。

| 协议 | 实现来源 | 说明 |
| --- | --- | --- |
| HTTP / SOCKS5 | corduit | 出入站路径均在引擎内 |
| Shadowsocks | corduit | 含 AEAD 与流密码路径 |
| VMess / VLESS / Trojan | corduit | 含 WebSocket、gRPC、TLS 传输 |
| TUIC / Hysteria 2 | corduit（`tuic`、`hysteria2` feature） | QUIC 路径，本构建已启用 |
| WireGuard | corduit（`wireguard` feature） | 隧道路径，本构建已启用 |
| ShadowsocksR / Hysteria v1 / shadowquic | 不支持 | 桥接层在配置转换时丢弃该节点并回落引用，同时上报警告 |

协议进入“已支持”状态至少需要：官方/主流服务端互操作测试、TCP 与 UDP 测试、认证失败测试、断线重连测试，以及各目标平台上的集成测试。

## 平台状态

| 平台 | UI 壳 | 系统代理 | 全局 TUN/VPN | 当前结论 |
| --- | --- | --- | --- | --- |
| Android | 有 | 不适用 | `VpnService` 路径已实现 | 需要真机、ABI 和长连接回归测试 |
| Windows | 有 | 已实现 | Wintun 路径已实现 | 需要管理员权限和 Windows 10/11 实机测试 |
| Linux | 有 | GNOME 设置路径 | 已实现仅 IPv4 的 global 模式路径 | 仍需 root/实机验证；在完成 socket mark 或物理网卡绑定前，rule/direct 模式会主动拒绝 |
| macOS | 有 | `networksetup` 路径 | 未实现 Network Extension | 不能宣称全局代理支持 |
| iOS | 有 | 不适用 | 未实现 Packet Tunnel Extension | 仅应用壳 |
| HarmonyOS NEXT | 有工程骨架 | 不适用 | 明确返回 `OHOS_VPN_UNSUPPORTED` | 不可发布 |

## 架构

```text
Flutter UI / Provider
        |
Flutter Rust Bridge（生成绑定）
        |
veloguard-lib（唯一桥接 crate：异步适配、DTO 映射、平台入口）
        |
corduit 0.1.5（引擎：配置、路由、出入站、DNS、TUN、全部协议）
        +-- courierust（HTTP/1.1 · HTTP/2 · HTTP/3 · WebSocket · TLS 栈）
        +-- nextjson / rustbinary（配置与二进制编解码）
RecurseX 0.1.0（可选：本地递归 DNS 前端，由桥接层托管生命周期）
```

corduit 是同步引擎，Dart 侧接口保持 `Future`——桥接层把每个引擎调用派发到阻塞工作线程（`run`），因此代理启停、延迟探测或 TUN 切换都不会卡住 Flutter 隔离区。

保持边界清晰比无目的地增加宏、泛型或复杂生命周期更重要。Rust 代码只在能减少重复、表达所有权或实现零成本抽象时使用这些能力。

## 环境要求

- Flutter SDK 对应 Dart `^3.10.4`
- Rust stable，支持 edition 2021 和 workspace resolver 3
- Android：Android SDK、NDK、JDK 17
- Windows：Visual Studio C++ 工具链；Wintun/管理员权限
- macOS/iOS：Xcode 与有效签名配置
- HarmonyOS NEXT：DevEco Studio、API 12 SDK、Flutter OHOS 工具链

## 构建与检查

```bash
flutter pub get
flutter analyze
flutter test

cd rust
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

Dart 桥接代码由 `flutter_rust_bridge.yaml` 驱动生成；改动 Rust 侧 `api`/`types` 后必须重新执行：

```bash
flutter_rust_bridge_codegen generate
```

平台构建必须在对应宿主和 SDK 上执行：

```bash
flutter build apk --release
flutter build windows --release
flutter build linux --release
flutter build macos --release
flutter build ios --release --no-codesign
```

HarmonyOS NEXT 使用 [ohos/README.md](ohos/README.md) 中的 DevEco/hvigor 流程。构建成功只证明工具链可用，不等于 VPN 数据路径已通过验证。

## 图标

唯一源文件为 `assets/veloguard.png`（正方形，至少 1024x1024）。Windows 环境执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/generate_icons.ps1
```

脚本会生成 Android、iOS、macOS、Windows、Linux、Web 和 HarmonyOS 所需资源，并校验源图尺寸。不要手工编辑生成图标。

## 自动化验证

每次 push 和 pull request 都会执行 Dart 格式检查、Flutter 分析与测试、Android Debug APK 构建、Android Release lint、Rust 格式检查、将警告视为错误的 Clippy，以及 Rust 全工作区测试。发布工作流会在生成签名 APK 时重复这些检查。

自动构建通过不等于 VPN 行为或协议互操作已经得到证明。Android VPN 真实流量、Windows/Linux 特权 TUN 路由、Apple Network Extension、HarmonyOS VPN FD 处理，以及真实服务端协议兼容性，仍必须满足下方发布门槛。

## GitHub 发布配置

手动执行发布工作流或推送发布标签前，必须配置以下仓库 Actions Secrets：

- `VELOGUARD_KEYSTORE_BASE64`
- `VELOGUARD_KEYSTORE_PASSWORD`
- `VELOGUARD_KEY_ALIAS`
- `VELOGUARD_KEY_PASSWORD`

`pubspec.yaml` 中的 `version`、变更日志顶部版本和 `vMAJOR.MINOR.PATCH` 标签必须一致。手动发布只能从默认分支执行。已经发布的 Release 及其产物不可变，工作流会明确失败，不会静默覆盖或把既有产物当作本次成功。

## 发布门槛

在标记正式版本前必须完成：

1. 用成熟、经过审计的实现替换或验证 WireGuard、Hysteria 2、TUIC；补充 Hysteria v1 与 NaiveProxy。
2. 完成 Linux global 路由接管/恢复的隔离网络测试，并补齐无路由环路的 rule/direct、IPv6、DNS 防泄漏与网络切换恢复；实现 Apple Network Extension 和 HarmonyOS VPN FD 到 Rust 的完整生命周期。
3. 为每个协议建立容器化互操作测试矩阵，并在 CI 中覆盖 TCP、UDP、IPv4、IPv6、重连和错误认证。
4. 在六个平台完成签名发布构建、安装、启停、休眠恢复、网络切换和泄漏测试。

## 免责声明

- **合法使用是唯一被授权的用途。** VeloGuard 是网络工具，本身不提供代理服务器、节点或订阅；你需要自行准备配置，并对其合法性负责。
- **合规责任在你自己。** 你需要确保使用行为符合所在司法管辖区的法律、所接入网络的条款，以及适用的出口管制与制裁规定。将本软件或其改动、衍生作品用于违法用途，不在许可范围内，并构成对[许可条款](LICENSE)的违反。
- **作者与贡献者不承担责任。** 在法律允许的最大范围内，作者与贡献者对因使用或无法使用本软件产生的任何直接或间接损失不负责，也不对任何人（无论是否经你授权）使用本软件从事违法行为引发的后果负责。
- **不构成法律意见。** 本文档与应用内提示只是风险说明，不是法律建议；需要时请咨询执业律师。
- **无担保。** 软件按「现状」提供，不附带任何明示或默示保证（见 `LICENSE` 的 *No Liability* 一节）。

## 许可证

**PolyForm Perimeter License 1.0.1**——见 [`LICENSE`](LICENSE)：正文是官方 [PolyForm Perimeter
1.0.1](https://polyformproject.org/licenses/perimeter/1.0.1)，末尾多出一段由许可人自己增加的附加条款。

实际含义：

- **可免费用于除「竞争产品」之外的任何目的。** 阅读、构建、修改、自托管、内嵌进公司内部或客户系统、教学使用、随非竞争软件分发：都允许。不允许的是向他人提供替代本软件功能或价值的产品——包括以服务接口形式提供，也包括移植到其它语言（见
  [Noncompete](https://polyformproject.org/licenses/perimeter/1.0.1/#noncompete) 与
  [Competition](https://polyformproject.org/licenses/perimeter/1.0.1/#competition)）。
- **不是 OSI 认可的开源许可**，而是 *source-available（源码可获取）* 许可：源码可以按上面的条款阅读和修改，而且你转发出去的副本，接收方也同时得到这份条款。
- **必须保留署名通知。** 分发本软件或其任何部分时，必须随附 `LICENSE` 全文（或上述官方链接），以及其中的 `Required Notice: Copyright 2026 blueokanna and HyphenTeam (https://github.com/blueokanna/Courierust)`（见 *Notices*）。
- **无担保、无责任**（在法律允许范围内），并且末尾那段附加条款把同样的限制延伸到「他人用本软件（或其改动/衍生作品）从事违法行为」的情形（见 `LICENSE` 末尾 *Additional Term Adopted by the Licensor*）。
