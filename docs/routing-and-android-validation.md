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

## HLS 验证

运行 ArcadiaPlus 后，将其 HTTP 或 mixed 监听地址传给：

```powershell
python scripts/verify_hls.py --proxy http://127.0.0.1:7890
```

脚本读取 Mux 的公开测试播放列表、一个变体及首个媒体分片，并输出长度与 SHA-256。它验证本地代理入口的下载能力；最终出口必须结合应用连接诊断确认。不能把 MetaClash 的成功下载记作 ArcadiaPlus 的测试结果。

此次检查发现已连接手机的活动 VPN 属于 `com.github.metacubex.clash.meta`。尚未完成新版 ArcadiaPlus 的手机端 HLS 下载与通知胶囊验收。

## 流体云边界

采用 [Android Live Updates](https://developer.android.com/develop/ui/views/notifications/live-update) 的权限及公开 `android.requestPromotedOngoing` extra，与 compileSdk 36 保持兼容。不使用未经证实的厂商私有字段，不伪装导航、通话或下载进度。系统、通知设置与 OEM 资格判定决定是否提升通知；尚未证明 ColorOS 17 会将 VPN 常驻通知展示为流体云胶囊。

## 自动检查

规则转换、DNS 设置、分流隐私、全局模式和规则源共 112 项 Flutter 测试通过；修改文件的 Dart 静态检查通过。Android Kotlin 与资源编译通过。以上结果不等于完整 APK 构建、设备安装或端到端代理验证。
