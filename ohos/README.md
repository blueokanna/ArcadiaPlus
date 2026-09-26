# ArcadiaPlus · HarmonyOS NEXT 构建与集成指南

> VPN 数据面已完成：隧道与引擎运行在 `VpnExtensionAbility` 进程内，UI 进程只负责启停与状态镜像。
> 本文档描述构建链路、进程架构与真机验证清单。

## 架构（先读这一节，构建问题九成源于误解它）

```
┌─ UI 进程（Flutter）──────────────────────────────┐      ┌─ VpnExtension 进程（ArkTS + Rust 引擎）──────────┐
│ ArcadiaPlusPlugin (com.arcadiaplus/ohos_proxy)    │      │ ArcadiaPlusVpnAbility                             │
│  · startVpn / stopVpn / isVpnRunning              │      │  · vpnConnection.create() → tun fd                │
│  · 订阅 com.arcadiaplus.VPN_STATUS                │      │  · protectProcessNet / protect(fd)                │
│  · 发布 com.arcadiaplus.VPN_COMMAND               │      │  · libarcadia_core.so（NAPI）→ Rust 引擎          │
└──────────────┬────────────────────────────────────┘      │      · corduit 引擎 + solidtcp 用户态协议栈        │
               │ Want（configPath / geoipPath / logPath / mode）│      · 读写 tun fd，按规则分流                     │
               └─────────────────────────────────────────► └───────────────────────────────────────────────────┘
```

三个不可协商的约束，决定了上述结构：

1. **tun fd 只能由 `VpnConnection.create()` 产生**，而它只能在携带 `VpnExtensionContext` 的扩展进程里调用。
2. **`protect` / `protectProcessNet` 同样只有扩展进程能调**：引擎自己的出站 socket 必须豁免于刚装上的隧道，
   否则「连代理服务器」这一跳会被路由回自己的 TUN，形成自环。
3. **两个进程之间只共享沙箱文件，不共享内存**：
   引擎配置、GeoIP 数据库、引擎日志都以路径形式随启动请求传入扩展进程；
   状态与命令通过公共事件（CommonEvent）双向传递。

## 目录结构

```
ohos/
├── entry/
│   └── src/main/
│       ├── ets/
│       │   ├── plugins/ArcadiaPlusPlugin.ets           # UI 进程：通道 + 状态镜像
│       │   └── vpnextension/ArcadiaPlusVpnAbility.ets  # 扩展进程：隧道 + 引擎宿主
│       ├── cpp/
│       │   ├── napi_init.cpp                           # Rust 入口的 NAPI 包装（含 protect 回调 TSFN）
│       │   ├── CMakeLists.txt
│       │   └── types/libarcadia_core/                  # ArkTS 侧类型声明
│       └── module.json5                                # extensionAbilities(type: vpn) + 权限
├── scripts/build-rust-ohos.sh                          # Rust 引擎交叉编译与产物落位
└── har/                                                # flutter build har 产物 + UI 进程用的 .so
```

## 构建步骤

### 0. 前置

- DevEco Studio 5.0+，HarmonyOS SDK API 12+；
- Rust 1.97（rustup，仓库 `rust-toolchain.toml` 已固定）：
  `rustup target add aarch64-unknown-linux-ohos`
- 设置 `OHOS_NDK` 指向 SDK 的 `native` 目录（如 `…/sdk/default/openharmony/native`），
  或让脚本自行探测常见安装路径。

### 1. 构建 Rust 引擎（两个产物）

```bash
bash ohos/scripts/build-rust-ohos.sh
```

- `ohos/entry/src/main/cpp/thirdparty/arm64-v8a/librust_lib_arcadiaplus.a`
  —— 静态链接进 `libarcadia_core.so`（扩展进程的引擎）。
- `ohos/har/arm64-v8a/librust_lib_arcadiaplus.so`
  —— UI 进程的 Flutter 插件库（FRB）。

脚本在编译前会删除旧产物并以 cargo 退出码判定成败，避免「文件存在即成功」的假绿；
同时给 `dart-sys` 这类带 C shim 的依赖导出 NDK 的 CC/AR/CFLAGS 交叉编译环境。

### 2. 构建 Flutter HAR 与 HAP

```bash
flutter build har --release        # 生成 ohos/har/flutter*.har
```

随后用 DevEco Studio 打开 `ohos/` 目录构建 HAP。`ohos/entry/build-profile.json5`
已配置 `externalNativeOptions`，CMake 会把 `napi_init.cpp` 与上述 `.a` 链接为
`libarcadia_core.so`。

### 3. 签名与安装

在 `ohos/build-profile.json5` 配置签名材料后，通过 DevEco 或 `hdc install` 安装到
HarmonyOS NEXT 真机。

## 运行流程

1. Dart 侧在启动服务时生成引擎配置，写入 `<沙箱>/engine/config.json`，
   并把 GeoIP 路径与日志路径一并登记（`PlatformProxyService.prepareOhosEngine`）。
2. `startVpn` → 插件携带四个参数唤起 `ArcadiaPlusVpnAbility`；
   首次启动时系统弹出 VPN 授权对话框（等待用户操作不会触发超时误报：60s 预算）。
3. 扩展进程内：`create()` 拿到 tun fd → 尽可能调用 `protectProcessNet()`（API 22+），
   否则注册按 fd 的 `protect` 回调（线程安全函数，逐 socket 异步保护）→
   `arcadiaCore.startVpn(...)` 启动引擎与数据面。
4. 扩展以 `com.arcadiaplus.VPN_STATUS` 广播 `started/failed/stopped`；
   插件据此应答 Dart 的启动/停止请求，并让 `isVpnRunning` 反映真实状态。
5. 运行中切换分流模式：插件广播 `VPN_COMMAND {command:'set-mode'}`，
   扩展直接调用引擎的 `set_proxy_mode`，无需重启隧道。

## 权限说明

| 权限 | 说明 |
|------|------|
| `ohos.permission.INTERNET` | 网络访问（已声明） |
| `ohos.permission.GET_NETWORK_INFO` / `SET_NETWORK_INFO` | 网络状态（已声明） |
| VPN 授权 | 系统对话框授予，随应用卸载重置；无需在 module.json5 声明 |

## 真机验证清单（发布前逐项执行）

1. 首次开启 VPN：出现系统授权弹窗，允许后状态栏出现钥匙图标。
2. 引擎日志出现 `HarmonyOS packet path started on fd`；
   应用内网络页 TUN 开关为开；退出应用后 VPN 图标消失（系统会随宿主进程回收扩展）。
3. `hdc shell` 内 `curl -x http://127.0.0.1:<mixed_port> https://www.gstatic.com/generate_204`
   返回 204（混合端口可直接验证代理链路）。
4. 规则模式：访问大陆站点直连、境外站点走代理（用应用内连接列表核对 outbound）。
5. 关闭 VPN：开关收起、图标消失、无残留隧道路由。

## 已知边界（有意为之，不做静默降级）

- **IPv6 已纳入隧道（双栈）**：`VpnConfig` 同时声明 v4（`198.18.0.1/16`）与 v6
  （`fd7a:115c:a1e0:1::1/64`）地址、两条默认路由（`0.0.0.0/0`、`::/0`）与两个 DNS
  地址（v4/v6 各一），`isIPv6Accepted = true`。引擎的 netstack（solidtcp）本来就解析
  v6 报文，本轮补齐了**构建**侧：新增 `build_ipv6_tcp` / `build_ipv6_udp`（含 v6
  伪头校验和、UDP 校验和禁止为 0 的规则）与地址族分发器，TCP SYN/SYN-ACK/数据段/FIN、
  UDP 回复、SOCKS5 UDP relay 回复全部按目的地址族发包；客户端拿到 AAAA（v4 fake-ip
  策略下仍被抑制）时按地址直连并走代理，不再泄漏出隧道。
  边界依旧明确：ICMPv6（含 ping6）与带扩展头（分片等）的 v6 报文不处理——计入
  引擎统计后丢弃，不伪造回复；IPv6 的 AAAA 在 fake-ip 模式下仍返回空，客户端因此
  优先走被代理的 v4，而缓存中的旧 AAAA、v6 字面量与 v6-only 目标会被按地址接入
  隧道，而不是泄漏到隧道之外。
- **分应用代理未暴露**：`trustedApplications / blockedApplications` 能力系统侧具备，
  但尚未在 UI 上提供入口，配置序列不做无据声明。
- **插件注册**：`ArcadiaPlusPlugin` 采用标准 `FlutterPlugin` 生命周期实现。
  使用 `flutter build har` 生成的注册器时走常规 GeneratedPluginRegistrant 路径；
  手工嵌入 Flutter 引擎时，需要在引擎创建处调用其 `onAttachedToEngine`
  （binding 提供 `getBinaryMessenger()`），否则 Dart 侧会收到
  `MissingPluginException` —— 这是唯一尚未由本仓库代码闭环的对接点。

## 常见问题

**Q：DevEco 提示不识别 `"type": "vpn"`？**
A：旧版工具链需在 SDK 的 `toolchains/modulecheck/module.json` 中为 extensionAbilities
添加 `vpn` 枚举，清缓存并重启 DevEco（官方已知问题）。

**Q：TUN 开启后应用自身断网？**
A：引擎出站 socket 未获豁免。检查日志中是否出现 `protectProcessNet applied`
或 `setProtectCallback` 相关行；两者都缺失时 `start_ohos_vpn` 会拒绝启动（拒绝优于自环）。

**Q：想看扩展进程的引擎日志？**
A：`<沙箱>/engine/engine.log`（应用的 `files` 目录下，`hdc file recv` 可取）。
