# 分流与 Android 验证记录

## 已修正

- 逻辑规则中的 `no-resolve` 单独传给内核，不再混入 CIDR 或规则集名称。
- 嵌套 `NOT` 必须只有一个条件；空条件不再被悄悄删除。
- 未声明 DNS 模式时使用 Fake-IP。订阅声明的 `normal`、`redir-host` 和用户已经保存的模式不被覆盖。
- Android 通知请求标准 Live Updates 提升，使用独立单色图标；启动期间与连接成功后的文字分开显示。
- Flutter 启动画面与关于页面使用系统亮暗模式选择 Logo。Android 使用日夜矢量资源和自适应图标；桌面启动器是否立即刷新由系统决定。其他平台重新生成静态亮色图标。

## 视频为什么可能直连

HLS 的播放列表与分片可以使用不同域名，规则需要覆盖实际分片目标。`corduit 0.3.8` 的真实 DNS 域名恢复只接受尚未过期、没有歧义的 IP 映射。多个 CDN 域名共用一个地址时，内核不会猜测域名；域名规则可能因此不命中，随后按 IP 规则或 MATCH 处理。

Fake-IP 为经过内置 DNS 的请求保留域名，避免上述歧义。它不能恢复应用自行使用 DoH、已有真实 IP 缓存或直接连接 IP 时隐藏的域名，也不能替代 TLS/QUIC 嗅探。当前修改没有实现这些嗅探能力。切换模式后应重连 VPN，并重新启动下载任务。

代理组命中也不等于最终代理：组内成员仍可能是 DIRECT。排查时同时记录域名、命中规则、规则目标和最终组成员。

## 1.1.0+5 规则兼容性

运行时配置转换不再忽略未知参数、缺失匹配值或多余的 MATCH 字段。`IP-CIDR` / `IP-CIDR6` 的 `src` 参数会转换为源 IP 匹配；当前无法保留语义的组合（例如 `GEOIP,...,src`）会阻止配置启动，并给出错误。此行为依据 [Mihomo 规则参数说明](https://wiki.metacubex.one/config/rules/)，不将源地址规则降级成目标地址规则。

Corduit 0.3.8 的 classical 规则集读取器不保留条目级附加参数。因此规则源中的 `IP-CIDR,192.0.2.0/24,no-resolve` 等条目现在会被拒绝；将 `no-resolve` 放在引用该规则集的 `RULE-SET,集合名,出口,no-resolve` 上。源地址匹配使用 `SRC-IP-CIDR,192.0.2.0/24`。如果一个集合内需要不同的解析行为，应拆成独立集合再按原顺序引用。

升级时，旧 classical 缓存不能绕过新校验，需要重新读取本地源或下载远端规则。域名/IP 集合缓存不受此次迁移影响。通过新校验的完整缓存仍可在刷新失败时使用；失败的新数据不会覆盖它。这里的测试证明转换与匹配行为，不证明某个实际 CDN 下载已走远端代理。

### Compatibility notes

Runtime conversion rejects unsupported modifiers and malformed fields. The `src` modifier on `IP-CIDR` / `IP-CIDR6` becomes a source-IP rule; unsupported source-GEOIP semantics are rejected. Classical providers must contain type/payload pairs only: use explicit `SRC-IP-CIDR` entries and apply `no-resolve` to the referencing `RULE-SET`. Previously cached classical sets must be refreshed under the new validation. A newly validated complete cache remains usable when a later refresh fails.

## HLS 验证流程

运行 ArcadiaPlus 后，将其 HTTP 或 mixed 监听地址传给：

```powershell
python scripts/verify_hls.py --proxy http://127.0.0.1:7890
```

脚本读取 Mux 的公开测试播放列表、一个变体及首个媒体分片，并输出长度与 SHA-256。它验证本地代理入口的下载能力；最终出口必须结合应用连接诊断确认。不能把 MetaClash 的成功下载记作 ArcadiaPlus 的测试结果。

此前设备检查发现已连接手机的活动 VPN 属于 `com.github.metacubex.clash.meta`。尚未完成新版 ArcadiaPlus 的手机端 HLS 下载与通知胶囊验收。

## 流体云边界

采用 [Android Live Updates](https://developer.android.com/develop/ui/views/notifications/live-update) 的权限及公开 `android.requestPromotedOngoing` extra，与 compileSdk 36 保持兼容。不使用未经证实的厂商私有字段，不伪装导航、通话或下载进度。系统、通知设置与 OEM 资格判定决定是否提升通知；尚未证明 ColorOS 17 会将 VPN 常驻通知展示为流体云胶囊。

## 自动检查

1.1.0+5 本次修复先用新增回归复现了 12 项失败，再完成实现修改。全量 Flutter 回归为 412 项通过、1 项因需要外部快照而跳过；随后下载六份 Loyalsoldier 官方规则快照，单独运行该项测试通过，没有丢弃规则条目。下载来源与 SHA-256 保存在本地 `.dart_tool/ruleset-fixtures/sources.json`。

完整 Dart 静态分析和格式检查通过；Python 构建／发布检查共 30 项通过；实际 Corduit 路由器的域名优先级与源 IP 匹配两项集成测试通过。Android Debug APK 构建完成，9 个 64 位原生库通过 16 KB 对齐检查。这些结果不等于真机端到端代理验证，也不代表远端 GitHub 发布任务已成功。

发布前可在仓库根目录执行 `python scripts/check_release_notes.py`。它与发布工作流使用同一份版本章节提取逻辑。修复应提交并推送到发布使用的代码分支；重新运行旧的失败任务不会自动切换到修复后的提交。如果发布标签已经指向其他提交，现有保护会明确拒绝覆盖。
