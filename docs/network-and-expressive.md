# DNS、系统代理与 Expressive 适配

## 构建使用哪份内核

ArcadiaPlus 使用 crates.io 发布的 Corduit 0.3.2、RecurseX 0.2.5 和 Courierust 1.1.2。具体版本和包校验和由 `rust/Cargo.lock` 固定。构建不再依赖相邻源码仓库，也没有 vendor 或源码同步步骤。

桥接层与 Corduit 必须共享同一份 RecurseX；RecurseX 与 Corduit 必须共享同一份 Courierust，保证 DNS 的出站套接字工厂只有一个实例。之前混合本地路径和注册表依赖的方式会引入两份同版本的 RecurseX，版本号相同并不代表包身份相同。

```powershell
python scripts/check_engine_dependencies.py --offline
cargo check --manifest-path rust/Cargo.toml --locked --all-targets --all-features
```

检查脚本需要 Python 3.11 或更高版本，校验清单、锁文件中的来源与校验和，再检查 Cargo 实际解析出的包身份及依赖边。重复包、路径或 Git 替换、不同的 Courierust 实例以及 JNI 类型分裂都会失败。CI 和发布流水线直接使用锁定的注册表包，不再克隆上游仓库或追踪 main 分支。

Corduit 0.3.2 将 Android JNI 升级到 0.22.4。应用的三个原生入口同步改用 `EnvUnowned`，由内核取得 JNI 环境并管理 JavaVM、VpnService 引用和 protect 回调，避免两套 JNI 类型或生命周期状态。应用侧保留原有导出符号和停止服务顺序，Kotlin 的调用接口不变。

## DNS 与路由

RecurseX 的 UDP、TCP、DoT、DoQ，以及 Courierust 的 HTTP/HTTP3 出站连接，统一经过 Corduit 的套接字入口。Windows 在安装捕获路由前固定物理出口；Android 通过 VPN 的 socket protection 排除内核自身流量。保护失败会返回错误，不能继续建立一个可能再次进入 TUN 的连接。

Windows 的 IPv4 接口索引使用网络字节序，IPv6 使用主机字节序。TUN 出口改变会递增网络代次，下一次查询淘汰旧代次的加密 DNS 连接池，防止继续复用切换前的连接。

公共上游组最多启用两条查询通道，首个通过校验的回答返回；同一次查询共用截止时间。后台竞速线程全进程最多 32 个，达到上限后使用顺序查询。本机回环解析器保留优先级，不与公共上游抢答。失败响应仍重试，截断的 UDP 回答改用 TCP。

递归解析保留启动探测和缓存持久化；探测失败会显示配置警告，并继续使用已配置上游。递归模式需要网络能够访问权威 DNS 的 UDP/TCP 53，应用无法绕过运营商对这些端口的封锁。严格加密模式与根服务器迭代解析是不同策略：严格模式继续排除明文上游，不能把“递归”描述为端到端加密。

已有 Fake-IP、`nameserver-policy` 和 `fallback-filter` 继续负责地址映射、域名分组与污染结果过滤。并发查询不会自行把某个最快的答案判定为“国内”或“安全”；这些判断仍由配置策略负责。

普通 `DOMAIN` / `DOMAIN-SUFFIX` 规则增加索引，查询只合并对应域名、父级后缀与不可索引规则的候选位置。候选按原始位置排序，保持首条命中的规则语义。正则、进程和 IP 等剩余规则仍需要匹配，不能把域名索引测试等同于所有规则的端到端耗时。

Windows 增加 IPv6 半默认捕获路由，Android VPN 增加 IPv6 地址与默认路由。Windows 创建的路由按所有权回滚；必要的地址或 DNS 配置失败会让启动失败。Wintun 每个环的容量从 64 MiB 改为 4 MiB，TUN 输入队列限制为 1024 包。满队列丢弃新包，不阻塞停机；这一容量调整不等于已测得同等幅度的 RSS 降幅。

## Windows 系统代理

代理设置通过 WinINET 的连接级 API 更新，包含代理标志、端点、绕过列表与 PAC URL。启用前原子保存恢复快照；关闭时恢复原有 PAC/WPAD 配置。每次写入都通知 WinINET 并回读校验。失败的恢复保留快照，便于重试；原生更新与回滚同时失败时，错误分别报告两次调用的错误码。

此路径只配置当前用户的 WinINET LAN 代理。WinHTTP 服务代理、浏览器自己的代理策略以及应用主动绕过系统代理的行为，需要由各自配置或 TUN 接管。

## 界面与动效

桌面和 Android 的主操作、模式选择使用 `material_ui` 的 `material3Expressive` 组件变体。鸿蒙 Flutter 3.41 使用独立的应用适配包，通过 SDK Material 3 按钮实现选择状态和按压形状过渡；两套实现遵循同一交互接口并运行相同测试。状态图形共用 `material_new_shapes` 的 square / cookie9Sided 形状插值，切换时从当前值和速度继续弹簧运动。图形通过 clipper 重绘，空闲时没有循环动画；系统减少动画设置和 `TickerMode` 都会停止该运动。

主题菜单移除双层填充，状态文字移除叠加的出入场副本，按钮不再额外包一层按压缩放。卡片统一圆角，移动导航增加安全区，窄屏与大字体下状态和模式控制自动纵向排列。

这些改动使用 Flutter 的帧调度、绘制与合成机制，没有另造或宣称实现系统级“极光引擎”。现有插件仍使用 SDK Material 类型，所以 Expressive 主题桥接局限在组件边界，避免全局混用两套 ThemeData。

## 验证与验收边界

自动检查覆盖 Flutter 布局、触控和对比度，Windows 代理快照与恢复，并发 DNS 的首答及总超时，出站套接字工厂接入，以及十万域名规则的候选筛选。调试构建同时检查 Windows 原生通道和 Android Kotlin/Rust 集成。

2026-11-11，Corduit 0.3.2 发布包升级验证：

| 检查 | 结果 |
| --- | --- |
| Cargo 来源、校验和与共享依赖检查 | 通过；包含 Android JNI 依赖身份 |
| 依赖校验脚本回归 | 11 通过 |
| Rust 全特性、全部目标测试 | 22 通过，含 17 项单元测试与 5 项集成测试 |
| Rust 格式检查、Clippy `-D warnings` | 通过 |
| Rust 1.88 全特性、全部目标检查 | Windows 主机通过 |
| Android ARM64 交叉编译 | 通过，JNI 0.22 入口类型一致 |
| Windows Debug 构建 | 通过 |
| Android Debug APK | 构建成功；三个 VPN JNI 导出符号正确，包内 ARM64 库的 20 个运行时 ELF 区段与新编译内核一致 |

本轮未重跑未修改的 Flutter 界面测试，也未将构建成功等同于 VPN 真机连通性验证。DNS 隐私集成测试使用本机 TLS 对端，并需要可读取系统证书库的测试环境。

2026-11-11 上一轮界面与网络修复的验证记录（不代表本次依赖升级的验证）：

| 检查 | 结果 |
| --- | --- |
| Flutter analyze | 无问题 |
| Flutter test | 269 通过；1 项官方规则快照测试因未提供 `RULESET_FIXTURE_DIR` 跳过 |
| Corduit 全特性库测试 | 964 通过 |
| DNS / HTTP socket factory 集成测试 | 1 通过 |
| RecurseX forward 测试 | 10 通过 |
| ArcadiaPlus Rust 桥接层测试 | 17 通过 |
| Corduit 无默认特性检查 | 通过 |
| Windows Debug / Android Debug APK | 均构建成功 |

布局截图检查涵盖 320、430、800、1200 宽度及明暗主题，其中 320 宽度使用双倍字体。构建和测试记录位于本机 `.build/`，该目录不进入源码版本管理。

发布前仍需在真实网络上验证以下场景；单元测试和 APK 编译不能替代它们：

- Windows 管理员权限下反复开启、关闭 TUN，确认 IPv4/IPv6 路由恢复，系统代理页面与实际 HTTP 请求一致。
- 加密 DNS 与本机递归切换后，冷缓存、热缓存、UDP 被拦截和网络切换时均能得到明确成功或失败结果。
- Android 真机上的 VPN 生命周期、IPv6、息屏恢复和 Wi-Fi/蜂窝切换。
- 在相同节点、规则、网络和 Release 构建下测量应用首开时间、DNS 延迟、吞吐与 RSS，再与其他内核比较。本次没有跨产品实机性能结论。

参考：[Flutter Expressive 组件迁移](https://flutter.googlesource.com/mirrors/flutter/+/refs/heads/master/docs/ecosystem/material_ui/Material-3-Expressive-component-migration-checklist.md)、[WinINET 连接设置](https://learn.microsoft.com/en-us/windows/win32/wininet/setting-and-retrieving-internet-options)、[IPv6 socket options](https://learn.microsoft.com/en-us/windows/win32/winsock/ipproto-ipv6-socket-options)。
