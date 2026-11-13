# ArcadiaPlus

<p align="center"><img src="assets/arcadiaplus.png" width="112" height="112" alt="ArcadiaPlus"></p>

Flutter 与 Rust 构建的跨平台代理客户端，提供 Material 3 界面、配置管理、策略路由和连接诊断。

[English](README_EN.md) · [下载发行版](https://github.com/blueokanna/ArcadiaPlus/releases) · [文档与故障排查](https://github.com/blueokanna/ArcadiaPlus/wiki) · [问题反馈](https://github.com/blueokanna/ArcadiaPlus/issues)

## 功能

- 导入 Clash 形态订阅与本地配置，管理更新、节点和策略组。
- 支持规则、全局与直连模式，提供规则命中、连接详情、DNS 活动及流量观察。
- Corduit 提供代理协议和 TUN 数据路径；RecurseX 提供可选的本地递归 DNS。
- Material 3 动态配色、明暗主题、自定义背景、响应式导航与可中断的形状动效。
- Android VPN 前台服务、桌面系统代理和平台原生集成；具体能力见下表。

协议、规则类型与配置语义见[使用指南](https://github.com/blueokanna/ArcadiaPlus/wiki/User-Guide-zh)。ArcadiaPlus 不提供节点、服务器或订阅。

## 截图

<details open>
<summary><b>💻 Windows 电脑端 </b></summary>
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
<summary><b>📱 安卓端 </b></summary>
<br>
<div align="center">
<img width="260" src="https://github.com/user-attachments/assets/21ef5262-a39c-40c6-9565-8ad7b02a5c26" />
&nbsp;&nbsp;&nbsp;&nbsp;
<img width="260" src="https://github.com/user-attachments/assets/a92930ff-03fd-43c2-a210-b08173f1c388" />
</div>
</details>

## 平台状态

| 平台 | UI 壳 | 系统代理 | 全局 TUN/VPN | 当前结论 |
| --- | --- | --- | --- | --- |
| Android | 有 | 不适用 | `VpnService` 路径已实现 | 需要真机、ABI 和长连接回归测试 |
| Windows | 有 | 已实现 | Wintun 路径已实现 | 需要管理员权限和 Windows 10/11 实机测试 |
| Linux | 有 | GNOME 设置路径（逐条校验 `gsettings` 退出码） | corduit 提供 IPv4 TUN 路径 | TUN 当前仅允许 global，rule/direct 会明确拒绝；仍需 root/实机验证 |
| macOS | 有 | `networksetup` 路径 | 未实现 Network Extension | 不能宣称全局代理支持 |
| iOS | 有 | 不适用 | 未实现 Packet Tunnel Extension | 仅应用壳 |
| HarmonyOS NEXT | 有 | 不适用 | `VpnExtensionAbility` 隧道 + 引擎数据面已实现 | 需要 HarmonyOS NEXT 真机验证（授权弹窗、隧道与引擎分流），未经真机不得宣称可用 |

## 开始使用

从 [Releases](https://github.com/blueokanna/ArcadiaPlus/releases) 下载对应平台的安装包。导入配置，选择节点，授予所需系统权限后启动连接。日志位于设置页；故障定位见 [Wiki](https://github.com/blueokanna/ArcadiaPlus/wiki/Troubleshooting-zh)。

## 从源码构建

使用 Flutter 3.47.x、Dart 3.13 与项目固定的 Rust 工具链。Android 需要 JDK 17 与 NDK 28.2.13676358。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build apk --release
python scripts/check_android_page_sizes.py build/app/outputs/flutter-apk/app-release.apk
```

完整工具链、签名、其他平台与依赖检查见[开发指南](https://github.com/blueokanna/ArcadiaPlus/wiki/Development-zh)。Android 原生库的构建和验收要求见 [16 KB 兼容性](https://github.com/blueokanna/ArcadiaPlus/wiki/Android-16-KB-zh)。

## 许可证

采用 PolyForm Perimeter License 1.0.1 及仓库附加条款。使用、修改和分发前请阅读 [LICENSE](LICENSE)，并保留版权通知。
