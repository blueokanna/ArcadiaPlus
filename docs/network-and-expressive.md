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

### Android 平板与节点状态

Android 启动时不再指定竖屏方向，Activity 允许调整窗口大小。布局跟随窗口的逻辑宽度，而不是设备型号或面板像素：窄窗口使用底栏，平板和横屏使用侧栏；短横屏侧栏可滚动。系统自动旋转开关仍由用户控制。MatePad 上运行的 Android APK 使用 Android VPN 路径，不应按 OpenHarmony HAP 的扩展进程路径排查。

侧栏与底栏共用一份目的地列表，标签、选中项和路由不再分别维护索引。Android 手机和平板都将日志放在“设置 → 查看日志”，避免出现看似是日志、实际跳转到设置的入口。

`NativeCoreService.isReady` 只表示原生库和 FFI 已加载。`ConfiguredProxyEngine` 负责另一层状态：配置已装载、节点选择已恢复，并且配置身份与当前代理页一致。未就绪时只保存预选，不调用内核选择接口，也不生成失败测速记录。配置替换、停止和完整的选择回滚共用串行队列，避免旧选择事务写入新配置。自动测速、故障转移、负载均衡和链式组不接受手动 selector 写入。

代理页在宽窗口显示策略组面板，窄窗口保留横向策略组切换；节点搜索只过滤视图，不改变配置或已选节点。列数偏好会持久化，但实际列数受可用宽度和文字缩放限制。首页在可容纳两列时并排显示连接控制和流量信息。

前一轮平板修复验证（2026-11-11）：Flutter 静态分析无问题，全量测试 286 项通过；1 项外部规则快照测试因未指定 `RULESET_FIXTURE_DIR` 跳过。新增回归覆盖原生库就绪但配置未加载、安装失败后重试、配置身份隔离、选择回滚与重载互斥，以及 Android 横竖屏导航。布局渲染覆盖浅色、深色与两倍文字缩放。未连接 MatePad 真机，以上结果不代表该设备的 VPN 连通性或系统旋转行为已经实测。

旋转时保留搜索输入的补充修复通过 29 项相关界面回归。最终 ARM64 release APK 已用 JDK 17 构建，APK v2 签名校验通过，包内仅包含 `arm64-v8a` 原生库及对应 Rust 内核。本地产物使用 Android Debug 证书，供安装验证；正式分发仍使用发布流水线配置的签名。该电脑自动发现的 JDK 25 与 Gradle 8.14 不兼容，本次构建通过进程级 `JAVA_HOME` 选择已安装的 JDK 17，没有修改全局 Flutter 配置。

桌面和 Android 的主操作、模式选择使用 `material_ui` 的 `material3Expressive` 组件变体。鸿蒙 Flutter 3.41 使用独立的应用适配包，通过 SDK Material 3 按钮实现选择状态和按压形状过渡；两套实现遵循同一交互接口并运行相同测试。状态图形共用 `material_new_shapes` 的 square / cookie9Sided 形状插值，切换时从当前值和速度继续弹簧运动。图形通过 clipper 重绘，空闲时没有循环动画；系统减少动画设置和 `TickerMode` 都会停止该运动。

主题菜单移除双层填充，状态文字移除叠加的出入场副本，按钮不再额外包一层按压缩放。卡片统一圆角，移动导航增加安全区，窄屏与大字体下状态和模式控制自动纵向排列。

这些改动使用 Flutter 的帧调度、绘制与合成机制，没有另造或宣称实现系统级“极光引擎”。现有插件仍使用 SDK Material 类型，所以 Expressive 主题桥接局限在组件边界，避免全局混用两套 ThemeData。

## 验证与验收边界

### 1.0.9+2 界面细化

主导航按窗口宽度选择形态：小于 600 dp 使用悬浮胶囊底栏，600–999 dp 使用紧凑侧栏，1000 dp 起展开为带文字的桌面侧栏。导航目的地共用路由定义，选中背景使用可中断的弹簧运动；快速连续点击会沿当前速度转向。动画只重绘指示器，静止后不保留帧回调。减少动画设置会直接定位选中项，侧栏在短横屏窗口中可以滚动。底栏的安全区由外层统一预留，避免各页面的列表和悬浮按钮被挡住。

首页采用分层的浅色、深色表面，连接状态、模式按钮和流量指标遵循同一套圆角与间距。流量指标随宽度和文字大小换行；迷你曲线仅绘制已有采样，未运行时不生成装饰性流量。配置页在空间充足时并排展示订阅，大字体回到单列；零配额显示未知上限，不计算无效百分比。导入面板允许滚动，短横屏窗口仍能访问全部选项。

界面字体使用 Google Sans Flex，中文回退到 Noto Sans SC，地址和配置代码使用 Google Sans Code。三套字体直接随包分发，启动时不请求字体服务。原始文件来自 [Google Fonts 官方仓库](https://github.com/google/fonts)，固定到提交 `5bb28733cec313b63fbd415b574b5ae35c8aa8b8`；下载地址和 SHA-256 保存在 `assets/fonts/sources.json`。OFL 授权随应用注册到许可列表，字体文件没有修改或重命名。

页面渲染检查使用真实字体，覆盖手机、平板、桌面和浅深色主题。导航回归检查快速切换、方向键、两倍文字、减少动画与底栏安全区；配置页检查长名称、零配额、超额用量和短横屏导入。测试截图的状态由隔离的测试数据提供，不代表真机网络和性能测量。MatePad Pro 12.6 的帧耗时、旋转与 VPN 连通性仍需连接实际设备验收。

本轮最终验证：静态分析无问题，Flutter 测试 300 项通过，1 项外部规则快照测试跳过。Windows Debug 和 Android ARM64 release 均构建成功；Android 版本码为 `100090002`，APK v2 签名校验通过，本地包使用 Android Debug 证书。检查确认 APK 只包含 ARM64 原生库，三套字体与仓库原文件逐字节一致，Windows 字体清单也包含相同字体族。正式分发应由发布流水线使用正式证书签名。

### 1.0.9+3 出口信息、内存与查询观测

首页只保留一个 64 dp 的花瓣形启停按钮。停止、切换中和运行使用同一图形连续变形；出口地址、运营商及分类成为首卡的信息主体。移动底栏继续使用悬浮胶囊，横屏和桌面使用侧栏。

`ExitIpController` 在 Flutter 中通过 HTTPS 获取 [IPQuery](https://github.com/ipqwery/ipqwery) 的出口情报，失败时回退到 IP.SB 的地址与归属地。启用代理时两个请求都使用配置的本地代理端口，不因失败切回直连。切换节点、端口或代理状态会取消旧请求；后台与隐藏页面停止请求，过期响应不能覆盖新出口。报告只驻留内存，显示来源和检查时间。

“住宅候选”的依据是数据源明确返回非机房、非移动、非 VPN、非代理及非 Tor 标志；它不能证明住宅宽带身份。缺失标志不会被默认成 `false`。风险分数使用提供者原值，范围为 0–100；低分显示“风险较低”，不将其描述为安全保证或概率。评分口径见 [IPQuery 风险说明](https://ipquery.io/glossary/risk-score)。不在客户端嵌入付费 API 密钥，也不根据运营商名称猜测质量。

内存面板分别展示内核接口读取的进程 RSS 和 Flutter 图像缓存占用。清理只调用 `ImageCache.clear()`，保留活动图像监听和连接，不调用私有 GC 接口、不关闭 VPN，也不清除 DNS 缓存。清理结果是缓存实际移除的字节数，不等于系统立即收回的 RSS。当前接口没有 Dart 与 Rust 堆的独立计量，因此不生成参考图中那类分项百分比。

DNS 表格读取 Corduit 现有的 `DNS query received` TUN 事件，保留日志中的时间、域名和类型。最近 500 条日志中最多展示 80 个查询事件；首页最多显示 6 条，连接页提供完整入口。该计数表示保留的观测事件，不能当作会话累计查询数。没有查询事件时显示空状态，不从连接目标、测速请求或测试数据构造记录。日志时间按内核 UTC 时钟转换到本地时间。

这里仍有明确的接口限制：Corduit 0.3.2 / RecurseX 0.2.5 未公开带请求标识的完整查询事件流，无法可靠关联并发查询的结果、逐条缓存命中及耗时。表格保留未知值，本地递归累计计数使用真实 `getRecursiveDnsStatus`，不冒充全部转发 DNS 的统计。要完整实现参考图的这些列，需要上游增加结构化观测接口后发布兼容版本；本轮没有替换已锁定的注册表依赖或修改其缓存源码。

路由入场与空状态使用有截止时间的变形、位移和淡入，遵循 Material 的 [形状原则](https://m3.material.io/styles/shape/overview-principles)。动画由 Flutter 的帧调度器执行，页面静止后没有循环动画；减少动画、隐藏路由和后台会停止运动。没有声称接入华为系统的“极光引擎”，也没有用动画代码的变化推算 GPU 负载或内存降幅。

本轮验证：静态分析无问题，315 项 Flutter 测试通过，1 项外部规则快照测试因缺少 `RULESET_FIXTURE_DIR` 跳过。Windows Debug、Android ARM64 release 均构建成功。IPQuery 使用公开地址 `8.8.8.8` 验证了实际响应字段，没有将主机出口检测当作 MatePad 的网络实测。界面测试使用隔离数据检查布局、可访问性和生命周期；内存清理测试验证缓存条目被移除、活动图像监听仍保留。尚未连接 MatePad 真机测量帧耗时、GPU 负载或清理前后的进程 RSS。

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
