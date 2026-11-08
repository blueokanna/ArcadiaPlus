# Material 3 界面、状态管理与核心加固

验证日期：2026-11-08。

当前依赖为 courierust 1.1.1、nextjson 0.1.5、rustbinary 0.1.10、recurse-x 0.2.3。Corduit 与 Flutter 桥接锁文件使用同一组版本。

## 界面与动效

主页保留 Material 3 的分段选择器、按钮、卡片和开关；宽屏双列、窄屏单列，内容宽度受约束。运行状态和流量卡片没有持续的装饰动画。

节点页使用原生 ChoiceChip 和 FilledButton。节点名正常排版，窄屏及大字号切换为自适应高度列表；宽屏网格不缩小文字。选中状态使用主题容器色、描边与图标，不改变卡片尺寸。键盘、焦点、触控目标与语义由 Material 控件承担。

共享按压反馈使用 SpringSimulation，从当前位置和速度继续运动。松手、取消或快速反向按压不重置动画；减少动画设置在按压期间发生变化时也能正确收敛。流量更新只通知相关节点或统计区域，避免重建整个节点页。

连接列表的入场等待上限为 160 ms，不再按全局行号无限延后；减少动画时立即显示，销毁时取消计时器。删除未引用的旧 IP 检测卡片及自绘按钮、开关、循环装饰动画，保留实际使用的 Material 3 控件与共享动效。

## 状态与资源管理

节点操作通过 ProxyEngine 边界调用核心。手动切换与启动恢复共用 ProxySelectionService：先读取核心当前选择，再执行切换并回读；失败时恢复实际读取到的旧节点，并再次核验。恢复失败则显示核心最后确认的节点；始终无法读取时，清除勾选与旧偏好并报告错误。配置变化和对象销毁后，旧任务不得回写页面或发起回滚。销毁时移除核心监听器。

启动同步只保存一次选择快照、刷新一次出口 IP；未改变的偏好不重复写入。存储失败单独报告，不掩盖已经生效的核心切换，也不会产生未处理的异步异常。

批量测速和单节点测速共用四个并发名额。批量任务只启动固定数量的工作协程；同一测量中的重复请求合并。测速走已配置的出站和组内测试 URL，不再用普通 TCP 连接成功掩盖协议测试失败。各出站的具体探测能力仍由核心实现决定。

出口 IP 请求按节点切换和端口变化失效，旧客户端立即关闭，过期响应无法更新地址或缓存。节点变更序号在主页未挂载时仍然保留，返回主页后不会沿用旧出口缓存。IP 请求客户端可注入，生命周期测试不依赖公网服务。

## Corduit 修复

- RustBinary 0.1.9 已被撤回，当前两份锁文件均解析到 [0.1.10](https://crates.io/crates/rustbinary/0.1.10)。Corduit 和 recurse-x 共用一个版本；保留 NextJson 0.1.5 与现有自描述二进制格式。
- C ABI 不再把 JSON 或二进制解码错误降为无参数请求。非法 UTF-8、截断、尾随数据、超深嵌套、非零长度的空指针均在分发前拒绝。二进制长度在构造切片前检查，输入上限 64 MiB；错误响应仍按既有契约返回 UTF-8 文本。外部传入的非法非空指针仍属于调用方违反 C ABI 安全契约，Rust 无法验证其指向的内存。

- DIRECT 和 SOCKS5 共享有界 HTTP 探测。HTTPS 先进行证书校验的 TLS 握手；查询参数与完整 Host 保留。连接、SOCKS5 协商、TLS 和响应读取使用同一截止时间，首行上限 8 KiB；103 等临时响应受数量和累计大小限制。
- SOCKS5 拒绝超长或空域名、错误的认证版本、非零保留字节及空绑定域名。显式配置用户名和密码时，只提供认证方式，不静默降级为无认证。
- CONNECT 请求头达到 64 KiB 上限后立即拒绝，避免继续占用连接直到超时。
- 关闭定界的 HTTP 正文改用 Courierust 的 read_direct。正常关闭保留最后一段数据；超时返回错误，不把不完整订阅或规则数据视为成功。
- NextJson 0.1.5 不再实现标准库 HashMap 的编解码。适配集中在配置边界：DNS 映射通过独立适配器处理，入站和出站使用解码视图与借用编码视图。运行时哈希表和公共字段类型保留，编码不复制整个选项值。协议选项不得覆盖 type、tag、server、listen、port 等保留字段。

协议边界参考 [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.html)、[RFC 1929](https://www.rfc-editor.org/rfc/rfc1929.html) 和 [HTTPS 语义](https://www.rfc-editor.org/rfc/rfc9110.html#section-4.2.2)。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| Flutter analyze | 无问题 |
| Flutter 测试 | 188 项通过 |
| Corduit 全特性单元测试 | 944 项通过 |
| Corduit 集成 / 文档测试 | 2 / 3 项通过 |
| Flutter Rust 桥接测试 | 17 项单元测试、2 项 DNS 缓存集成测试通过 |
| Clippy 全特性、全部目标，警告视为错误 | 通过 |
| Linux x86_64 核心交叉编译检查 | 通过 |
| 核心 no_std 检查 | 通过 |
| Windows debug 构建 | 通过 |
| Android arm64 profile 构建及 lint | 通过；0 error、4 warning |

新增测试覆盖连续切换、失败回滚、并发名额、配置失效、对象销毁、过期 IP 响应、HTTP 截断和滴送响应、SOCKS5 畸形帧，以及新版编解码的默认字段、扁平选项和往返转换。

界面测试覆盖 320、430、800、1200 宽度、亮暗主题和双倍字号，并检查触控目标、可访问名称及文字对比度。渲染图位于 `.dart_tool/ui-previews/`；这些是隔离状态下的真实组件渲染，不是设备联网或帧率证据。

本轮日志使用 `.dart_tool/rustbinary-*.log`，包含 FFI、缓存兼容、Flutter、桥接、核心及平台构建结果。此前的界面专项日志仍保留。核心测试使用 `--test-threads=2`，避免并行构建干扰时间敏感用例。

## 产物与验证边界

- Windows：`build/windows/x64/runner/Debug/arcadiaplus.exe`。运行时保留相邻 DLL 和 data 目录。
- Android：`build/app/outputs/apk/profile/app-profile.apk`，用于真机性能采样，不是正式发布签名包。
- APK 已通过 ZIP 完整性与 v2 签名检查；包内 arm64 原生库与 stripped_native_libs 中的构建输出逐字节一致。
- APK SHA-256：`9f2a89b4a33a9606b5ed4154aa15550fc84d33807bbbdf2eda19288655b79d23`。

ADB 当前没有连接设备，尚未测得 OnePlus 15 的 PSS、UI/raster 帧时间或长时间运行结果。Windows 管理员 TUN、断网恢复、DNS/IPv6 泄漏及其他平台真机验收范围仍见 [平台验证记录](validation-2026-11.md)。Apple VPN 扩展尚未补齐。构建、单元测试和组件截图不等同于这些运行验收，也不能证明不存在其他缺陷。

连接已授权 Android 设备后，可用 `scripts/android-profile.ps1` 采集内存与系统帧统计；Flutter 帧时间需结合 DevTools。包体积不能用于推断运行内存。
