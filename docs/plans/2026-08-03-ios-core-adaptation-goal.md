# iOS Core 适配 Goal

- 状态：待实施；最终审查修订版 v3（实施前冻结）
- 日期：2026-08-03
- 实施基线：包含本 Goal 最新修订版本的 `main` HEAD
- 实际基线 SHA：在创建实现分支时记录到 PR 描述和验收文档，不在本文件中写死
- 建议实现分支：`agent/ios-core-adaptation`
- 首轮目标设备：支持 TrollStore 的 iPad 真机
- 首轮设备族：仅 iPad（`TARGETED_DEVICE_FAMILY = 2`）
- 构建环境：GitHub Actions；本地没有 macOS/Xcode

## 1. 背景

当前项目是面向 Android 的 Flutter Emby 客户端，核心业务已经包括登录、媒体库、搜索、详情、播放协商、`media_kit` 播放、播放进度回报、离线下载和离线播放。

仓库当前只有 Android 平台工程，`.metadata` 尚未登记 iOS 平台，`pubspec.yaml` 也只引入了 `media_kit_libs_android_video`。此外，画中画、前台下载服务、局域网发现和设备标识中存在 Android 专用行为。

本次不追求一次完成全部 iOS 能力，而是先交付一个可以真实安装、持续构建和进行真机验证的 **iPadOS Core** 版本。

## 2. 总目标

在不破坏现有 Android 功能的前提下，为项目加入受控的 iPadOS 平台支持，并通过 GitHub Actions 持续生成可供 TrollStore 真机安装验证的 IPA。

首轮完成后，目标 iPad 应能够：

1. 安装、覆盖升级并正常启动应用；
2. 手动输入 Emby 服务器地址并登录；
3. 浏览首页、媒体库、搜索、详情和人物作品；
4. 在线播放视频，完成暂停、拖动、续播、音轨和字幕选择；
5. 在应用前台完成离线下载，并可离线播放；
6. 重启应用后恢复登录会话；
7. 在诊断日志和构建 Artifact 中提供足够的信息定位真机问题。

## 3. 状态定义与责任边界

### 3.1 `IMPLEMENTATION_COMPLETE`

由实现者完成并声明，必须满足：

- 代码、自动测试、Android 回归和 iOS 构建全部通过；
- GitHub Actions 可生成 TrollStore 测试 IPA；
- 已提供真机验收清单、安装说明和诊断 Artifact；
- 尚未要求实现者声称真实 iPad 功能已经通过。

### 3.2 `ACCEPTED`

由设备所有者在目标 iPad 上完成验收后确认，必须满足：

- 使用合并后 `main` 工作流生成的 IPA 完成验收；
- IPA 可以安装、启动和覆盖升级；
- 登录、浏览、播放、会话恢复、前台下载和离线播放通过；
- 验收结果已经写入仓库；
- 失败项已经修复，或被明确记录为本 Goal 允许的限制。

只有进入 `ACCEPTED`，本 Goal 才能关闭。README 也只有在 `ACCEPTED` 后才能写入“实验性 iPadOS 支持”，不得提前泛化为“已支持 iOS”。

## 4. 固定工具链

首轮实现使用以下固定基线：

- Flutter revision：`67323de285b00232883f53b84095eb72be97d35c`
- Dart SDK：`3.10.8`
- Linux 门禁 Runner：`ubuntu-24.04`
- iOS 构建 Runner：`macos-15`
- Xcode：`16.4`
- CocoaPods：`1.16.2`
- ldid 实现：Homebrew Core `ldid`，不得使用 `ldid-procursus`
- ldid 版本：`2.1.5`

要求：

- 工作流不得仅使用会长期漂移的 `stable`、`macos-latest` 或未固定版本的 CocoaPods；
- CI 必须输出 Flutter、Dart、Xcode、macOS、Ruby、CocoaPods 和 ldid 的实际版本；
- CocoaPods 必须通过 `Gemfile` / `Gemfile.lock` 与 Bundler 固定；
- ldid 的安装来源必须固定到 Homebrew formula commit，或固定 bottle/source URL 及 SHA-256；仅执行未约束版本的 `brew install ldid` 不足以满足本 Goal；
- CI 必须拒绝不是 `2.1.5` 的 ldid，也不得根据 Runner 状态在 `ldid` 与 `ldid-procursus` 之间自动切换；
- Xcode 必须显式选择 16.4，并通过 `xcodebuild -version` 验证；
- 如果 GitHub Runner 不再提供指定工具链，必须先在同一 PR 中更新本 Goal、工作流和兼容性证据，不得静默升级；
- 生成 `ios/` 工程时必须使用上述 Flutter revision，避免模板漂移。

## 5. 成功标准

### 5.1 自动化门禁

以下项目必须全部通过：

- `dart format --output=none --set-exit-if-changed .`
- `flutter analyze`
- `flutter test`
- Dart/Flutter 依赖必须遵守已提交的 `pubspec.lock`
- CocoaPods 依赖必须遵守已提交的 `ios/Podfile.lock`
- 依赖安装后 `pubspec.lock` 与 `ios/Podfile.lock` 不得产生未提交变化
- 现有 Android Debug APK 构建继续成功；如当前流程包含分 ABI 构建，必须继续保留
- `flutter build ios --release --no-codesign` 成功
- GitHub Actions 生成标准 `Payload/Runner.app` 结构的 IPA
- IPA 内必须是设备版 `arm64` 应用，不得上传模拟器产物
- 工作流不得依赖 Apple 开发者证书、私钥、Provisioning Profile 或手工签名 Secret
- 最终 Artifact 必须包含 IPA、SHA-256、dSYM、版本信息、Info.plist 摘要、entitlement 源文件哈希、最终 entitlement dump 和架构检查结果

依赖锁定原则：

- 优先使用固定 Flutter 支持的 lockfile 强制模式，例如 `flutter pub get --enforce-lockfile`；若该版本不支持，则执行普通依赖解析后通过 `git diff --exit-code -- pubspec.lock` 强制验证；
- 提交 `ios/Podfile.lock`；
- CI 使用 `bundle exec pod install --deployment`；
- 普通 CI 禁止默认执行 `pod update` 或 `pod install --repo-update`；
- Pod 解析完成后执行 `git diff --exit-code -- ios/Podfile.lock`。

### 5.2 TrollStore 真机验收

必须在真实 iPad 上完成并记录结果：

- IPA 可由 TrollStore 安装、覆盖升级和启动
- 冷启动无崩溃、白屏或无限加载
- Keychain 写入真实生效；登录后杀掉应用并重新启动仍可恢复会话
- 覆盖升级后 Bundle ID、有效 Keychain 身份、数据库和离线记录保持连续
- 首次连接局域网服务器时，本地网络授权流程可理解且可恢复
- 拒绝本地网络权限时，应用不得无限加载；重新授权后可继续使用
- 可通过局域网 HTTP 地址手动登录
- 可通过正常证书的 HTTPS 地址登录
- 首页、媒体库、搜索和详情页图片可加载
- H.264 + AAC 的 MP4 至少完成 DirectPlay 或 DirectStream
- 通过降低最大码率等可控方式至少完成一次 Transcode 播放
- 播放器可以暂停、继续、拖动并正确回报进度
- 内嵌音轨、内嵌字幕和外挂字幕分别完成至少一次验证
- 亮度和音量手势不会导致崩溃；若插件在目标系统不支持，必须安全降级
- 应用前台下载、暂停、继续、删除和离线播放可用
- 切换前后台后，播放器、WebSocket 和下载状态不会进入不可恢复状态

DirectStream 可根据媒体和服务器条件标记为“不适用”，但不能只用 Transcode 成功来代替 DirectPlay/DirectStream 验收。

## 6. 首轮范围

### 6.1 建立受审查的 iOS 工程

- 从包含本 Goal 最新版本的 `main` HEAD 创建实现分支
- 在首个实现提交或 PR 描述中记录实际基线 SHA
- 使用固定 Flutter revision 运行 `flutter create --platforms=ios .`
- 逐项审查生成 diff，不得接受模板对 Android、Dart 业务代码、包名或已有配置的无关覆盖
- iOS Deployment Target 统一设置为 `13.0`；若插件要求提高，必须给出证据并更新验收设备要求
- Bundle Identifier 固定为 `com.jsdfhasuh.embyclient`
- 设备族首轮固定为 iPad-only：`TARGETED_DEVICE_FAMILY = 2`
- 保留应用现有中文名称和深色主题，不在本里程碑重做视觉设计

`.metadata` 处理规则：

- 必须正确登记 iOS migration platform；
- 使用固定 Flutter revision 在干净临时目录生成同类 iOS 项目，以新生成的 `.metadata` 作为参考；
- 不得无条件删除或保留当前 `ios/Runner.xcodeproj/project.pbxproj` unmanaged 标记；
- 若固定版本的新模板不包含该项，则移除；若新模板仍包含，则保留并记录其属于 Flutter 模板行为；
- 最终提交必须说明 `.metadata` 与固定 Flutter 模板之间的差异及原因。

### 6.2 iPad 全屏与方向策略

现有播放器依赖 `SystemChrome.setPreferredOrientations` 在进入播放时切换横屏。首轮为保证该契约可验证：

- iPadOS Core 设置 `UIRequiresFullScreen = true`；
- `UISupportedInterfaceOrientations~ipad` 应允许应用所需的竖屏和横屏方向；
- 首轮明确不支持 Split View、Slide Over、Stage Manager 可调整窗口或其他多任务窗口模式；
- 播放器进入横屏、退出后恢复应用方向必须完成真机验收；
- `UIRequiresFullScreen` 仅作为当前 TrollStore Core 的过渡策略，后续正式多任务适配另立 Goal。

### 6.3 播放器原生依赖

将 Android 专用依赖：

```yaml
media_kit_libs_android_video
```

替换为跨平台依赖，并在锁文件中固定解析结果：

```yaml
media_kit: ^1.2.6
media_kit_video: ^2.0.1
media_kit_libs_video: ^1.0.7
```

要求：

- 不同时保留 `media_kit_libs_android_video` 和 `media_kit_libs_video`
- Android 播放行为不得退化
- 继续复用现有 `PlaybackEngine`、`PlaybackController` 和 Emby 播放协商，不在首轮引入第二套 AVPlayer 播放架构
- iOS 真机重点验证 HTTP Header 鉴权、音轨、字幕、外部字幕、倍速、音频延迟和字幕延迟
- 原生 mpv 属性在 iOS 不支持时必须安全失败，不得导致整个播放会话退出
- 不允许为了通过 iOS 构建而删除现有 Android 播放能力

### 6.4 平台能力边界

新增一个轻量、可注入、可测试的平台能力层，至少表达：

- 当前平台是否支持 Android 前台下载执行器
- 当前平台是否启用局域网 UDP 自动发现
- 当前平台是否支持现有画中画实现
- 新设备 ID 使用的平台名称
- 当前平台的目标设备族和已知限制

避免让 UI 和业务层到处新增零散的 `Platform.isAndroid` / `Platform.isIOS` 判断。底层确实只属于单个平台的代码仍可保留最小平台判断。

### 6.5 Android 前台下载隔离

当前 Android 前台下载服务必须继续工作，但 iOS 不得初始化或调用 Android 服务流程。

要求：

- `ForegroundDownloadExecutor.initializePlatform()` 只在 Android 执行
- `ForegroundDownloadExecutor` 只在 Android 注入 `DownloadService`
- iOS 使用现有应用内下载执行流程，定义为“前台下载”
- 应用被系统挂起但进程仍保留时，回到前台后刷新状态并继续或允许继续
- 应用进程被终止后，未完成任务恢复为 `paused/processInterrupted` 或等价明确状态，由用户手动继续
- 不要求进程终止后自动继续下载
- 不得伪装成已经支持可靠的 iOS 后台持续下载

### 6.6 画中画安全降级

现有 `emby_my_client/picture_in_picture` MethodChannel 只有 Android 原生实现。首轮不实现 iOS 画中画，但必须消除缺失插件导致的异常。

要求：

- iOS 上 `isSupported` 稳定返回 `false`
- `updatePlaying` 在原生通道不存在时安全 no-op
- 不得产生未处理的 `MissingPluginException`
- iOS UI 隐藏或禁用画中画入口
- Android 现有画中画行为和控制按钮保持不变

### 6.7 局域网访问与服务器发现

首轮必须支持手动输入局域网服务器地址，但暂不要求 iOS UDP 自动发现。

要求：

- 在 `Info.plist` 提供清晰的 `NSLocalNetworkUsageDescription`
- 在 ATS 配置中声明允许本地网络访问，优先采用 `NSAllowsLocalNetworking`
- 不添加全局 TLS 证书校验绕过
- 不支持无效证书或自签名 HTTPS 属于可接受限制，用户应使用 HTTP 局域网地址或正常证书的 HTTPS
- Android 保持现有 UDP 自动发现
- iOS 首轮关闭自动广播扫描，登录页继续允许手动输入地址
- iOS 自动发现作为后续独立里程碑，不在本轮申请或依赖 multicast entitlement
- 本地网络权限被拒绝时必须显示可恢复错误，不得无限加载或反复弹出无意义请求

### 6.8 会话、Keychain 与设备标识

- 为 `flutter_secure_storage` 配置 Debug/Profile/Release 所需的 iOS Keychain entitlement
- 仓库中必须只有一个人工维护的 TrollStore entitlement 源，固定路径为 `scripts/ios/trollstore-entitlements.plist`
- 若构建变量必须展开，可由脚本从该源生成临时 resolved entitlement；生成文件不得成为第二个人工维护来源
- `ios/Runner/DebugProfile.entitlements`、`ios/Runner/Release.entitlements` 与 TrollStore fakesign entitlement 必须由同一源生成，或由 CI 自动比较关键项一致性
- 初始配置遵循 `flutter_secure_storage` 官方最小要求：必须存在 `keychain-access-groups`；没有经过验证的共享组需求时保持空数组，不编造 Team ID、AppIdentifierPrefix 或自定义共享组
- Bundle ID、最终应用标识和有效 Keychain 身份必须在所有构建之间保持稳定
- 不依赖不存在的 Provisioning Profile
- CI 必须比较：人工维护源、构建时 resolved entitlement、fakesign 后主二进制 entitlement，以及最终 IPA 解包后的主二进制 entitlement
- 关键 Keychain 项缺失、不一致或出现未批准 entitlement 时构建失败
- 真机验证写入、读取、退出登录清理、杀进程恢复和覆盖安装后的行为
- 已存在的 Android 设备 ID 必须保持不变
- 新生成设备 ID 不再对所有平台硬编码 `emby-android-`
- 新 Android ID 使用 `emby-android-`，新 iOS ID 使用 `emby-ios-`，或采用经过说明的平台中立前缀
- 不进行已有 Android 用户设备 ID 迁移
- Keychain 失败时不得回退到明文 SharedPreferences 保存访问令牌

### 6.9 数据库、缓存和离线文件

继续使用现有：

- `sqflite`
- `getApplicationSupportDirectory()`
- 应用沙盒内的离线目录

要求：

- iOS 不引入 `sqflite_common_ffi` 作为运行时依赖
- 数据库迁移、foreign key 和 WAL 配置必须在 iOS 真机验证
- 离线媒体路径不得依赖 Android 外部存储路径
- 下载完整性、临时文件恢复和账号数据清理继续通过现有测试
- 覆盖升级后数据库和离线记录必须保持可读

### 6.10 iPad 基础适配

首轮只做阻塞性修正，不重构全部 UI：

- 登录、首页、媒体库、搜索、详情和设置在 iPad 竖屏及横屏不溢出
- 播放器进入横屏和退出后方向恢复正常
- 安全区域、Home Indicator、状态栏和底部弹层不得遮挡关键操作
- 现有底部 `NavigationBar` 可以继续使用
- `NavigationRail`、双栏详情页和完整宽屏布局后置
- 首轮不声明 iPhone 支持，也不要求 iPhone 专项 UI 验收

## 7. TrollStore IPA 与签名方案

TrollStore 测试包必须采用明确、可复现的 fakesign 流程，不把普通 ad-hoc `codesign --sign -` 与 TrollStore `ldid` fakesign 视为等价。

固定方案：

- 只使用 Homebrew Core `ldid 2.1.5`
- 不使用 `ldid-procursus`
- 安装来源必须固定并校验 SHA-256
- CI 检测到不同实现或版本时立即失败

标准流程：

1. 执行 `flutter build ios --release --no-codesign`；
2. 从 `scripts/ios/trollstore-entitlements.plist` 生成或取得唯一批准的最终 entitlement；
3. 检查 entitlement 白名单，禁止未批准的高权限项；
4. 如存在嵌入式 Framework、App Extension 或其他 Mach-O，按由内到外顺序处理签名；
5. 使用固定的 `ldid 2.1.5` fakesign；
6. 使用 `ldid -e`、`codesign -d --entitlements :-` 或等价工具导出并检查最终 entitlement；
7. 解包最终 IPA 后再次检查主二进制和嵌入式 Mach-O；
8. 确认主应用保持稳定 Bundle ID、有效 Keychain 身份和应用沙盒；
9. 按 `Payload/Runner.app` 结构打包 IPA；
10. 生成 SHA-256 校验文件并上传 Artifact。

禁止加入与本项目无关的高权限 entitlement，包括但不限于：

- `platform-application`
- 解除应用沙盒的私有能力
- root helper 能力
- JIT entitlement
- 任意未说明的系统私有 entitlement

若 Keychain entitlement 无法在 TrollStore 产物中稳定工作，状态只能停留在 `IMPLEMENTATION_COMPLETE` 之前，不得通过降低安全性绕过。

## 8. GitHub Actions 工作流

新增独立工作流，例如 `.github/workflows/ios-core.yml`，并拆为两个主要 Job。

### 8.1 `quality-and-android`

- Runner：`ubuntu-24.04`
- 执行格式检查、静态分析、全量测试和 Android Debug APK 构建
- 保留现有分 ABI 构建要求
- 强制验证 `pubspec.lock` 未漂移

### 8.2 `ios-device-build`

- Runner：`macos-15`
- `needs: quality-and-android`
- 使用固定 Flutter revision、Xcode、CocoaPods 和 ldid
- 使用 `bundle exec pod install --deployment`
- 强制验证 `ios/Podfile.lock` 未漂移
- 无签名构建设备版 Release
- 执行 entitlement 一致性检查、`ldid` fakesign 和 IPA 打包
- 上传 IPA、dSYM、SHA-256、最终 Info.plist、entitlement 源及 dump、架构检查和工具版本信息

触发条件至少包括：

- `workflow_dispatch`
- `push` 到实现分支
- `push` 到 `main`
- Pull Request 中修改以下范围：
  - `lib/**`
  - `test/**`
  - `ios/**`
  - `scripts/ios/**`
  - `pubspec.yaml`
  - `pubspec.lock`
  - `Gemfile`
  - `Gemfile.lock`
  - `.github/workflows/ios-core.yml`
  - 与打包脚本相关的其他路径

要求：

- Pull Request 和实现分支 Artifact 用于实施验证；
- 合并后 `main` 工作流必须重新构建，不得复用分支 IPA 冒充合并结果；
- 真机 `ACCEPTED` 验收必须使用 `main` 对应提交生成的 IPA；
- 工作流必须配置 concurrency，在同一分支出现新提交时取消旧的未完成运行。

## 9. 版本与 Artifact 规则

- `CFBundleShortVersionString` 沿用 `pubspec.yaml` 的版本名
- `CFBundleVersion` 使用 GitHub `run_number` 或其他单调递增整数
- Bundle ID 固定为 `com.jsdfhasuh.embyclient`
- 有效 Keychain 身份在所有构建之间保持稳定
- IPA 文件名：`emby-ios-core-<short-sha>-<run-number>.ipa`
- 诊断包文件名：`emby-ios-core-diagnostics-<short-sha>-<run-number>.zip`

诊断包至少包含：

- `Runner.app.dSYM`
- commit SHA
- Flutter / Dart / Xcode / macOS / Ruby / CocoaPods / ldid 版本
- `pubspec.lock` 与 `ios/Podfile.lock` 哈希
- 最终 `Info.plist`
- `scripts/ios/trollstore-entitlements.plist` 及其 SHA-256
- 构建时 resolved entitlement
- fakesign 后及最终 IPA 中的 entitlement dump
- 主二进制及嵌入式 Mach-O 架构检查结果
- IPA SHA-256

## 10. 明确不在首轮范围内

以下内容不得为了“顺便完成”而扩大本次改动：

- App Store、TestFlight、正式证书和发布流程
- 可靠的 iOS 后台持续下载
- iOS 原生画中画
- iOS 局域网 UDP 自动发现和 multicast entitlement
- AirPlay、投屏、Live TV、SyncPlay 或新功能开发
- iPhone 设备支持和专项 UI 优化
- iPad Split View、Slide Over、Stage Manager 和可调整窗口支持
- iPad `NavigationRail`、双栏和桌面级布局重构
- macOS、Windows、Linux 或 Web 平台适配
- 播放器整体替换
- 无效证书、自签名 HTTPS 的全局信任绕过
- 与 iOS 适配无关的 Android 重构

## 11. 实施阶段

### 阶段 A：平台骨架与编译闭环

- 建立实现分支并记录实际基线 SHA
- 使用固定 Flutter revision 生成并审查 `ios/`
- 按固定模板证据处理 `.metadata` iOS migration 信息
- 固定 Bundle ID、iPad-only、iOS 13 和全屏方向策略
- 配置唯一 entitlement 源、Keychain、本地网络和 ATS
- 切换到跨平台 `media_kit_libs_video`
- 使用固定 CocoaPods 生成并提交 `ios/Podfile.lock`
- GitHub Actions 能无签名生成设备版 `Runner.app`

完成条件：iOS Release 构建通过，锁文件无漂移，Android 门禁保持通过。

### 阶段 B：平台专用行为隔离

- 引入轻量平台能力层
- 隔离 Android 前台下载初始化
- 修正新设备 ID 前缀
- iOS 禁用自动发现
- 画中画通道安全降级
- 增加相应单元和 Widget 测试

完成条件：iOS 冷启动不触发 Android 专用调用或未处理的 MethodChannel 异常。

### 阶段 C：TrollStore Artifact

- 固定并校验 Homebrew Core `ldid 2.1.5`
- 标准化唯一 entitlement 源、resolved entitlement、fakesign 和 IPA 打包
- 校验架构、Info.plist、锁文件和 entitlement
- 上传 IPA、dSYM、SHA-256 和诊断包
- 记录安装步骤及已知限制

完成条件：实现者达到可交付真机验证的 `IMPLEMENTATION_COMPLETE` 候选状态。

### 阶段 D：核心在线功能验收

由设备所有者使用合并后 `main` Artifact 在真实 iPad 验收：

- 登录与会话恢复
- 首页、媒体库、搜索和详情
- 图片与 WebSocket
- H.264 + AAC DirectPlay 或 DirectStream
- 强制 Transcode 路径
- 音轨、字幕、拖动、续播和播放进度
- 生命周期切换和方向恢复

完成条件：至少一部电影和一集电视剧完成核心播放流程，两类播放路径均有证据。

### 阶段 E：离线与回归

- 前台下载、暂停、恢复和删除
- 进程终止后的中断任务状态恢复
- 离线播放和进度同步
- 存储空间和文件完整性
- 覆盖升级后的数据库、Keychain 和离线记录连续性
- iPad 横竖屏和安全区域
- Android 全量回归

完成条件：自动测试、Android APK 和 iPad 验收清单全部通过，状态进入 `ACCEPTED`。

## 12. 自动测试要求

至少补充以下自动测试或构建脚本门禁：

- 已保存设备 ID 不因平台适配而改变
- 新设备 ID 使用正确的平台前缀
- iOS 能力配置不会创建 Android 前台下载执行器
- iOS 登录页不会自动启动 UDP 广播发现
- 画中画原生通道缺失时 `isSupported` 和 `updatePlaying` 安全降级
- Android 能力配置仍启用前台下载和服务器发现
- 平台能力对象可注入，不依赖当前测试宿主的真实平台
- 应用进程中断后的无 executor 下载任务恢复为明确的可继续状态
- 平台分支不影响现有下载、离线播放和播放器控制测试
- Bundle ID、目标设备族、最低系统版本和关键 Info.plist 项可由脚本验证
- `.metadata` 与固定 Flutter 模板的处理结果有可审查证据
- `pubspec.lock` 与 `ios/Podfile.lock` 在 CI 中不漂移
- 人工维护 entitlement 源与 Xcode、resolved、fakesign 后、最终 IPA entitlement 的关键项一致
- entitlement 白名单拒绝未批准的私有或高权限项
- 打包脚本拒绝非 `arm64` 主应用和缺少必要 entitlement 的产物
- ldid 实现或版本不是 Homebrew Core `2.1.5` 时构建失败

## 13. 真机验收记录

真机验收结果应写入独立文档，例如：

`docs/acceptance/2026-08-ios-core-ipad-acceptance.md`

至少记录：

- iPad 型号与 iPadOS 版本
- TrollStore 版本
- IPA 对应 `main` commit SHA、run number 和 SHA-256
- Emby Server 版本
- Bundle ID、应用版本和构建号
- 测试媒体的容器、视频编码、音频编码和字幕类型
- DirectPlay / DirectStream / Transcode 的实际选择结果
- 每项通过、失败或未测状态
- 覆盖升级前后的会话、有效 Keychain 身份、数据库和离线记录状态
- 失败时的诊断日志摘要和原生崩溃日志符号化结果

Codex 或其他实现者只能创建验收模板，不得代替设备所有者填写虚假的通过结果。

## 14. 提交与审查规则

建议按可独立审查的提交拆分：

1. `build: add audited iPadOS runner`
2. `build: lock iOS native dependencies`
3. `build: use cross-platform media kit video libs`
4. `refactor: isolate mobile platform capabilities`
5. `fix: make unsupported iPadOS features safe`
6. `ci: build fakesigned TrollStore artifact`
7. `test: cover iPadOS platform boundaries`
8. `docs: add iPad acceptance template`
9. `docs: record device acceptance`（只能在用户真机验收后提交）

约束：

- 每个提交都必须保持 `flutter analyze` 和 `flutter test` 通过
- 不得把大量生成文件和业务修复混在同一个提交中
- 不得删除或弱化 Android 测试来使 iOS 构建通过
- 不得通过修改或忽略锁文件来掩盖依赖解析问题
- 遇到插件不兼容时先记录根因，再做最小替换；禁止无说明地更换整套架构
- README 只有在状态进入 `ACCEPTED` 后才能修改项目定位

## 15. 风险与处理原则

### 播放器能编译但真机黑屏或崩溃

先确认原生库、设备架构、渲染和 HTTP Header，再检查具体编码。Transcode 成功不能单独证明播放器 Core 完成；仍需完成 H.264 + AAC DirectPlay 或 DirectStream。首轮不同时引入第二播放器。

### IPA 可安装但 Keychain 不持久

检查唯一 entitlement 源、resolved entitlement、fakesign 后和最终 IPA entitlement、Bundle ID 及有效 Keychain 身份是否一致。会话恢复是 Core 的硬性验收项，不得通过改用明文 SharedPreferences 绕过。

### Pod 或 Dart 依赖在 CI 中漂移

CI 必须失败。不得在普通构建中自动更新锁文件；需要升级依赖时应提交独立变更并说明影响。

### HTTP 局域网地址无法访问

检查本地网络权限和 ATS 配置。不得关闭 TLS 校验或全局信任任意证书作为修复。

### iPad 无法按现有逻辑切换横屏

确认 `UIRequiresFullScreen`、支持方向和 Xcode 配置一致。首轮不以牺牲播放器方向契约为代价同时支持多任务窗口；多任务适配后置。

### iOS 后台中断下载

普通挂起后回到前台应刷新状态并继续或允许继续；进程终止后任务应进入明确的中断状态并允许手动恢复。可靠后台下载另立 Goal。

### 平台判断难以自动测试

通过注入轻量平台能力对象解决，不使用依赖真实宿主平台的脆弱测试。

### GitHub Runner 或工具版本失效

不得静默升级。先记录失败原因，选择新的固定版本，并在同一 PR 中更新 Goal、工作流和工具链记录。

## 16. 最终交付物

- 受审查的 `ios/` 平台工程
- 基于固定 Flutter 模板证据处理后的 `.metadata`
- `Gemfile`、`Gemfile.lock` 和已提交的 `ios/Podfile.lock`
- 跨平台播放器原生依赖配置
- iPadOS 平台边界和安全降级实现
- 唯一人工维护的 `scripts/ios/trollstore-entitlements.plist`
- GitHub Actions Linux 门禁与 macOS iOS 构建
- 可复现的固定 `ldid 2.1.5` fakesign 和 IPA 打包脚本
- IPA、dSYM、SHA-256 和诊断 Artifact
- 新增平台相关自动测试
- TrollStore iPad 真机验收模板和最终验收记录
- Android 回归结果
- 真机验收后更新的 README

## 17. 完成定义

### `IMPLEMENTATION_COMPLETE`

必须同时满足：

- 所有自动化门禁通过
- Android 现有核心功能无回归
- 依赖锁文件在 CI 中无漂移
- 唯一 entitlement 源及最终 IPA entitlement 一致性门禁通过
- GitHub Actions 可重复生成同类 iPadOS Artifact
- Artifact 包含 IPA、dSYM、SHA-256、版本、锁文件、架构和 entitlement 证据
- 所有未实现能力在 UI 或文档中明确降级，不出现伪支持
- 已提交真机验收模板和安装说明

### `ACCEPTED`

在 `IMPLEMENTATION_COMPLETE` 基础上，还必须满足：

- 使用合并后 `main` 对应提交生成的 IPA
- TrollStore iPad 可安装、启动和覆盖升级
- Keychain 会话恢复和覆盖升级连续性通过
- 手动登录、浏览、两类在线播放路径、前台下载和离线播放完成真机验收
- 验收结果和已知限制已经入库
- README 仅以“实验性 iPadOS 支持”表述已经验收的范围

## 18. 参考资料

- Flutter iOS 构建与发布：<https://docs.flutter.dev/deployment/ios>
- Flutter iOS 开发环境：<https://docs.flutter.dev/platform-integration/ios/setup>
- media_kit 官方安装说明：<https://github.com/media-kit/media-kit#installation>
- Apple 本地网络权限：<https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription>
- Apple ATS 本地网络例外：<https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking>
- flutter_secure_storage：<https://pub.dev/packages/flutter_secure_storage>
- TrollStore：<https://github.com/opa334/TrollStore>
- Homebrew ldid：<https://formulae.brew.sh/formula/ldid>
