# 代理生命周期、DNS 与平台验证记录

验证日期：2026-11-08。用户设备为 OnePlus 15 / ColorOS 16.0.5.503，报告内存占用约 278 MB。本机没有已连接的 ADB 设备，因此没有真机内存改善或帧率数据。

## 已落地的修复

- Windows：TUN 保持流量捕获，规则、全局、直连由核心路由器选择；切换模式不再重建路由。启停和模式修改串行执行，失败保留实际状态，避免界面显示成功而系统未生效。
- Flutter：启动、停止、重启、模式切换与规则刷新按顺序执行；配置转换与规则文本解析移至 isolate。停止时同步清理隧道和 DNS，关闭页面后不再继续通知监听器。
- DNS：应用构建使用本地 Corduit 与 recurse-x 0.2.3。递归服务的 hot/warm/cold/NX 缓存容量分别限制为 512/4096/1024/1024；UDP 使用 1 个接收线程、4 个处理线程、64 项队列，TCP 并发连接上限为 16。核心停止后释放全局解析器，状态采集只读取当前进程内存。
- DNS 回退：可疑主答案必须由可接受的备用答案替换，备用解析失败不能继续使用可疑结果或绕回系统 DNS。修正 GeoIP 条件方向；强制回退域名直接查询备用服务器；显式 hosts 和 nameserver-policy 优先，保留私有地址用途。地址过滤不等于完整抗污染证明，也不替代 DNSSEC 验证。
- 规则更新：支持到期刷新及手动强制刷新；HTTPS 重定向逐跳检查；超时覆盖响应体；源地址变化会失效旧校验标记，下载失败保留上次有效规则。应用恢复前台时补做过期检查；尚未实现操作系统后台定时更新任务。
- Android：页面交由 Material 路由处理返回手势，按钮按压采用保留速度的弹簧动画并响应减少动画设置。快捷设置磁贴可请求连接、停止服务并跟踪实际 VPN 状态；Android 13 起可在设置页请求添加磁贴。VPN 原生停止在工作线程执行，先停原生数据通道再关闭文件描述符；仅关闭 TUN 不会误停普通代理核心。
- HarmonyOS：VPN 扩展拥有实际代理实例，界面进程避免重复监听；模式切换等待扩展确认。配置更新通过停止并重启扩展生效，因此会中断已有连接；尚未实现扩展进程内的无中断热重载。
- Linux：当前 TUN 仅接受 global；禁止切到 rule/direct，避免未经标记的直连回流。macOS 系统代理实现保留，macOS Network Extension 与 iOS Packet Tunnel Extension 尚未完成。

## 依赖与构建

应用的 `rust/Cargo.toml` 引用同级目录 `../../Corduit`，确保核心修复进入构建；检出项目时必须同时提供该目录。

Corduit 使用 courierust 1.1.1，补齐新增 TLS profile 字段。rustbinary 0.1.8 与 recurse-x 持久化依赖要求 `nextjson/std`，nextjson 0.1.5 已移除该 feature，因此固定为 `=0.1.4`。这是依赖兼容修复，不是协议创新。

TLS 指纹声明中不支持的 ECH、ALPS 扩展不会生成伪造空扩展；padding 仅在对应 profile 声明时发送。未实现的能力不作为支持项宣传。

GeoIP 与域名回退行为参照 [Mihomo DNS 配置语义](https://wiki.metacubex.one/en/config/dns/)，用于订阅格式兼容，不作为自主创新声明。

## 验证范围

| 检查 | 结果 |
| --- | --- |
| Flutter analyze | 无问题 |
| Flutter test | 133 项通过 |
| Corduit 全特性单元测试 | 924 项通过 |
| Corduit 集成测试 / 文档测试 | 2 / 3 项通过 |
| Rust 桥接测试 | 17 项通过 |
| Corduit Clippy（所有目标，警告视为错误） | 通过 |
| Linux x86_64 Rust 核心交叉检查 | 通过 |
| Windows debug 构建 | 通过 |
| Android arm64 profile 构建 | 通过 |
| Android debug 构建及 lint | 通过；lint 有 4 条 warning、无 error |

核心测试使用 `--test-threads=2`，避免多个编译任务同时运行时干扰原有的短时延断言。新增 DNS 用例使用本地 UDP 服务器；集成用例通过真实回环 SOCKS5 连接收发数据，覆盖模式切换和停止后清理。

Android lint 剩余提示为：旧 API 忽略返回手势属性、协程库有新版本、Android 12 数据迁移规则未单独配置，以及冗余 drawable-v21 目录。应用已有 `allowBackup=false`，但不同厂商的设备迁移行为尚未验证。

本轮执行 Flutter 分析与测试、Rust 核心及桥接测试、真实回环 TCP/SOCKS5 数据传输测试，以及 Windows debug、Android debug 构建。Android lint 已运行；它仍有兼容性提示及依赖版本提示。完整命令输出保存在本地 `.dart_tool/*-build.log`、`.dart_tool/*-tests.log` 等日志中。

Android 构建使用 JDK 17；系统默认 Java 25 与项目 Gradle 8.14 不兼容。没有修改机器默认 JDK。Linux Rust 核心交叉检查通过；这不等于 Linux 桌面或 TUN 真机验收。

尚待验证：Windows 管理员 TUN 路由、断网恢复、IPv6/DNS 泄漏；OnePlus 真机连续切换、待机恢复、PSS 内存和 Flutter 帧时间；Linux root 网络命名空间；HarmonyOS VPN 扩展权限、进程生命周期及路由行为。Apple 平台仍需补齐 VPN 扩展并在对应 SDK 和设备上验证。

`scripts/android-profile.ps1` 可在连接一台已授权设备后采集 PSS 和系统帧统计。请使用 release/profile 包，在固定配置、相同网络和操作序列下比较；Flutter 动画还需结合 DevTools 的 UI/raster 帧时间。debug 包的内存和动画表现不能作为发布性能结论。

本机存在 Android API 37 模拟器镜像，但未安装模拟器虚拟化驱动；没有把软件模拟结果作为 OnePlus 的性能结论。

## 后续界面修订

本文件保留首轮核心与平台检查结果。后续已按要求迁移到 nextjson 0.1.5／rustbinary 0.1.10；其中的旧依赖兼容结论仅属于首轮记录。当前构建产物、界面修改及新增测试见 [Material 3 修订记录](ui-motion-2026-11.md)。构建产物会被后续构建覆盖，应使用该记录中的当前校验值。
