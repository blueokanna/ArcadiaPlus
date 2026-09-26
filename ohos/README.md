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
│   ├── build-profile.json5                             # externalNativeOptions → CMake 链接引擎静态库
│   ├── libs/arm64-v8a/                                 # build-rust-ohos.sh 落位的 UI 进程 .so（不提交）
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/EntryAbility.ets           # FlutterAbility 子类：创建引擎并注册插件
│       │   ├── pages/Index.ets                         # FlutterPage 宿主页
│       │   ├── plugins/ArcadiaPlusPlugin.ets           # UI 进程：通道 + 状态镜像
│       │   └── vpnextension/ArcadiaPlusVpnAbility.ets  # 扩展进程：隧道 + 引擎宿主
│       ├── cpp/
│       │   ├── napi_init.cpp                           # Rust 入口的 NAPI 包装（含 protect 回调 TSFN）
│       │   ├── CMakeLists.txt
│       │   └── types/libarcadia_core/                  # ArkTS 侧类型声明
│       └── module.json5                                # extensionAbilities(type: vpn) + 权限
├── hvigor/hvigor-config.json5                          # hvigor 模型版本（5.1.0）
├── hvigorfile.ts                                       # flutter-hvigor-plugin：接管 Flutter 产物注入
├── scripts/build-rust-ohos.sh                          # Rust 引擎交叉编译与产物落位
└── har/                                                # flutter build hap 产出的 HAR（不提交）
```

## 构建步骤

### 0. 前置

- DevEco Studio 5.0.5+（或与 CI 相同的 command-line-tools），HarmonyOS SDK API 17+；
- 可构建 HAP 的 Flutter 只有 CPF-Flutter 维护的 `flutter_flutter` 分支
  （上游 Flutter 没有 ohos 工具链）：`flutter build hap` 必须由该 SDK 执行，
  版本见 `.github/actions/checkout-flutter-ohos/action.yml` 的 `version` 默认值；
- Rust 1.97（rustup，仓库 `rust-toolchain.toml` 已固定）：
  `rustup target add aarch64-unknown-linux-ohos`（脚本也会自行确保）；
- 设置 `OHOS_NDK` 指向 SDK 的 `native` 目录（如 `…/sdk/default/openharmony/native`），
  或让脚本自行探测常见安装路径。

### 1. 构建 Rust 引擎（两个产物）

```bash
bash ohos/scripts/build-rust-ohos.sh
```

Windows（无 bash 环境）用产物路径完全一致的 PowerShell 版；DevEco Studio 的 NDK
会被自动探测（也可 `-Ndk <…\sdk\default\openharmony\native>` 或设 `OHOS_NDK`），
路径含空格时会自动用目录联接（junction，`%LOCALAPPDATA%\ohos-ndk-native`）
映射出无空格路径再喂给 clang/cc：

```powershell
powershell -ExecutionPolicy Bypass -File ohos/scripts/build-rust-ohos.ps1
```

- `ohos/entry/src/main/cpp/thirdparty/arm64-v8a/librust_lib_arcadiaplus.a`
  —— 静态链接进 `libarcadia_core.so`（扩展进程的引擎）。
- `ohos/entry/libs/arm64-v8a/librust_lib_arcadiaplus.so`
  —— UI 进程的 Flutter 插件库（FRB）。`entry/libs` 是模块的本地库目录，
  hvigor 会把其中的所有 `.so` 与 `libapp.so` 一起打进 HAP；
  flutter_rust_bridge 在 `Platform.operatingSystem == 'ohos'` 时按
  `lib$stem.so` 裸名加载，不需要额外配置路径。

脚本在编译前会删除旧产物并以 cargo 退出码判定成败，避免「文件存在即成功」的假绿；
同时给 `dart-sys` 这类带 C shim 的依赖导出 NDK 的 CC/AR/CFLAGS 交叉编译环境。

### 2. 构建 HAP

```bash
flutter build hap --release --no-codesign   # 未签名（CI 默认，产物 entry-default-unsigned.hap）
flutter build hap --release                 # 已配置 signingConfigs 时输出签名 HAP
```

工程采用 **flutter-hvigor-plugin 模式**：根 `hvigorfile.ts` 注册
`flutterHvigorPlugin`，由它在 hvigor 构建阶段注入 `flutter.har`、`libapp.so`、
`flutter_assets` 与模块依赖，不再需要手工 `flutter build har` 或维护
`overrides`/`flutter_module` 模块。调试与真机安装依旧可以用 DevEco Studio 打开
`ohos/` 目录完成。

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
- **插件注册**：`ArcadiaPlusPlugin` 采用标准 `FlutterPlugin` 生命周期实现，
  由 `EntryAbility.configureFlutterEngine` 在引擎创建后注册
  （`flutterEngine.getPlugins()?.add(...)`）。UI 进程侧不存在需要手工接线的
  对接点；若后续引入带 ohos 平台的 pub 插件，生成器会走常规
  GeneratedPluginRegistrant 路径。
- **CI 上的 Dart 版本差**：`flutter_flutter` 落后上游（3.41.9），其 Dart 早于
  `pubspec.yaml` 里 3.47.x 线的约束。CI 在作业内把 `environment.sdk/flutter`
  放宽到检出 SDK 实际报告的版本，改动只存在于 runner 工作区并打印 `git diff`，
  不提交；`pubspec.lock` 同理不参与 OHOS 作业的 `--enforce-lockfile`。

## CI（GitHub Actions）

`.github/workflows/ci.yml` 的 `ohos` 作业与 `release.yml` 的 `ohos` 作业共用三个
复合 action：

| action | 职责 |
|--------|------|
| `.github/actions/setup-ohos` | 下载/校验 command-line-tools 与 OpenHarmony SDK（SHA-256 双重校验），解包成 DevEco 布局，导出 `DEVECO_SDK_HOME` / `OHOS_NDK` / `OHOS_SDK_COMPATIBLE_VERSION` |
| `.github/actions/checkout-flutter-ohos` | 检出固定 tag 的 `flutter_flutter`（唯一能执行 `flutter build hap` 的 SDK） |
| `.github/actions/prepare-ohos-build` | 把 `compatibleSdkVersion` 绑定到实际供应的 SDK、放宽 pubspec 约束到 fork 的 Dart 线、`flutter pub get` |

随后依次是 `ohos/scripts/build-rust-ohos.sh` 与 `flutter build hap --release [--no-codesign]`，
收尾用 `unzip -l` 断言 HAP 内确实含有
`libs/arm64-v8a/{libapp.so,librust_lib_arcadiaplus.so,libarcadia_core.so}`，
避免出现「构建绿但包是空壳」。发布作业在配置了 `ARCADIAPLUS_OHOS_*` secrets 时输出**签名** HAP
（`app.p12` / `app.cer` / `app.p7b` + 口令），未配置时输出 `-unsigned.hap` 并给出告警：
未签名 HAP 无法安装到真机，这是可预期的中间态。

两个作业都把两个下载缓存到 `$RUNNER_TEMP/ohos-downloads`；缓存键包含版本与 SDK
校验和，命中即免下载（命中后仍会再次校验 SHA-256）。

### 签名材料（`ARCADIAPLUS_OHOS_*` secrets）

发布作业需要三件套与三枚凭据，全部来自 DevEco 的签名配置，以 base64 形式存进仓库 Secrets：

| Secret | 内容 |
|--------|------|
| `ARCADIAPLUS_OHOS_KEYSTORE_BASE64` | `.p12` 密钥库 |
| `ARCADIAPLUS_OHOS_KEYSTORE_PASSWORD` / `ARCADIAPLUS_OHOS_KEY_ALIAS` / `ARCADIAPLUS_OHOS_KEY_PASSWORD` | 密钥库口令 / 别名 / 密钥口令 |
| `ARCADIAPLUS_OHOS_CERT_BASE64` / `ARCADIAPLUS_OHOS_PROFILE_BASE64` | `.cer` 证书 / `.p7b` Profile |
| `ARCADIAPLUS_OHOS_SIGN_ALG`（可选） | 仅手动创建的 RSA 密钥需要，填 `SHA256withRSA`；缺省按 `SHA256withECDSA` 处理 |

生成一次即可（自动签名链；不需要本地能构建 HAP）：

1. DevEco Studio（与本仓库 CI 同代，5.1.x）登录**已实名认证**的华为开发者账号，打开本仓库的 `ohos/` 目录；
2. `File → Project Structure → Signing Configs` 勾选自动生成签名并等待完成——它会在 AGC 侧为
   `com.blueokanna.arcadiaplus` 登记调试证书与 Profile，并把 `material` 写进工程的
   `build-profile.json5`：`storeFile`/`certpath`/`profile` 三个路径与
   `storePassword`/`keyAlias`/`keyPassword` 三个凭据（材料文件位于 `%USERPROFILE%\.ohos\config\`）；
3. 一键导出——脚本读取 `build-profile.json5` 中 DevEco 写入的三个路径与三枚凭据，把
   `.p12`/`.cer`/`.p7b` 转成 `%TEMP%\ohos-signing-secrets\<Secret 名>.txt`
   （ASCII、无 BOM、无换行），并用 DevEco 自带 keytool 验证密钥库可打开、配置的别名
   存在，同时给出 `signAlg`（即 `ARCADIAPLUS_OHOS_SIGN_ALG` 应填的值）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File ohos/scripts/export-signing-secrets.ps1
   ```

4. 打开 GitHub 仓库 → **Settings → Secrets and variables → Actions → New repository
   secret**，逐个新增：三个 `.txt` 的全文（文件名去掉 `.txt` 即 Secret 名，见上表）、
   脚本打印的三枚明文凭据、以及按需的 `SIGN_ALG`（缺省 `SHA256withECDSA`，只有
   手动创建的 RSA 密钥才需要填）；
5. `git restore ohos/build-profile.json5` **还原**该文件——它此刻含明文口令与本机绝对路径，
   绝不能提交；CI 也依赖其中 `"signingConfigs": []` 作为注入占位。

自动签名产出的是**调试**证书与 Profile：可侧载装机，不能上架 AppGallery。上架需要在 AGC
申请发布证书与发布 Profile（同一 bundle name），用 DevEco「生成密钥与 CSR」换取 `.cer`
并下载配对的 `.p7b`，然后换成发布三件套与口令即可——工作流只负责把材料注入签名配置，
不区分签名类型；密钥算法不是 ECDSA 时用 `ARCADIAPLUS_OHOS_SIGN_ALG` 声明。

调试 Profile 是一份**设备白名单**：清单内的设备都能安装（设备可以多选，上限以「设备管理」
页面显示的额度为准），清单外的装不了。要把 CI 产物装到更多设备：把设备 UDID 注册进
「设备管理」→ 编辑该 Profile 勾上新设备 → 重新下载 `.p7b` → 更新 GitHub 的
`ARCADIAPLUS_OHOS_PROFILE_BASE64`（代码与工作流不用动）。要让**不限设备的任何人**安装，
唯一官方途径是**应用市场分发**——HarmonyOS 从系统层面关闭了任意侧载（设备只信任华为
签发、经市场或白名单授权的安装；把 HAP 文件直接发给别人会被系统拦截），这不是本工程的
构建或签名方式能改变的；调试白名单是唯一"侧载"形态，但只覆盖登记过的设备。上架流程：
在 AGC 用同一 bundle name 创建应用，申请**发布证书 + 发布 Profile**
（发布 Profile 没有设备列表），把三个 `*_BASE64` secrets 换成发布三件套（工作流不用改，
它只负责注入材料、不区分证书类型），上架物料是 App Pack（DevEco `Build → Build App(s)`
产出），通过审核后用户即可在应用市场安装；还没有准备好公开上架时，可以先走 AGC 内测/
邀请测试渠道（测试用户同样经应用市场安装）。网络代理类应用的上架审核通常更严格，能否
过审以华为审核结果为准。

未签名 HAP 有两个现成来源（不必在本地准备 Flutter-OHOS 工具链）：**CI**——每次 push 后，
Actions 的 `ohos` 作业会把 `ArcadiaPlus-ci-ohos-arm64-unsigned.hap` 作为产物上传；
**Release**——未配置 `ARCADIAPLUS_OHOS_*` secrets 时，发布会直接附带
`ArcadiaPlus-<tag>-ohos-arm64-unsigned.hap`。未签名的 HAP 任何设备都装不了，先用签名材料
（DevEco **自动签名**即可产出，见上文）和 SDK 的 `hap-sign-tool.jar` 在本地签一次：

```powershell
java -jar "<DevEco SDK>\default\openharmony\toolchains\lib\hap-sign-tool.jar" sign-app `
  -mode localSign -signAlg SHA256withECDSA `
  -keystoreFile app.p12 -keystorePwd <storePassword> -keyAlias <keyAlias> -keyPwd <keyPassword> `
  -appCertFile app.cer -profileFile app.p7b `
  -inFile ArcadiaPlus-ci-ohos-arm64-unsigned.hap -outFile ArcadiaPlus-signed.hap
```

`hap-sign-tool.jar` 在 DevEco SDK 的 `toolchains/lib` 下（找不到时就在 toolchains 目录里
搜这个文件名）；`java` 用 DevEco 自带的 JBR（`<DevEco 安装目录>\jbr\bin\java.exe`）。
试签通过说明材料与口令自洽，随后 `hdc install ArcadiaPlus-signed.hap` 即可装机
（调试 Profile 只接受其登记过的设备——自动签名时连接设备即自动登记）。

## 常见问题

**Q：DevEco 提示不识别 `"type": "vpn"`？**
A：旧版工具链需在 SDK 的 `toolchains/modulecheck/module.json` 中为 extensionAbilities
添加 `vpn` 枚举，清缓存并重启 DevEco（官方已知问题）。

**Q：TUN 开启后应用自身断网？**
A：引擎出站 socket 未获豁免。检查日志中是否出现 `protectProcessNet applied`
或 `setProtectCallback` 相关行；两者都缺失时 `start_ohos_vpn` 会拒绝启动（拒绝优于自环）。

**Q：想看扩展进程的引擎日志？**
A：`<沙箱>/engine/engine.log`（应用的 `files` 目录下，`hdc file recv` 可取）。

**Q：DevEco 打开工程报 `Cannot find module 'flutter-hvigor-plugin'`？**
A：该 npm 包由 Flutter-OHOS 工具链准备（`flutter build hap` 会先写
`ohos/package.json` 再 `npm install`，把 fork SDK 里的
`packages/flutter_tools/hvigor` 装进 `node_modules/`）。没跑过工具链的检出里
没有它，`hvigorfile.ts` 因此改成「插件在则加载、不在则跳过」：CI 构建时插件必然
就位，本机 DevEco 不开工具链也能正常 sync（做签名配置、浏览代码）。若要在本机
跑完整 HAP 构建，先按「构建步骤」备好 fork SDK 并执行一次 `flutter build hap`，
插件才会就位。

**Q：DevEco 报 `The Rust engine for arm64-v8a has not been built`？**
A：这是 `CMakeLists.txt` 的守卫，不是环境问题：先运行
`powershell -ExecutionPolicy Bypass -File ohos/scripts/build-rust-ohos.ps1`
（Windows）或 bash 版脚本把两份产物就位，再回 DevEco 构建。系统 PATH 里的
clang（LLVM/Swift）与本工程无关——DevEco 的 CMake 一直用 SDK 自带的 clang。
