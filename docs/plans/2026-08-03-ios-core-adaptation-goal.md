# iOS Core 适配 Goal

- 状态：待实施；本文作为首轮 iOS 适配的范围基线
- 日期：2026-08-03
- 基线分支：`main`
- 基线提交：`9dccdead0f477d95abbcb19711a9a2908e1f80eb`
- 目标设备：支持 TrollStore 的 iPad 真机
- 构建环境：GitHub Actions macOS Runner；本地没有 macOS/Xcode

## 1. 背景

当前项目是面向 Android 的 Flutter Emby 客户端，核心业务已经包括登录、媒体库、搜索、详情、播放协商、`media_kit` 播放、播放进度回报、离线下载和离线播放。

仓库当前只有 Android 平台工程，`.metadata` 尚未登记 iOS 平台，`pubspec.yaml` 也只引入了 `media_kit_libs_android_video`。此外，画中画、前台下载服务、局域网发现和设备标识中存在 Android 专用行为。

本次不追求一次完成全部 iOS 能力，而是先交付一个可真实使用和持续验证的 **iOS Core** 版本。

## 2. 总目标

在不破坏现有 Android 功能的前提下，为项目加入受控的 iOS 平台支持，并通过 GitHub Actions 持续生成可供 TrollStore 真机安装验证的 IPA。

首轮完成后，iPad 应能够：

1. 安装并正常启动应用；
2. 手动输入 Emby 服务器地址并登录；
3. 浏览首页、媒体库、搜索、详情和人物作品；
4. 在线播放视频，完成暂停、拖动、续播、音轨和字幕选择；
5. 在应用前台完成离线下载，并可离线播放；
6. 重启应用后恢复登录会话；
7. 在诊断日志中提供足够的信息定位真机问题。

## 3. 成功标准

### 3.1 自动化构建门禁

以下项目必须全部通过：

- `dart format --output=none --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`
- 现有 Android Debug APK 构建继续成功；如当前流程包含分 ABI 构建，必须继续保留
- `flutter build ios --release --no-codesign` 成功
- GitHub Actions 生成包含 `Payload/Runner.app` 的 IPA Artifact
- IPA 内必须是设备版 `arm64` 应用，而不是模拟器产物
- 工作流不得依赖 Apple 开发者证书、私钥或手工上传的签名 Secret
- 工作流使用明确固定的 Flutter 版本，不使用长期漂移的 `stable` 作为唯一版本约束

### 3.2 TrollStore 真机验收

必须在真实 iPad 上完成并记录结果：

- IPA 可由 TrollStore 安装、覆盖升级和启动
- 冷启动无崩溃、白屏或无限加载
- Keychain 写入真实生效；登录后杀掉应用并重新启动仍可恢复会话
- 可通过局域网 HTTP 地址手动登录
- 可通过正常证书的 HTTPS 地址登录
- 首页、媒体库、搜索和详情页图片可加载
- DirectPlay、DirectStream 或 Transcode 至少有一条实际播放路径可用
- 播放器可以暂停、继续、拖动并正确回报进度
- 内嵌音轨、内嵌字幕和外挂字幕分别完成至少一次验证
- 亮度和音量手势不会导致崩溃；若插件在目标系统不支持，必须安全降级
- 应用前台下载、暂停、继续、删除和离线播放可用
- 切换前后台后，播放器、WebSocket 和下载状态不会进入不可恢复状态

只有自动化构建和真机验收同时通过，README 才能把 iOS 标记为“已支持”。

## 4. 首轮范围

### 4.1 加入 iOS 工程

- 从基线提交创建独立实现分支，建议命名：`agent/ios-core-adaptation`
- 使用与项目固定版本一致的 Flutter SDK 生成 iOS 平台工程
- 允许使用 `flutter create --platforms=ios .`，但必须逐项审查 diff
- 不得接受模板对 Android、Dart 业务代码、包名或已有配置的无关覆盖
- 将 iOS Deployment Target 统一设置为 `13.0` 或插件要求的更高版本；若提高，必须在提交说明中给出原因
- iOS Bundle Identifier 使用稳定的非 `com.example` 标识；默认采用 `com.jsdfhasuh.embyclient`
- 保留应用现有中文名称和深色主题，不在本里程碑重做视觉设计

### 4.2 播放器原生依赖

将 Android 专用依赖：

```yaml
media_kit_libs_android_video
```

替换为官方跨平台视频依赖：

```yaml
media_kit_libs_video
```

要求：

- 不同时保留 `media_kit_libs_android_video` 和 `media_kit_libs_video`
- Android 播放行为不得退化
- 继续复用现有 `PlaybackEngine`、`PlaybackController` 和 Emby 播放协商，不在首轮引入第二套 AVPlayer 播放架构
- iOS 真机重点验证 HTTP Header 鉴权、音轨、字幕、外部字幕、倍速、音频延迟和字幕延迟
- 原生 mpv 属性在 iOS 不支持时必须安全失败，不得导致整个播放会话退出

### 4.3 平台能力边界

新增一个轻量、可测试的平台能力层，至少表达：

- 当前平台是否支持 Android 前台下载执行器
- 当前平台是否启用局域网 UDP 自动发现
- 当前平台是否支持现有画中画实现
- 新设备 ID 使用的平台名称

避免让 UI 到处新增零散的 `Platform.isAndroid` / `Platform.isIOS` 判断。底层确实只属于单个平台的代码仍可保留平台判断。

### 4.4 Android 前台下载隔离

当前 Android 前台下载服务必须继续工作，但 iOS 不得初始化或调用 Android 服务流程。

要求：

- `ForegroundDownloadExecutor.initializePlatform()` 只在 Android 执行
- `ForegroundDownloadExecutor` 只在 Android 注入 `DownloadService`
- iOS 使用现有应用内下载执行流程，定义为“前台下载”
- iOS 进入后台后允许系统挂起下载；回到前台后必须能够刷新状态并继续
- 不得伪装成已经支持可靠的 iOS 后台持续下载

### 4.5 画中画安全降级

现有 `emby_my_client/picture_in_picture` MethodChannel 只有 Android 原生实现。首轮不实现 iOS 画中画，但必须消除缺失插件导致的异常。

要求：

- iOS 上 `isSupported` 稳定返回 `false`
- `updatePlaying` 在原生通道不存在时必须安全 no-op
- 不得产生未处理的 `MissingPluginException`
- iOS UI 隐藏或禁用画中画入口
- Android 现有画中画行为和控制按钮保持不变

### 4.6 局域网访问与服务器发现

首轮必须支持手动输入局域网服务器地址，但暂不要求 iOS UDP 自动发现。

要求：

- 在 `Info.plist` 提供清晰的 `NSLocalNetworkUsageDescription`
- 在 ATS 配置中声明允许本地网络访问，优先采用 `NSAllowsLocalNetworking`
- 不添加全局 TLS 证书校验绕过
- 不支持无效证书或自签名 HTTPS 属于可接受限制，用户应使用 HTTP 局域网地址或正常证书的 HTTPS
- Android 保持现有 UDP 自动发现
- iOS 首轮关闭自动广播扫描，登录页继续允许手动输入地址
- iOS 自动发现作为后续独立里程碑，不在本轮申请或依赖 multicast entitlement

### 4.7 会话、Keychain 与设备标识

- 为 `flutter_secure_storage` 配置 iOS Debug/Profile/Release 所需的 Keychain entitlement
- 真机验证写入、读取、退出登录清理和覆盖安装后的行为
- 已存在的 Android 设备 ID 必须保持不变
- 新生成设备 ID 不再硬编码 `emby-android-`；根据平台生成 `emby-android-` 或 `emby-ios-`，或使用经过说明的平台中立前缀
- 不进行已有 Android 用户设备 ID 迁移

### 4.8 数据库、缓存和离线文件

继续使用现有：

- `sqflite`
- `getApplicationSupportDirectory()`
- 应用沙盒内的离线目录

要求：

- iOS 不引入 `sqflite_common_ffi` 作为运行时依赖
- 数据库迁移和 WAL 配置必须在 iOS 真机验证
- 离线媒体路径不得依赖 Android 外部存储路径
- 下载完整性、临时文件恢复和账号数据清理继续通过现有测试

### 4.9 iPad 基础适配

首轮只做阻塞性修正，不重构全部 UI：

- 登录、首页、媒体库、搜索、详情和设置在 iPad 竖屏及横屏不溢出
- 播放器进入横屏和退出后方向恢复正常
- 安全区域、Home Indicator、状态栏和底部弹层不得遮挡关键操作
- 现有底部 `NavigationBar` 可以继续使用
- `NavigationRail`、双栏详情页和完整宽屏布局后置

### 4.10 GitHub Actions iOS 工作流

新增独立工作流，例如 `.github/workflows/ios-core.yml`。

触发条件至少包括：

- `workflow_dispatch`
- 修改 iOS、播放、存储、网络、依赖或工作流相关文件的 Pull Request
- 实现分支按需 push

工作流必须：

1. checkout 仓库；
2. 安装固定 Flutter 版本；
3. 输出 `flutter --version` 和 Xcode 版本；
4. 执行依赖解析、格式检查、静态分析和测试；
5. 无签名构建设备版 Release `Runner.app`；
6. 检查 Bundle ID、最低系统版本和 `arm64` 架构；
7. 按标准 `Payload/Runner.app` 结构打包 IPA；
8. 保留应用需要的最小 entitlement；
9. 生成 SHA-256 校验文件；
10. 上传 IPA、校验文件和必要的构建诊断信息。

TrollStore 打包方案必须以真机安装结果为准。若纯 `--no-codesign` 产物无法保留 Keychain 等 entitlement，可在工作流中增加明确、可复现的 ad-hoc/fakesign 步骤，但不得引入私有证书。

## 5. 明确不在首轮范围内

以下内容不得为了“顺便完成”而扩大本次改动：

- App Store、TestFlight、正式证书和发布流程
- 可靠的 iOS 后台持续下载
- iOS 原生画中画
- iOS 局域网 UDP 自动发现和 multicast entitlement
- AirPlay、投屏、Live TV、SyncPlay 或新功能开发
- iPhone 专项 UI 优化
- iPad `NavigationRail`、双栏和桌面级布局重构
- macOS、Windows、Linux 或 Web 平台适配
- 播放器整体替换
- 无效证书、自签名 HTTPS 的全局信任绕过
- 与 iOS 适配无关的 Android 重构

## 6. 实施阶段

### 阶段 A：平台骨架与编译闭环

- 建立实现分支
- 生成并审查 `ios/`
- 固定 Bundle ID 和 iOS 13 最低版本
- 配置 Keychain、本地网络和 ATS
- 切换到跨平台 `media_kit_libs_video`
- GitHub Actions 能无签名生成 `Runner.app`

完成条件：iOS Release 构建通过，Android 门禁保持通过。

### 阶段 B：平台专用行为隔离

- 引入轻量平台能力层
- 隔离 Android 前台下载初始化
- 修正设备 ID 前缀
- iOS 禁用自动发现
- 画中画通道安全降级
- 增加相应单元和 Widget 测试

完成条件：iOS 冷启动不触发 Android 专用调用或未处理的 MethodChannel 异常。

### 阶段 C：TrollStore Artifact

- 标准化 IPA 打包
- 校验架构和 Info.plist
- 保留必要 entitlement
- 上传 Artifact 和 SHA-256
- 记录安装步骤及已知限制

完成条件：iPad 可安装、启动并覆盖升级。

### 阶段 D：核心在线功能验收

- 登录与会话恢复
- 首页、媒体库、搜索和详情
- 图片与 WebSocket
- DirectPlay / DirectStream / Transcode
- 音轨、字幕、拖动、续播和播放进度
- 生命周期切换

完成条件：至少一部电影和一集电视剧完整完成核心播放流程。

### 阶段 E：离线与回归

- 前台下载、暂停、恢复和删除
- 离线播放和进度同步
- 存储空间和文件完整性
- iPad 横竖屏和安全区域
- Android 全量回归

完成条件：自动测试、Android APK 和 iPad 验收清单全部通过。

## 7. 测试要求

至少补充以下自动测试：

- 已保存设备 ID 不因平台适配而改变
- 新设备 ID 使用正确的平台前缀
- iOS 能力配置不会创建 Android 前台下载执行器
- iOS 登录页不会自动启动 UDP 广播发现
- 画中画原生通道缺失时 `isSupported` 和 `updatePlaying` 安全降级
- Android 能力配置仍启用前台下载和服务器发现
- 平台分支不影响现有下载、离线播放和播放器控制测试

真机验收结果应写入独立文档或 PR 描述，至少记录：

- iPad 型号与 iPadOS 版本
- TrollStore 版本
- IPA 对应提交 SHA
- Emby Server 版本
- 测试媒体的容器、视频编码、音频编码和字幕类型
- 每项通过、失败或未测状态
- 失败时的诊断日志摘要

## 8. 提交与审查规则

建议按可独立审查的提交拆分：

1. `build: add audited iOS runner`
2. `build: use cross-platform media kit video libs`
3. `refactor: isolate mobile platform capabilities`
4. `fix: make unsupported iOS platform features safe`
5. `ci: build TrollStore iOS artifact`
6. `test: cover iOS platform boundaries`
7. `docs: record iOS device acceptance`

约束：

- 每个提交都必须保持 `flutter analyze` 和 `flutter test` 通过
- 不得把大量生成文件和业务修复混在同一个提交中
- 不得删除或弱化 Android 测试来使 iOS 构建通过
- 遇到插件不兼容时先记录根因，再做最小替换；禁止无说明地更换整套架构
- README 只有在真机核心验收完成后才能修改项目定位

## 9. 风险与处理原则

### 播放器能编译但真机黑屏或崩溃

先确认原生库、设备架构、渲染和 HTTP Header，再检查具体编码。允许通过 Emby Transcode 路径完成 Core 验收，但必须记录 DirectPlay 的失败媒体特征。首轮不同时引入第二播放器。

### IPA 可安装但 Keychain 不持久

检查 Runner entitlement、打包后的签名 entitlement 和 Bundle ID 是否一致。会话恢复是 Core 的硬性验收项，不得通过改用明文 SharedPreferences 绕过。

### HTTP 局域网地址无法访问

检查本地网络权限和 ATS 配置。不得关闭 TLS 校验或全局信任任意证书作为修复。

### iOS 后台中断下载

这是首轮已知限制。恢复前台后应刷新并继续；可靠后台下载另立 Goal。

### 平台判断难以自动测试

通过注入轻量平台能力对象解决，不使用依赖真实宿主平台的脆弱测试。

## 10. 最终交付物

- 受审查的 `ios/` 平台工程
- 跨平台播放器原生依赖配置
- iOS 平台边界和安全降级实现
- GitHub Actions iOS 构建及 IPA Artifact
- 新增平台相关自动测试
- TrollStore iPad 真机验收记录
- Android 回归结果
- 经过真机验收后更新的 README

## 11. 完成定义

只有同时满足以下条件，本 Goal 才能关闭：

- 所有自动化门禁通过
- Android 现有核心功能无回归
- GitHub Actions 可重复生成同类 iOS Artifact
- TrollStore iPad 可安装、启动和覆盖升级
- 手动登录、浏览、在线播放、会话恢复、前台下载和离线播放完成真机验收
- 所有未实现能力在 UI 或文档中明确降级，不出现伪支持
- 验收结果和已知限制已经入库

## 12. 参考资料

- Flutter iOS 构建与发布：<https://docs.flutter.dev/deployment/ios>
- Flutter iOS 开发环境：<https://docs.flutter.dev/platform-integration/ios/setup>
- media_kit 官方安装说明：<https://github.com/media-kit/media-kit#installation>
- Apple 本地网络权限：<https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription>
- Apple ATS 本地网络例外：<https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking>
- flutter_secure_storage：<https://pub.dev/packages/flutter_secure_storage>
- TrollStore：<https://github.com/opa334/TrollStore>
