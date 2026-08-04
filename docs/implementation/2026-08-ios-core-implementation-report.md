# iPadOS Core 实现报告

## 状态

- 实现状态：`IMPLEMENTATION_IN_PROGRESS`
- 真机验收状态：`NOT_ACCEPTED`
- 本报告不代替设备所有者填写任何真机验收结果。
- 本轮范围保持冻结：iPadOS Core 播放、登录、媒体库、搜索、详情、下载数据层和受控 iOS 构建；不包含 iOS 原生画中画、可靠后台持续下载、UDP 自动发现、iPhone、App Store 或桌面端。

## 基线与提交

- 整改计划审计基线：`d7380ffd7b0b97930affa53a544574370834fedf`
- 本分支要求保留的计划基线：`6c906822055ef4cfd6740cbe97e00fb5a358d5f4`
- 当前报告提交前的分支 HEAD：`94a354c`
- 最终分支 SHA：待完整绿色 Actions 和 Artifact 生成后回填。

已完成的整改提交：

1. `a1b53aa` `fix: separate app and embedded iOS fakesigning`
2. `1422b8a` `fix: degrade optional iPadOS player controls safely`
3. `e6f72ac` `fix: align iPadOS client identity and network errors`
4. `94a354c` `ci: harden iOS lock and signing verification`
5. 本报告及验收状态修正提交：待提交。

## 关键实现

### fakesign 与 entitlement

- `scripts/ios/trollstore-entitlements.plist` 是唯一人工维护的 entitlement 源。
- `sync_entitlements.sh --runner-files` 只生成 Runner Debug/Release 镜像；镜像明确标记为不可直接编辑。
- `Runner.app/Runner` 最后使用批准的应用 entitlement 签名。
- Framework、dylib 和其他嵌入式 Mach-O 先使用空 entitlement 签名，禁止携带 `keychain-access-groups` 或其他应用 entitlement。
- 发现没有明确签名策略的 `.appex` 立即失败，不猜测扩展策略。
- 打包前和 IPA 解包后都重新检查 Bundle ID、`.appex`、Mach-O 架构和所有 Mach-O entitlement，并记录签名顺序、分类和 dump 文件。

### 播放与平台能力

- mpv 音频延迟、字幕延迟和字幕样式属性按属性独立捕获异常并安全降级；`open`、`play`、`pause`、`seek` 等核心播放错误仍进入失败路径。
- 亮度和音量读取/设置失败只触发本地安全降级，不形成未处理异步异常，也不阻止播放器启动。
- 播放器初始化有顶层错误边界，初始化失败会进入可观察的失败状态。
- iPadOS Emby Header 使用 `Device="iPadOS"`；Android 继续使用 `Device="Android"`，已有 Android device ID 不迁移。
- iPadOS 私网 IPv4/IPv6 连接失败会提供可恢复的本地网络权限提示；Android 既有错误策略保持不变。

### CI 与打包门禁

- `quality-and-android` 固定 Flutter revision，执行 lockfile、format、analyze、全量测试、shell 脚本检查和 Android 双构建。
- 普通 APK 与分 ABI APK 使用独立 Artifact 名称：`android-debug-apk-<run>`、`android-debug-split-apks-<run>`。
- `ios-device-build` 使用 Xcode 16.4、CocoaPods 1.16.2 和 Homebrew Core ldid 2.1.5，并在 iOS build 后再次检查 `pubspec.lock` 与 `ios/Podfile.lock` 无漂移。
- `test_packaging_negative_gates.sh` 覆盖错误 Bundle ID、无策略 `.appex`、嵌入式应用 entitlement 和非 arm64 架构拒绝。

## `.metadata` 模板比较

比较使用当前固定 Flutter revision 生成干净模板：

```text
flutter create --platforms=ios --no-pub --project-name metadata_template --org com.example build/metadata-template
```

模板 `.metadata` 的 migration 平台为 `root` 和 `ios`，并把以下路径列为 unmanaged：

```text
lib/main.dart
ios/Runner.xcodeproj/project.pbxproj
```

当前项目的 `.metadata` 保留同样的 unmanaged 列表，并额外记录已有 Android migration；这是因为当前仓库不是纯 iOS 模板，而是保留 Android 工程的 Flutter 应用。逐行比较显示除 Android migration 外，revision、channel、root/ios migration 和 unmanaged 说明一致。

模板与当前 `project.pbxproj` 的有效差异为：当前项目把 `TARGETED_DEVICE_FAMILY` 收窄为 `2`，使用 `com.jsdfhasuh.embyclient`，为 Debug/Release Runner 配置 entitlement 文件，并保留项目测试 Bundle ID；部署版本仍为 `13.0`。这些是 iPadOS Core 的有意工程定制，因此保留 `project.pbxproj` 的 unmanaged 标记，没有让 Flutter migration 覆盖它。当前 `Info.plist` 另外保留 iPad 全屏、本地网络说明和本地 HTTP ATS 配置。

## 工具、锁文件与本地结果

- 固定 Flutter revision：`67323de285b00232883f53b84095eb72be97d35c`
- 本机 Flutter：`3.38.9`
- 本机 Dart：`3.10.8`
- CI Xcode：`16.4`
- CI CocoaPods：`1.16.2`
- CI ldid：`2.1.5`
- `connectivity_plus`：`7.0.0`；`7.1+` 要求 Xcode 26，与本轮固定 Xcode 16.4 不兼容，因此锁定兼容版本。
- `dart format --output=none --set-exit-if-changed .`：通过，127 个文件检查、0 个文件改动。
- `flutter analyze`：通过，无 issues。
- `flutter test`：通过，`+282`。
- `git diff --check`：通过。
- Git Bash `bash -n scripts/ios/*.sh`：通过。
- ShellCheck `0.11.0`：通过全部 `scripts/ios/*.sh`；Ubuntu CI Job 也会安装、打印版本并执行同一检查。
- Android 普通 Debug：`build/app/outputs/flutter-apk/app-debug.apk` 构建通过。
- Android 分 ABI Debug：`app-armeabi-v7a-debug.apk`、`app-arm64-v8a-debug.apk`、`app-x86_64-debug.apk` 构建通过。
- `flutter pub get --enforce-lockfile`：通过；随后 `pubspec.lock` 无漂移。
- 当前 Windows 工作树中的 `ios/Podfile.lock`：无漂移；CocoaPods 安装和 iOS build 后复查待 macOS Actions 确认。

## Actions 与 Artifact

- 分支 Actions run URL：待推送后回填。
- `quality-and-android`：待运行。
- `ios-device-build`：待运行。
- IPA Artifact：`ios-core-ipa-<run>`，应包含 IPA 与 `*.ipa.sha256`。
- dSYM Artifact：`ios-core-dsym-<run>`，应包含 `*.dSYM.zip`。
- diagnostics Artifact：`ios-core-diagnostics-<run>`，应包含版本、锁文件哈希、工具版本、架构、分类、签名顺序、IPA SHA-256 及 fakesign/最终 entitlement dump。

在两个 Job 成功且上述 Artifact 全部真实生成前，实现状态保持 `IMPLEMENTATION_IN_PROGRESS`。

## 最终签名证据

待 Actions 生成并回填以下证据文件：

- `entitlements-fakesign/main/Runner.plist`：应用 entitlement，来自唯一源。
- `entitlements-fakesign/embedded/*.plist`：空 entitlement；不得出现 `keychain-access-groups`。
- `entitlements-final/main/Runner.plist`：IPA 解包后的应用 entitlement。
- `entitlements-final/embedded/*.plist`：IPA 解包后的嵌入式 entitlement，仍为空。
- `signing-order.txt`：所有嵌入式 Mach-O 在 `Runner` 之前签名。
- `architecture-fakesign.txt`、`architecture-final-ipa.txt`：所有 Mach-O 为 arm64。
- `Info.plist`、`macho-classification-final.txt` 和 `lockfiles-sha256.txt`：Bundle ID、分类和锁文件证据。

## 已知限制与设备所有者步骤

已知限制严格遵循冻结 Goal：不提供 iOS 原生画中画、可靠后台持续下载、UDP 自动发现、iPhone、App Store、桌面端或其他未列入范围的能力。未有真实 iPad 验收前，不声明 `ACCEPTED`。

设备所有者应在合并后的 `main` Actions 重新生成 IPA 后执行：核对 IPA SHA-256，使用 TrollStore 安装并确认 Bundle ID；冷启动和覆盖升级；验证本地网络权限允许/拒绝后的可恢复登录；验证 Keychain 会话恢复、媒体库和搜索；验证 DirectPlay、DirectStream/不适用说明、Transcode、暂停/拖动/进度、音轨和字幕；验证亮度/音量失败降级、横屏恢复、前台下载和离线播放；最后下载 diagnostics 并记录每项 `PASS`/`FAIL`/`NOT_TESTED` 及日志位置。验收表仍由设备所有者填写。
