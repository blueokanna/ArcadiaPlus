# Interface previews · 界面预览

这些图片由 `test/readme_showcase_test.dart` 使用当前 `HomeScreen`、`AdaptiveScaffold`、主题与本地字体直接渲染。状态来源为离线测试夹具：服务停止、没有活动配置、流量为零。未启动 Rust 引擎、连接代理、修改系统代理或读取用户订阅。

The images render the current `HomeScreen`, `AdaptiveScaffold`, themes and bundled fonts. An offline fixture supplies an idle service with no active profile and zero traffic. The test does not start the Rust engine, connect to a proxy, alter system settings or read user profiles.

## Scope / 范围

The target label identifies Flutter's `TargetPlatform` setting, not a native test host. All captures were produced by the Windows Flutter test runner. Host-dependent `dart:io` branches still run on Windows. These images verify layout and localization, not platform-specific behavior, window chrome, VPN support or performance.

平台名称表示 Flutter 的 `TargetPlatform` 设置，不代表原生运行环境。本批图片均由 Windows 上的 Flutter 测试运行器生成；依赖 `dart:io` 的判断仍然使用 Windows 宿主。图片只展示布局和本地化，不验证原生系统行为、窗口装饰、VPN 或性能。

HarmonyOS NEXT requires its own SDK and device capture. The Android tablet preview is not a substitute for that evidence. iOS previews do not imply that a Packet Tunnel Extension is implemented.

HarmonyOS NEXT 需要其专用 SDK 与设备采图，Android 平板预览不能代替这项验证。iOS 界面预览不表示 Packet Tunnel Extension 已实现。

## Gallery / 图集

| Target / 目标 | Viewport | 中文 · 亮色 / 暗色 | English · Light / Dark |
| --- | --- | --- | --- |
| Android | 412 × 915 | [亮色](android-zh-light.png) · [暗色](android-zh-dark.png) | [Light](android-en-light.png) · [Dark](android-en-dark.png) |
| iOS | 390 × 844 | [亮色](ios-zh-light.png) · [暗色](ios-zh-dark.png) | [Light](ios-en-light.png) · [Dark](ios-en-dark.png) |
| Windows | 1440 × 960 | [亮色](windows-zh-light.png) · [暗色](windows-zh-dark.png) | [Light](windows-en-light.png) · [Dark](windows-en-dark.png) |
| macOS | 1440 × 960 | [亮色](macos-zh-light.png) · [暗色](macos-zh-dark.png) | [Light](macos-en-light.png) · [Dark](macos-en-dark.png) |
| Linux | 1440 × 960 | [亮色](linux-zh-light.png) · [暗色](linux-zh-dark.png) | [Light](linux-en-light.png) · [Dark](linux-en-dark.png) |
| Tablet / 平板（Android target） | 1024 × 1366 | [亮色](tablet-zh-light.png) · [暗色](tablet-zh-dark.png) | [Light](tablet-en-light.png) · [Dark](tablet-en-dark.png) |

## Regenerate / 重新生成

Resolve the locked dependencies first. From the repository root on Windows:

先安装锁定依赖，再从仓库根目录执行：

```powershell
flutter pub get --enforce-lockfile
./scripts/generate_readme_images.ps1
```

Equivalent commands for individual locales / 单独生成某个语言版本：

```sh
flutter test --no-pub test/readme_showcase_test.dart --dart-define=CAPTURE_UI=true --dart-define=SHOWCASE_LOCALE=en
flutter test --no-pub test/readme_showcase_test.dart --dart-define=CAPTURE_UI=true --dart-define=SHOWCASE_LOCALE=zh
python scripts/update_readme_image_manifest.py
```

The test fails on widget exceptions and checks the responsive navigation breakpoint. Review the PNGs for font rendering, clipping and image quality before committing them. The capture flag is opt-in, so a normal `flutter test` does not rewrite documentation images. Update the preview date in both READMEs when refreshing the gallery.

测试会检查组件异常与响应式导航断点。提交前还需检查 PNG 的字体、裁切和图像质量。只有显式启用采图参数才会写入图片，普通 `flutter test` 不会重写文档资源。更新图集时，请同步修改两份 README 中的预览日期。

[manifest.json](manifest.json) records image dimensions, SHA-256 checksums, the base Git revision and a fingerprint of the rendering sources. The source fingerprint includes uncommitted changes; the base revision alone does not identify the rendered working tree.

[manifest.json](manifest.json) 记录图片尺寸、SHA-256、基础 Git 提交与渲染源码指纹。指纹包含未提交的源码修改；仅凭基础提交号不能还原本批图片的工作区状态。
