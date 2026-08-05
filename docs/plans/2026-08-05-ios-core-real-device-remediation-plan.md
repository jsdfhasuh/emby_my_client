# iPadOS Core 真机失败整改计划

## 0. 文档元数据与约束效力

- 文档状态：`FROZEN_FOR_IMPLEMENTATION`
- 当前实现状态：`IMPLEMENTATION_IN_PROGRESS`
- 当前真机验收状态：`NOT_ACCEPTED`
- 计划日期：2026-08-05
- 仓库：`jsdfhasuh/emby_my_client`
- 实施基线：`main@9b74b6216e25375ee2e44e8019bfbff9546a5f51`
- 实施分支：`agent/ios-core-real-device-remediation`
- 计划文件：`docs/plans/2026-08-05-ios-core-real-device-remediation-plan.md`
- 上位 Goal：`docs/plans/2026-08-03-ios-core-adaptation-goal.md`
- 历史整改计划：`docs/plans/2026-08-04-ios-core-final-remediation-plan.md`
- 实现报告：`docs/implementation/2026-08-ios-core-implementation-report.md`
- 真机验收表：`docs/acceptance/2026-08-ios-core-ipad-acceptance.md`

本计划由合并后 `main` IPA 的真实 iPad/TrollStore 失败触发，是对上位 Goal 的事实性纠偏。发生冲突时，按以下顺序处理：

1. 本计划在“当前状态、TrollStore 有效 Keychain 身份、登录失败诊断、登录事务和 iPad 键盘避让”范围内优先；
2. 上位 Goal 的其余冻结范围、平台边界、安全要求和最终验收定义继续生效；
3. 历史整改计划和实现报告只作为历史证据，不得覆盖本次真实设备结论；
4. 无法判断是否冲突时停止实施并汇报，不得自行扩大范围。

上位 Goal `6.8` 中“未验证共享组时保持空的 `keychain-access-groups`”适用于正常 Xcode/Provisioning Profile 签名假设，不能直接作为 TrollStore 最终假签名 Runner 的有效运行时身份。本计划仅对这一 TrollStore 场景作窄幅替代，不允许借此添加其他 entitlement。

## 1. 真机失败事实与当前结论

设备所有者已使用合并后 `main` 生成的 TrollStore IPA 在真实 iPad 上测试，并报告：

1. IPA 可以安装和启动；
2. 手动输入局域网 Emby 地址、用户名和密码后，页面显示“登录失败，请稍后重试”；
3. 软件键盘弹出后，服务器、用户名、密码及登录按钮被遮挡，屏幕只剩品牌图标可见；
4. 系统键盘本身的方向和按键渲染没有证据表明异常，已确认的问题是应用登录页的短视口避让和焦点滚动失败。

两张原始照片包含明文密码，**禁止提交到仓库、Issue、PR、Actions Artifact 或诊断日志**。文档只允许记录上述脱敏事实。如需保存图片证据，必须由设备所有者重新拍摄或打码后再决定是否提交。

当前结论：

- TrollStore 安装、启动：已有初步成功证据，但仍需在正式验收表中填写准确构建和设备信息；
- 局域网手动登录：`FAIL`；
- iPad 软件键盘下的登录页可用性：`FAIL`；
- Keychain entitlement 是高度可疑根因，但在取得阶段化运行时证据前只能标记为 `SUSPECTED_ROOT_CAUSE`；
- 原 `IMPLEMENTATION_COMPLETE` 声明已被真实设备核心失败推翻，当前必须视为 `IMPLEMENTATION_IN_PROGRESS`；
- 所有未执行项目继续为 `NOT_TESTED`，不得推算为 `PASS`；
- 在修复、Actions、分支真机复验和合并后 `main` 最终真机验收全部完成前，状态必须保持 `NOT_ACCEPTED`。

## 2. 整改目标

本计划只解决下列五个闭环：

1. 让登录失败发生在哪个阶段、属于什么安全分类可以被稳定识别，同时不泄露密码、Token、用户名、设备 ID 或服务器敏感信息；
2. 建立 TrollStore Runner 可实际使用且范围最小的稳定 Keychain 身份，保留嵌入式代码无应用 entitlement 的边界；
3. 让登录成为可回滚、不会留下半会话的事务；
4. 让 iPad 横屏、竖屏、旋转、较大文字和软件键盘场景下的输入框及登录按钮可访问；
5. 用自动测试、打包门禁、Actions Artifact 和两阶段真机复验重新建立证据链。

完成本计划的分支实现后，最多恢复为：

```text
IMPLEMENTATION_COMPLETE
NOT_ACCEPTED
```

只有合并后的 `main` 新 IPA 完成上位 Goal 的完整真机清单，设备所有者才可以改为：

```text
ACCEPTED
```

## 3. 范围冻结

### 3.0 优先级

| 优先级 | 内容 | 阻塞规则 |
| --- | --- | --- |
| P0 | 安全阶段诊断、STOP GATE A、Keychain 条件修复、登录原子性、键盘可达、分支真机预验收 | 任一未完成或失败都禁止恢复 `IMPLEMENTATION_COMPLETE` |
| P1 | 日志纵深脱敏、CI/Artifact 证据、状态与验收文档回填、Android 回归 | 任一未完成都禁止请求合并 |
| P2 | 仅改善实现可读性且不改变范围的内部整理 | 不得延误 P0/P1，不得扩大重构 |

### 3.1 本轮允许修改

- `lib/data/session_store.dart`
- `lib/state/app_controller.dart`
- `lib/ui/login_screen.dart`
- `lib/core/diagnostic_log.dart`，仅限安全诊断和脱敏能力
- 必要的新错误类型或小型内部辅助文件
- 登录、SessionStore、AppController、诊断日志和键盘布局相关测试
- `scripts/ios/` 下的 entitlement 同步、验证、打包、负向门禁和校验脚本
- `scripts/ios/runner-entitlements.plist`，作为普通 Xcode Runner 的唯一策略源
- `ios/Runner/DebugProfile.entitlements`
- `ios/Runner/Release.entitlements`
- `.github/workflows/ios-core.yml`
- 本计划、实现报告和真机验收记录

### 3.2 本轮明确禁止

- iOS 原生画中画；
- 可靠后台持续下载；
- iOS UDP 自动发现；
- iPhone 支持；
- App Store、正式 Apple 签名或 Provisioning Profile 流程；
- macOS、Windows、Linux 等桌面端；
- 替换播放器、升级 Flutter、升级 Dart、升级 CocoaPods、升级 ldid 或无关依赖；
- Split View/Stage Manager 专项功能承诺；小窗口只作为响应式回归场景；
- 与登录、Keychain、键盘无关的 UI 重构；
- 修改媒体库、播放、下载业务契约；
- 修改 Android 设备 ID、已保存会话或现有用户数据迁移规则；
- 直接修改或推送 `main`；
- 自动合并 PR；
- 提交原始真机照片或任何真实凭据。

## 4. 必须保持的不变量

整改过程中以下事实必须保持：

- Bundle ID：`com.jsdfhasuh.embyclient`；
- `MinimumOSVersion`：iOS 13.0；
- `UIDeviceFamily`：仅 `[2]`，即 iPad-only；
- 所有可执行 Mach-O：仅 arm64；
- 不存在未定义签名策略的 `.appex`；
- 嵌入式 Framework/dylib 不得携带 Runner 应用 entitlement；
- 嵌入式代码先签名，Runner 最后签名；
- IPA SHA-256 使用可移植 basename，并可在下载目录直接校验；
- `pubspec.lock` 和 `ios/Podfile.lock` 不漂移；
- `main@9b74b6216e25375ee2e44e8019bfbff9546a5f51` 的历史基线为 `flutter test` 通过 284 项；新增测试应使计数相应增加，不得通过删除、跳过或弱化既有测试换取。若确有语义等价的测试合并，必须先取得审查者批准并在实现报告说明旧/新覆盖关系；
- Android 普通 Debug APK 和三个分 ABI Debug APK 必须继续构建；
- Android 登录、服务器发现、错误文案、会话和设备 ID 行为不得改变；
- AccessToken 和密码不得降级保存到 SharedPreferences、普通文件、SQLite 或日志；
- 不得记录完整 Session JSON、原始认证请求、Authorization Header 或带认证查询参数的 URL。

## 5. Luna 执行总规则

Luna 必须严格按阶段执行，不得跳到后续阶段，也不得一边猜测一边合并。

开始前必须：

1. 确认当前分支为 `agent/ios-core-real-device-remediation`；
2. 确认分支从 `9b74b6216e25375ee2e44e8019bfbff9546a5f51` 创建；
3. 执行 `git status --short` 并确认工作区干净；
4. 阅读本计划、上位 Goal、历史整改计划、实现报告和验收表；
5. 记录当前 `HEAD`、上游和锁文件状态；
6. 不得 rebase、force-push、改写历史或改动 `main`；
7. 每个阶段只提交本阶段文件，禁止 `git add -A` 混入无关改动；
8. 任何“真机验证”只能由设备所有者执行，Luna 不得代填 `PASS`；
9. 如果准确文件结构与计划不一致，先搜索确认，再做最小适配；禁止另起一套平行架构；
10. 如果某项需要真实设备证据才能决定，停下并汇报，不得选择权限更大的方案碰运气。

## 6. 当前代码事实与根因假设

### 6.1 登录错误为何不是普通网络提示

当前 `LoginScreen._submit()`：

- `EmbyApiException` 会显示认证、HTTP、网络超时或本地网络权限等具体文案；
- 只有其他异常落入 `catch (_)`，显示“登录失败，请稍后重试”。

因此真机截图证明发生的是非 `EmbyApiException`，或者 `EmbyApiException` 之外的登录后处理异常。它不证明密码错误，也不证明服务器不可达。

### 6.2 当前 `signIn` 的关键顺序

当前 `AppController.signIn()` 依次执行：

```text
SessionStore.getOrCreateDeviceId()
EmbyApi.authenticate()
构造 ServerScope
恢复媒体库分类设置
SessionStore.saveSession()
构造 API client（此时尚未注册）
保存 previousScope
关闭旧下载
注销 previousScope
写入内存 session/scope
恢复 capabilities
写入分类设置
注册 API client
激活下载
启动 realtime
notifyListeners()
```

这意味着异常可能发生在网络认证之前，也可能发生在认证成功之后。现有 UI 把这些异常合并为一句兜底文案，而且 `saveSession()` 后仍有可失败步骤，存在半提交风险。

### 6.3 Keychain 高度可疑的原因

`SessionStore` 使用 `flutter_secure_storage`。当前最终 TrollStore Runner 的人工 entitlement 源只有：

```xml
<key>keychain-access-groups</key>
<array/>
```

最终 IPA 证据同时表明 Runner 缺少可建立默认 Keychain 组的稳定 `application-identifier`，而所有嵌入式 entitlement 为空。

TrollStore 官方实现只在主二进制完全没有 entitlement 时注入 fallback 身份。当前 Runner 已有一个 entitlement 字典，只是数组为空，因此可能绕过 fallback，导致 `flutter_secure_storage` 在读取或写入设备 ID/Session 时返回 Keychain entitlement 错误。

该判断在本计划开始时只能写为：

```text
SUSPECTED_ROOT_CAUSE: effective Keychain identity is empty or unusable
```

只有满足下列任一条件才能改为 `CONFIRMED_ROOT_CAUSE`：

- 阶段化诊断明确显示设备 ID 或 Session 安全存储阶段发生 missing-entitlement 类错误；
- 修复后的新 IPA 通过 Keychain 写入、读取、杀进程恢复和覆盖安装连续性，而相同网络与凭据的基线 IPA稳定失败；
- 目标设备安装日志或安全存储探针提供等价证据。

### 6.4 实施时必须核对的上游依据

Luna 不得依赖二手博客或自行想象签名行为。开始 Keychain/entitlement 修改前，至少核对：

- Apple `errSecMissingEntitlement`：<https://developer.apple.com/documentation/security/errsecmissingentitlement>
- Apple 对有效 Keychain access-group 组成的说明：<https://developer.apple.com/forums/thread/67047>
- 本项目锁定的 `flutter_secure_storage 10.0.0` iOS Keychain 配置：<https://github.com/juliansteenbakker/flutter_secure_storage/blob/v10.0.0/flutter_secure_storage/README.md>
- TrollStore 主程序无 entitlement 时的 fallback 实现，固定参考提交 `88424f683b2a08f34a3f88985f790f97d84ce1df`：<https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/RootHelper/main.m>
- Flutter `MediaQuery.viewInsets`：<https://api.flutter.dev/flutter/widgets/MediaQueryData/viewInsets.html>
- Flutter `Scrollable.ensureVisible`：<https://api.flutter.dev/flutter/widgets/Scrollable/ensureVisible.html>
- Flutter `Scaffold.resizeToAvoidBottomInset`：<https://api.flutter.dev/flutter/material/Scaffold/resizeToAvoidBottomInset.html>

引用只用于确定行为边界。最终结论仍必须由本仓库打包证据和目标 iPad 真机结果证明。

## 7. 阶段 0：记录失败状态并打开 CI 分支

### 7.1 文档状态

先提交纯文档/CI 状态修正：

- `docs/implementation/2026-08-ios-core-implementation-report.md`
  - 保留 run 17 及旧 Artifact 的历史证据，不删除、不改写；
  - 独立核验并补记合并后 `main` 的基线 run（设备所有者下载的 Artifact 名称显示为 run 20，但 run URL、HEAD、文件名和 SHA 必须从 GitHub/Artifact 实际读取，不能只凭文件名猜测）；
  - 将当前实现状态改为 `IMPLEMENTATION_IN_PROGRESS`；
  - 增加“2026-08-05 真机失败”章节；
  - 只记录脱敏事实，不提交原图；
  - 标记登录和键盘为阻塞项。
- `docs/acceptance/2026-08-ios-core-ipad-acceptance.md`
  - 当前状态保持 `NOT_ACCEPTED`；
  - 实现状态改为 `IMPLEMENTATION_IN_PROGRESS`；
  - 新增“2026-08-05 基线失败记录”独立小节/表，记录局域网手动登录 `FAIL`、横屏键盘可达 `FAIL`、竖屏/旋转 `NOT_TESTED`；
  - 正式验收清单新增“横屏键盘弹出后当前字段与登录按钮可达”和“竖屏/旋转后当前字段与登录按钮可达”两项，但后续整改结果必须写入新的“整改分支预验收记录”，不得覆盖或删除基线 FAIL；
  - 其他项目保持原状，不得代填 `PASS`；
  - 未知的 iPad 型号、iPadOS、TrollStore 版本、run URL、IPA SHA 不得猜测。

### 7.2 Actions 触发修正

当前 `.github/workflows/ios-core.yml` 的 push 只监听 `main` 和 `agent/ios-core-adaptation`。必须增加：

```yaml
- agent/ios-core-real-device-remediation
```

同时在 `pull_request.paths` 增加：

```yaml
- 'docs/implementation/**'
```

保留现有 `docs/plans/**` 和 `docs/acceptance/**`。不得删除 `workflow_dispatch`。

### 7.3 阶段 0 完成条件

- 状态文档准确；
- workflow branch filter 与状态文档先在本地全部形成提交，再进行首次统一 push；不得只推尚未监听新分支的文档提交后等待一个不会触发的 run；
- 包含新 branch filter 的远端 HEAD push 可以触发两个 Job；
- 不修改任何生产代码；
- `git diff --check` 通过；
- 提交信息：`docs: record iPadOS real-device remediation state`；
- CI 触发修正可单独提交：`ci: build iPadOS real-device remediation branch`。

## 8. 阶段 1：建立安全、可测试的登录阶段诊断

### 8.1 固定阶段代码

新增稳定枚举或等价常量，不得用自由文本拼接阶段：

```text
PREFLIGHT
SESSION_READ
DEVICE_ID_READ
DEVICE_ID_WRITE
AUTHENTICATE
SESSION_PREPARE
SESSION_SAVE
ACTIVATE
SESSION_DELETE
ROLLBACK
```

错误必须分成两层，不得重复包装：

```text
EmbyApiException（保持原类型）
  authentication / HTTP / network / local-network

SignInFailure / SecureStorageFailure（固定枚举）
secure_storage_missing_entitlement
secure_storage_unavailable
secure_storage_access_denied
secure_storage_unexpected
session_prepare_failed
session_save_failed
activation_failed
already_in_progress
already_signed_in
unknown
```

`EmbyApiException` 必须保持原类型和原有安全文案，不得统一包装成未知错误。本地网络权限恢复提示、401/403、超时、HTTP 状态和证书错误仍走原路径。

### 8.2 `SessionStore` 错误边界

在 `lib/data/session_store.dart` 中：

1. 给 `readDeviceId`、`writeDeviceId`、`readSession`、`writeSession`、`deleteSession` 建立明确操作类型；
2. 捕获 `PlatformException` 并映射为固定的安全原因；
3. 允许识别 `errSecMissingEntitlement`/OSStatus `-34018`，但只能检查 `PlatformException` 的结构化 `code`、`message` 或 `details`；只把独立数值/严格格式的 `-34018` 映射为 missing-entitlement，禁止对任意异常全文使用宽泛 `contains('-34018')`；
4. 识别只用于分类，禁止把原始 `message`、`details` 或 Keychain value 放入错误对象或日志；
5. 匹配完成后立即丢弃原始字段；`SecureStorageFailure` 不得保留原始 cause；未知格式只携带批准的错误类型枚举和固定 reason；
6. 不改变现有 Session JSON 结构、Key 名和 Android 设备 ID 规则；
7. 不增加任何明文降级存储。

建议新增内部类型：

```text
SecureStorageOperation
SecureStorageFailureReason
SecureStorageFailure
```

命名可按项目风格微调，但语义和测试不得减少。

### 8.3 `AppController.signIn` 阶段包装

在 `lib/state/app_controller.dart` 中：

1. 将认证调用改为可注入依赖，默认仍调用 `EmbyApi.authenticate`，便于不访问网络的事务测试；
2. 为每个固定阶段记录 start/success/failure；
3. 其他异常转换成只含 stage、reason、errorType 的安全 `SignInFailure`；
4. 不向错误对象复制 serverUrl、username、password、deviceId、Token、Session 或原始异常字符串；
5. 保持公共 `Future<void> signIn(...)` 形状，除非现有测试证明必须做最小签名调整；
6. 开始时若 `_session != null`、`_scope != null` 或存在 active client，立即抛出 `PREFLIGHT/already_signed_in`，不得认证、写 Session、清 Session、关闭旧下载或注销旧 client；账号切换只能执行 `signOut → 返回登录页 → signIn`；
7. 第一个 signIn 未完成时，第二个调用立即抛出 `PREFLIGHT/already_in_progress`；不得读取第二组参数、不得返回第一个 Future、不得认证或写 Session；
8. 登录失败不得发送“已登录”通知。

`AppController._initialize()` 的 Session 恢复也必须纳入安全边界：

- `SessionStore.loadSession()` 的安全存储失败使用固定 `SESSION_READ` stage/reason 记录；
- 不得再把原始 `PlatformException` 交给 `DiagnosticLog.error(error: ...)`；
- 启动恢复失败后可以进入未登录状态，但必须保留可诊断的固定原因；
- 损坏 JSON 的既有清理语义保留，清理失败必须作为 `SESSION_DELETE` 安全错误分类；
- 启动失败不得崩溃、循环读取或留下 `_session/_scope` 半状态。

### 8.4 安全日志接口

在 `lib/core/diagnostic_log.dart` 增加固定字段的安全失败入口，例如：

```text
component
event
stage
reason
errorType
```

登录、认证和安全存储失败路径禁止把原始 error、message、details、request、response 或 stackTrace 交给会执行自由文本拼接的通用日志接口。安全入口的 stage/reason/errorType 应使用枚举或批准值，不接受换行或任意自由文本。

第一道且主要的安全边界是**结构化 allowlist**：本路径从源头只接收上述固定字段，绝不先接收原始异常再尝试清洗。全局 redaction 只是既有通用日志路径的纵深防护，本轮不得重写整个日志系统，也不得用会误删正常诊断内容的宽泛正则。防御性脱敏至少识别以下明确字段名或 Header 上下文：

```text
password
Pw（仅作为 JSON/表单中的完整字段名，不匹配普通文本子串）
AccessToken
api_key
X-Emby-Token
Authorization
username
deviceId
带凭据或 query 的 URL
```

需要覆盖 JSON、表单、Header 和普通键值文本形式。日志允许记录固定错误代码，但不得记录真实值。

### 8.5 用户文案

`SignInFailure` 必须通过只接受枚举的 const/switch 映射生成一个固定、非敏感、可人工抄录的诊断码；禁止把原始异常或任意字符串拼进码中。未登录用户不依赖登录后的设置/日志页面，登录页错误框本身必须同时显示安全文案和诊断码。最低固定映射：

| stage / reason | 登录页诊断码 |
| --- | --- |
| `DEVICE_ID_READ / secure_storage_missing_entitlement` | `LOGIN-DID-READ-KC-MISSING` |
| `DEVICE_ID_WRITE / secure_storage_missing_entitlement` | `LOGIN-DID-WRITE-KC-MISSING` |
| `SESSION_SAVE / secure_storage_missing_entitlement` | `LOGIN-SESSION-SAVE-KC-MISSING` |
| 上述三个 stage / `secure_storage_unavailable` | 对应 stage + 固定后缀 `KC-UNAVAILABLE` |
| 上述三个 stage / `secure_storage_access_denied` | 对应 stage + 固定后缀 `KC-DENIED` |
| 上述三个 stage / `secure_storage_unexpected` | 对应 stage + 固定后缀 `KC-UNEXPECTED` |
| `AUTHENTICATE / EmbyApiException` | `LOGIN-AUTH`，同时保留原认证/网络分类文案 |
| `SESSION_PREPARE` | `LOGIN-SESSION-PREPARE` |
| `ACTIVATE` | `LOGIN-ACTIVATE` |
| 未批准组合 | `LOGIN-UNKNOWN` |

其中“对应 stage”只能来自三项固定前缀 `LOGIN-DID-READ`、`LOGIN-DID-WRITE`、`LOGIN-SESSION-SAVE`；必须用穷尽 switch 实现并测试，不能运行时拼接未校验输入。

iPadOS 的 `LoginScreen` 至少映射：

- 安全存储不可用：`无法使用系统安全存储，登录信息不能安全保存。请记录诊断码并安装修复构建；除非验收步骤明确要求，请不要卸载现有版本。`
- 网络/认证/本地网络：保留现有 `EmbyApiException` 文案；
- 激活失败：`登录初始化失败，请重试；如持续出现，请提供诊断码。`
- 未知异常：保留通用兜底并附固定、非敏感诊断码。

普通用户文案不得直接出现 `PlatformException`、`-34018`、entitlement、Access Group、Token 或堆栈。

诊断类型和结构化日志可以跨平台复用，但上述新增安全存储恢复文案/可见诊断码只用于 iPadOS 真机整改路径；Android 登录页必须保持当前通用兜底和现有 EmbyApiException 文案，不得显示要求安装 iPadOS 修复构建的提示。使用现有平台能力抽象判断，禁止为此散布新的原始 `Platform.isIOS` 分支。

### 8.6 阶段 1 自动测试

至少新增：

- device ID read 抛 missing-entitlement：不调用 authenticate；
- device ID write 抛异常：不调用 authenticate；
- Session write 抛异常：不进入登录状态；
- App 启动时 Session read 抛异常：进入未登录状态，安全日志不含原始异常；
- 损坏 Session 触发 delete 且 delete 失败：固定分类，不产生未处理异常；
- 未知 PlatformException：归类为 unexpected；
- `code = '-34018'`、`details = -34018` 和严格 OSStatus message 正确分类；`id-340180` 或非 PlatformException 中出现 `-34018` 不得误判；
- 原始异常包含密码、Token、用户名、设备 ID、URL 时，安全错误和日志均不含原值；
- EmbyApiException 401、网络错误、本地网络错误保持原分类；
- 已登录状态调用 signIn：立即 fixed failure，原 Session/client/download 不变且不认证、不保存、不清除；
- 并发第二次 signIn：立即 `already_in_progress`，只有第一次触发认证；
- UI 分别展示安全存储、网络、认证、激活和未知错误的正确安全文案；
- iPadOS 未登录页面对三个 missing-entitlement stage 显示上表精确诊断码，设备所有者无需登录或读取内部日志即可抄录；
- Android 收到等价 PlatformException 时仍显示现有通用兜底，不出现 iPadOS 安全存储恢复文案或 iPadOS 诊断码。

提交信息：`fix: classify iPadOS sign-in failures safely`。

### 8.7 STOP GATE A：诊断 IPA 真机分流

阶段 1 提交并推送后，Luna 必须：

1. 等待该提交对应的 `quality-and-android` 与 `ios-device-build` 成功；
2. 汇报诊断代码 HEAD、Actions run、IPA 文件名和 SHA-256；
3. 停止本轮实施，不再创建任何代码提交；在设备所有者返回诊断结果并明确要求继续前，不得进入阶段 2–5；
4. 请求设备所有者安装该诊断 IPA并再次点击登录；
5. 设备所有者只需文字报告页面上的固定诊断码/安全文案，并补充 Safari 能否访问同一服务器、本地网络权限是否允许；不得再次发送含密码原图；
6. 若可取得 Emby 服务器日志，可脱敏确认是否收到 `/System/Info/Public` 或 `/Users/AuthenticateByName`，但不得提交用户名、密码、Token 或完整请求。

按固定证据分流：

```text
DEVICE_ID_READ / DEVICE_ID_WRITE / SESSION_SAVE
且 reason = secure_storage_missing_entitlement
  → 允许进入阶段 2 Keychain 路线

AUTHENTICATE + EmbyApiException
  → 禁止修改 entitlement；按现有网络/认证分类处理并重新审查范围

SESSION_PREPARE / ACTIVATE
  → 禁止把 Keychain 写成已确认根因；优先进入事务/本地组件路线

unknown 或没有稳定诊断码
  → 继续改进阶段诊断，禁止进入阶段 2
```

`SESSION_READ` 发生在启动恢复路径，本计划只要求其进入安全结构化日志，不要求把启动错误状态新增到登录页；因此它可以作为辅助证据，但不能单独解锁阶段 2。Gate A 的主分流只接受本次点击登录可直接观察到的 `DEVICE_ID_READ`、`DEVICE_ID_WRITE` 或 `SESSION_SAVE`。

只有第一种分流允许 Luna 实施本计划阶段 2 的精确三键候选。其他分流必须停止并向设备所有者说明当前证据与需要调整的计划，不得自行把阶段 2 当成“顺手修复”。

## 9. 阶段 2：建立最小 TrollStore Keychain 身份

### 9.1 两种签名上下文必须分开

本轮明确区分：

1. Xcode 工程输入 entitlement：用于普通 Flutter/Xcode 构建配置；
2. TrollStore 最终 Runner entitlement：用于 IPA 中主二进制的运行时假签名身份。

两者不再要求内容逐字相同。旧 Goal 中“同一空数组复制到所有上下文”的假设被本计划替代。CI 必须分别验证两种策略，不能再把“文件一致”当成“运行时 Keychain 可用”。

### 9.2 Xcode Runner 输入

`ios/Runner/DebugProfile.entitlements` 和 `ios/Runner/Release.entitlements` 保持 `flutter_secure_storage` 正常 Xcode 配置所需的最小形式：

```xml
<dict>
  <key>keychain-access-groups</key>
  <array/>
</dict>
```

不得在这两个文件中写入 `TROLLTROLL`、虚构 Apple Team ID、通配组或 TrollStore 专用身份。

普通 Xcode Runner 的唯一人工策略源固定为：

```text
scripts/ios/runner-entitlements.plist
```

它只包含上述空数组模板。`scripts/ios/sync_entitlements.sh --runner-files` 必须从该文件生成两个 Runner 镜像；镜像文件头继续标明不得手改。该源不得包含任何 Team ID、Bundle ID 或 TrollStore 身份。

### 9.3 TrollStore 最终 Runner 身份

在诊断门禁确认进入 Keychain 路线后，唯一允许 Luna 实现的候选是应用范围精确身份：

```xml
<dict>
  <key>application-identifier</key>
  <string>TROLLTROLL.com.jsdfhasuh.embyclient</string>
  <key>com.apple.developer.team-identifier</key>
  <string>TROLLTROLL</string>
  <key>keychain-access-groups</key>
  <array>
    <string>TROLLTROLL.com.jsdfhasuh.embyclient</string>
  </array>
</dict>
```

TrollStore 上下文的唯一人工策略源为：

```text
scripts/ios/trollstore-entitlements.plist
```

批准键必须**恰好**是上述三个，值和类型必须逐字匹配。禁止：

- 空 Keychain 数组；
- `TROLLTROLL.*` 通配组；
- `com.apple.token`；
- `get-task-allow`；
- `task_for_pid-allow`；
- `com.apple.security.application-groups`；
- `aps-environment`；
- 任何未在本节批准的额外 entitlement。

该精确 identity 是本项目依据 Apple 有效 Keychain group 规则，并根据固定 TrollStore 源码“保留已有 entitlement”的行为，从官方宽权限 fallback 收窄出的**待真机验证候选**；它不是 TrollStore 对第三方应用公开承诺的稳定 API。CI 打包成功只能记录：

```text
CANDIDATE_IDENTITY_PACKAGED
```

完成首次写入、杀进程读取、退出删除、再次登录和覆盖安装读取后，才能记录：

```text
CANDIDATE_IDENTITY_FUNCTIONAL
```

该精确组用于避免空组和官方 wildcard fallback，并降低非预期共享范围；它不提供 App Store/Provisioning Profile 签名体系下不可冒充的开发者身份隔离。在 TrollStore/CoreTrust 绕过环境中，其他主动声明相同 entitlement 的应用理论上可能请求同名 Keychain group。实现报告必须记录这一安全边界，设备所有者只应安装可信来源 IPA。

如果目标 TrollStore 拒绝安装、改写后身份不一致或 Keychain 仍失败，Luna 必须停止并汇报安装日志、打包前后 dump 和安全阶段码。未经设备所有者批准，不得自行切换到 TrollStore 官方宽权限 fallback，也不得编造另一个 Team ID/Access Group。

### 9.4 同步和验证脚本

调整 `scripts/ios/sync_entitlements.sh`、`validate_entitlements.sh`、`validate_embedded_entitlements.sh` 和 `build_trollstore_ipa.sh`：

1. 同步脚本必须有明确模式：`--runner-files` 只从 `scripts/ios/runner-entitlements.plist` 生成 Xcode 空数组镜像，`--trollstore <destination>` 只从 `scripts/ios/trollstore-entitlements.plist` 生成最终 fakesign resolved 文件；不得再保留会模糊选择身份的默认 positional 模式；
2. `validate_entitlements.sh` 必须提供明确的 `--xcode` 和 `--trollstore`/`--trollstore-dump` 模式，或拆成语义等价的两个脚本；所有 workflow、build 和负向门禁调用点必须显式选择模式，禁止继续用“source 与 candidate 逐字相同”的旧单策略语义；
3. Xcode 模式验证 source 和两个 Runner 镜像只有空的 `keychain-access-groups`；
4. TrollStore source/resolved/fakesign/final IPA dump 必须恰好包含三个批准键和值；
5. 嵌入式 Mach-O 必须继续使用空 entitlement；
6. 嵌入式先签，Runner 最后签；
7. IPA 打包前和解包后都执行验证；
8. diagnostics 保存 runner source、两个 Xcode 镜像、TrollStore source、resolved plist、fakesign dump、最终 IPA dump及各自 SHA-256；
9. 输出中明确区分 `packaged_entitlement` 与仍需真机证明的 `installed_effective_identity`；
10. 保留原架构、Bundle ID、最低系统、iPad-only、`.appex`、锁文件和便携式 checksum 门禁。

### 9.5 负向打包门禁

负向门禁按运行环境拆分：

- `test_entitlement_policy_negative_gates.sh`（允许新增该名称）：只用 plist fixture 测 source/value/type/extra-key，可在支持所需 plist 工具的质量环境运行；
- `test_packaging_negative_gates.sh`：在 macOS + ldid + Mach-O fixture/真实 Runner.app 上测试角色、签名顺序、dump 和篡改；
- `build_trollstore_ipa.sh`：对真实最终产物做正向 source/resolved/fakesign/final IPA 一致性验证。

上述门禁合计至少证明以下情况必定失败：

- Keychain 数组为空；
- 缺少 application identifier；
- 缺少 team identifier；
- application identifier 与 Keychain group 不一致；
- 使用 `TROLLTROLL.*`；
- 包含 `com.apple.token`；
- 包含 `get-task-allow` 或其他额外键；
- 把 Runner entitlement 写入 Framework/dylib；
- Runner 与 embedded 签名角色交换；
- Runner 不是最后签名项；
- source、resolved、fakesign 或最终 IPA dump 任一不一致。

测试不得只比较键名，必须比较类型、值、数组长度和额外键。

### 9.6 阶段 2 完成条件

- 脚本 `bash -n` 和 ShellCheck 通过；
- 所有正向与负向门禁通过；
- IPA 解包证据满足精确三键；
- 所有 embedded dump 为空；
- CI 只能声明 `PACKAGING_POLICY_VERIFIED`，不得声明 Keychain 真机可用；
- 提交信息：`fix: establish minimal TrollStore keychain identity`。

## 10. 阶段 3：让登录事务原子化并可回滚

### 10.1 事务规则

登录必须满足：

```text
失败时：isSignedIn == false，磁盘无新会话，client 未残留，下载/realtime 未残留
成功时：安全会话已保存，内存 session/scope/client 一致，只通知一次
```

具体要求：

1. `signIn` 只允许在 `_session == null`、`_scope == null` 且无 active client 时执行；已有会话立即返回 `already_signed_in`，零网络、零持久化、零清理；
2. 第一个 signIn 执行期间，第二个调用立即返回 `already_in_progress`，不得读取第二组凭据或共享第一个 Future；
3. 在认证前完成 device ID；该阶段失败不得调用网络；
4. 认证成功后先预计算 scope、settings、capabilities、API client 和所有可能失败但不改变全局状态的关键内容；
5. 允许注册一个仅属于本次 attempt 的临时 client，但不得写 `_session/_scope`、不得 notify，且失败时必须精确注销/dispose 该临时 client；如果无需提前注册则保持到提交后再注册；
6. `saveSession` 必须成为**最后一个可能失败的关键 await**；
7. `saveSession` 失败时清理本次临时资源，不调用 `clearSession`，因为新 Session 没有成功提交；
8. `saveSession` 成功后，只执行不会抛错的内存字段赋值/最终同步注册并 notify 一次；
9. downloads 和 realtime 等非关键能力在提交后按明确 best-effort 语义启动，每个 Future 自行捕获并用安全枚举记录，不能反转已经成功的登录；
10. 如果 Luna 发现某个关键失败步骤无法移动到 `saveSession` 之前，必须停止并说明，不能依赖“先写后删”模拟原子提交；
11. 不允许出现“界面显示登录失败，但 `_session != null`”；
12. 不允许登录失败后重启应用却恢复本次失败 Session；
13. 所有清理只能作用于本次 attempt 创建或注册的对象，不得清除旧账号或无关资源；
14. rollback 失败不能覆盖最初异常，只能追加安全诊断；
15. realtime 的未等待 Future 必须有错误处理，不能产生未处理异步异常。

### 10.2 关键与非关键初始化

Luna 必须先按当前实现逐项分类并写测试：

- device identity、authentication、secure session persistence、内存 session/scope/client 一致性属于关键步骤；
- 已经被平台能力明确禁用的下载功能不得阻断 iPad 登录；
- downloads/realtime 属于提交后的非关键启动；失败不得产生未处理异常或反转成功登录；
- library settings/capabilities 恢复已有默认值或降级时，应复用现有语义，不另创迁移；
- 任何改为 best-effort 的步骤必须有固定安全日志和测试，不能简单 `catch (_) {}`。

### 10.3 事务测试

至少覆盖：

- authenticate 失败：不写 Session；
- 已有 active Session 时调用 signIn：authenticate/save/clear 均为 0，旧 session/client/download 完全不变；
- 并发第二个 signIn 使用不同参数：立即 `already_in_progress`，只有第一次认证/保存；
- authenticate 成功、saveSession 失败：未登录，临时 client 注销/dispose，不调用 clearSession，download/realtime 未启动；
- saveSession 前的临时准备或注册失败：只清理本次 attempt 资源，不写/删 Session；
- attempt-local rollback 也失败：返回最初异常，安全记录 rollback failure；
- saveSession 成功后只有非抛错提交步骤；测试不得构造一个设计上仍存在的“写后关键失败”正常路径；
- iPad 禁用的下载执行器不会阻断登录；
- downloads/realtime 启动失败不反转登录且无未处理 Future；
- 失败后立即重试可以成功；
- 登录成功后杀进程恢复仍可读取相同 Session；
- 退出登录删除 Session；
- Android 原有登录和 device ID 行为不变。

提交信息：`fix: keep sign-in session activation atomic`。

## 11. 阶段 4：修复 iPad 登录页键盘避让与焦点滚动

### 11.1 定义问题

这不是修改 iOS 系统键盘，而是让 Flutter 登录页面在键盘造成的短视口中保持可用。禁止通过锁定方向、删除字段、隐藏登录按钮或改用第三方键盘规避。

### 11.2 生产代码结构

原则上只修改 `lib/ui/login_screen.dart`：

1. 类声明必须是 `class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver`；不得用 `implements WidgetsBindingObserver` 迫使页面实现整套接口；
2. 新增且只创建一次的 `_scrollController`；
3. 新增且只创建一次的 server、username、password 三个 `FocusNode`；
4. 每个字段外包一层无视觉 wrapper（例如 `KeyedSubtree`），wrapper 使用私有 `GlobalKey` 作为 `ensureVisible` 锚点；内部 `TextFormField` 使用本节末尾规定的 `ValueKey` 供测试定位。一个 Widget 只能传一个 Key，禁止把 GlobalKey 和 ValueKey 同时传给同一个字段；
5. 增加一个 `_ensureVisibleScheduled` 或等价调度标记，合并同一帧内重复请求，避免键盘动画连续触发多个滚动；
6. `initState` 注册 binding observer；三个 FocusNode 都注册同一个具名实例方法 `_handleFieldFocusChanged`，禁止用无法在释放时取得同一引用的匿名 closure；保留现有 discovery 初始化逻辑；
7. `dispose()` 先移除 binding observer，再用注册时的同一个 `_handleFieldFocusChanged` 方法引用逐一移除三个 FocusNode listener；随后 dispose 三个 FocusNode、`_scrollController` 和页面自有的 `_serverController`、`_usernameController`、`_passwordController`；不得 dispose 外部注入的 `widget.controller`，不得改变注入 discovery 的所有权；
8. 显式使用 `Scaffold(resizeToAvoidBottomInset: true)`，以 Scaffold 缩小 body 作为唯一键盘避让策略；
9. 页面结构固定为单一滚动链：`SafeArea > LayoutBuilder > SingleChildScrollView > ConstrainedBox(minHeight) > Align/ConstrainedBox(maxWidth: 420) > Form`；
10. ScrollView 绑定 `_scrollController`，使用稳定 Key，并设置 `keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag`；
11. `MediaQuery.viewInsetsOf(context).bottom` 在本方案中**只**用于计算 `keyboardVisible`；`resizeToAvoidBottomInset: true` 后，SafeArea 内 `LayoutBuilder.constraints.maxHeight` 已是避让键盘后的唯一可用高度来源，不得再从 constraints、minHeight 或“可见高度”减去 inset，也不得把 inset 加入底部 padding；
12. 禁止同时使用 `AnimatedPadding(viewInsets)`、`MediaQuery.removeViewInsets`、`maintainBottomViewPadding` 或任何第二套键盘避让；
13. 常规和紧凑模式分别选定竖向 padding；计算 `minContentHeight = max(0, constraints.maxHeight - 2 * verticalPadding)`，该值不得再减 keyboard inset；用该值设置内容 `ConstrainedBox.minHeight`。常规模式的 Column 垂直居中，紧凑模式从顶部开始；内容超过 minHeight 时只由上述 SingleChildScrollView 滚动；
14. 禁止把 `Expanded` 放进无边界 ScrollView，禁止嵌套可滚动 ListView，禁止用 IntrinsicHeight 包裹大型动态内容；
15. 不以 `Platform.isIOS`、具体 iPad 型号或固定屏幕尺寸决定布局。

### 11.3 紧凑品牌头

冻结常量：

```dart
const double _compactHeightThreshold = 600;
```

紧凑条件必须是：

```text
keyboardVisible || constraints.maxHeight < _compactHeightThreshold
```

键盘出现或可用高度低于 600 逻辑像素时：

- 将 54px Logo 和大标题压缩为 36–40px Logo + `titleLarge` 的单行品牌头；
- 隐藏副标题；
- 缩小非必要垂直间距；
- 不得隐藏服务器、用户名、密码、错误框或登录按钮；
- 常规高度继续保持现有品牌视觉和最大宽度。

### 11.4 焦点、滚动和旋转

1. server 的 Next 聚焦 username；
2. username 的 Next 聚焦 password；
3. password 的 Done 调用现有 `_submit()`；
4. 焦点变化后在 post-frame 对当前字段调用 `Scrollable.ensureVisible`；
5. 焦点首次变化可以执行一次 180–250ms、`Curves.easeOut`、alignment 0.1–0.2 的动画；
6. 禁止固定 scroll offset，因为发现列表、错误框和文字缩放都会改变位置；
7. `didChangeMetrics()` 在键盘动画、方向变化或窗口高度改变后，只用 `_ensureVisibleScheduled` 合并为每帧最多一个 post-frame 校正；metrics 路径统一调用 `Scrollable.ensureVisible(..., duration: Duration.zero)`，不得启动动画，也不得另写一套基于 `surfaceHeight - viewInsets` 的生产坐标算法；
8. 每次滚动前检查 `mounted`、`_scrollController.hasClients`、目标 FocusNode 仍有焦点、anchor context 非空；
9. 调度时把 `_ensureVisibleScheduled` 设为 true；post-frame callback 进入后的第一件事或 `try/finally` 必须将它恢复为 false，所有 mounted/focus/clients/context 提前返回和异常路径都不得留下 true；该标记不通过 setState 更新；
10. 不保存或等待已经过期的滚动 Future，不得在 dispose 后 setState、滚动或启动动画；
11. 禁止用单个 `Future.delayed(300ms)` 代替 metrics/post-frame 逻辑；
12. 三个 `TextFormField` 使用同一个 `onTapOutside` 具名处理器收起当前焦点；拖动 ScrollView 也必须收起键盘。禁止用会吞掉点击的全屏手势层，点击字段、发现服务器、密码眼睛和登录按钮必须仍触发原行为；
13. `_submit()` 开头继续 unfocus；失败时不得清空 server/username/password，也不得改变密码显隐状态；并发/重复提交沿用阶段 1/3 的 single-flight 防护；
14. 错误框出现后必须可以滚动访问，且不得自动重新弹键盘。

建议稳定 Key：

```text
login-scroll-view
login-server-field
login-username-field
login-password-field
login-error
login-submit-button
```

### 11.5 无障碍和 Android 边界

- 不得禁用系统文字缩放；
- 不得使用固定字体或剪裁消除 overflow；
- 错误文字必须可换行；
- 交互控件高度保持至少 48；
- 密码显隐 tooltip 保留；
- Android 局域网服务器发现、重新扫描、选择回填完整保留；
- Android 小屏和发现列表变长时，三个字段仍可通过同一 ScrollView 到达；
- Android 在键盘出现或短视口时允许使用同一紧凑品牌头；Android 无键盘且高度不少于 600 时必须保持原常规视觉；不得为了保留 Android 大 Logo 建立平台分支，也不得在紧凑模式隐藏发现数据；
- Android 不得显示仅属于 iPadOS 的本地网络权限恢复文案。

### 11.6 键盘 Widget 测试

新增 `test/login_keyboard_layout_test.dart`。测试中的 surface size、inset 和坐标一律使用逻辑像素：

- 用 `tester.binding.setSurfaceSize(Size(...))` 设置 surface，并在 `addTearDown` 中恢复；
- 通过 `MaterialApp.builder` 内的局部 `MediaQuery.copyWith(viewInsets: EdgeInsets.only(bottom: logicalInset), textScaler: TextScaler.linear(...))` 注入 inset 和文字缩放，不直接修改全局 tester view；
- 旋转测试必须保留同一个带稳定 Key 的 `LoginScreen` State，只改变 surface/config notifier 后 pump，不能销毁并重建页面来伪造“焦点和内容不丢”；
- fake discovery 和 fake signIn 必须确定完成或抛出，不得留下永不完成的 Future。

关键断言不能只检查 `tester.takeException() == null`。必须使用字段 ValueKey 获取 `tester.getRect()`，同时证明完整焦点字段满足 `field.top >= safeAreaVisibleTop + 8`、`field.bottom > field.top` 和 `field.bottom <= surfaceHeight - logicalInset - 8`。自动滚动测试只能用 `tester.showKeyboard(find.byKey(...))` 聚焦，测试代码不得先调用 `tester.ensureVisible()`，否则会掩盖生产缺陷。

至少覆盖：

1. iPad 横屏代表尺寸 + bottom inset 350–380，依次聚焦三个字段，字段均自动位于键盘上方；
2. 横屏键盘状态下可通过用户式 drag 滚到登录按钮并点击；
3. iPad 竖屏代表尺寸 + bottom inset，字段和按钮可达；
4. 键盘打开并聚焦 password 后横转竖、竖转横，焦点和内容不丢，字段仍可见；
5. 文字缩放 1.0、1.3、2.0，不 overflow、不裁字，允许滚动；
6. 600x500 短视口 + bottom inset 220，进入紧凑头且控件可达；
7. 无键盘时 599/601 高度边界分别进入紧凑/常规头；无 inset/外接键盘路径的 Next/Next/Done 焦点链正确且只提交一次；
8. 拖动 ScrollView 收键盘；
9. 空表单校验在短视口下可访问且不 overflow；
10. 登录错误框在短视口和大文字下可换行、按钮可达；
11. Android 360x640 + 软件键盘 + 至少两个发现服务器，发现和字段均可滚动；
12. Android 常规尺寸无键盘时保持常规视觉和服务器回填；
13. 紧凑模式切换密码显隐不丢焦点、不把字段滚到键盘下；
14. 点击空白处可收键盘；点击发现服务器、密码眼睛和登录按钮不被 tap-outside 处理吞掉；
15. 每组预期滚动动画都用有上限的 pump/pumpAndSettle 收敛，随后 `tester.takeException()` 为 null；测试结束没有由本页新建但未释放的 timer、animation、controller 或 listener。不得对框架全局做笼统的“无 pending animation”断言。
16. 强制滚动路径：选择确定让表单高于可用 viewport 的组合（固定为 600x500、bottom inset 220、文字缩放 2.0）；聚焦前先证明 password 的几何不满足完整可见条件并记录初始 scroll offset；随后只调用 `tester.showKeyboard(passwordKey)`，禁止 drag 和测试侧 ensureVisible；pump 完生产动画后必须证明 scroll offset 已改变且 password 的 top/bottom 均进入可见范围；再触发一次 metrics/旋转变化，证明即时校正仍有效且调度标记没有卡死。

提交信息：`fix: keep iPadOS login controls above keyboard`。

## 12. 阶段 5：完整自动测试矩阵

每个 `fix:` 提交必须同时包含该阶段对应的自动测试，并在提交前通过现有全量测试；不得先堆完生产代码再到最后补测试。本阶段只用于补跨阶段集成路径或审查中发现的覆盖缺口，独立 `test:` 提交是可选项，不得成为推迟阶段测试的理由。

建议新增或扩展：

```text
test/session_store_failure_test.dart
test/app_controller_sign_in_transaction_test.dart
test/login_storage_error_test.dart
test/login_keyboard_layout_test.dart
test/diagnostic_log_redaction_test.dart
test/login_screen_test.dart
test/login_network_error_test.dart
test/platform_capabilities_test.dart
```

测试必须同时覆盖：

- 安全存储 read/write/delete 各阶段错误；
- Keychain missing-entitlement 分类；
- `EmbyApiException` 原分类保持；
- 登录事务提交/回滚/重试/并发；
- 日志脱敏；
- iPad 键盘几何；
- 横竖屏、旋转、较大文字、短视口；
- Android 发现和登录回归；
- entitlement 脚本正向与负向门禁。

禁止：

- 删除既有测试；
- 把严格几何断言改成只看 `takeException`；
- 使用测试侧 ensureVisible 伪造布局成功；
- 放大容差到被键盘遮挡也能通过；
- 因 CI 时序问题直接 skip；
- 更新依赖或锁文件解决与本轮无关的问题。

若确有跨阶段测试需要独立提交，提交信息可为：`test: cover iPadOS real-device remediation paths`。

## 13. 阶段 6：本地与 CI 验证

### 13.1 每个生产代码提交的最低验证

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
bash -n scripts/ios/*.sh
shellcheck scripts/ios/*.sh
```

只改 Dart 且未动脚本的提交仍需在最终阶段执行全部 Shell 门禁。

### 13.2 最终 Android 验证

```bash
flutter build apk --debug
flutter build apk --debug --split-per-abi
```

必须生成：

```text
app-debug.apk
app-armeabi-v7a-debug.apk
app-arm64-v8a-debug.apk
app-x86_64-debug.apk
```

### 13.3 最终 iOS/Actions 门禁

两个 Job 必须成功：

```text
quality-and-android
ios-device-build
```

五类 Artifact 必须存在：

```text
android-debug-apk-<run>
android-debug-split-apks-<run>
ios-core-ipa-<run>
ios-core-dsym-<run>
ios-core-diagnostics-<run>
```

最终 diagnostics 必须证明：

- build HEAD 与 `implementation_code_head` 一致；
- Xcode Runner 输入与 TrollStore 最终身份分开验证；
- `scripts/ios/runner-entitlements.plist`、两个 Xcode 镜像、`scripts/ios/trollstore-entitlements.plist`、resolved plist 和各次 dump 的 SHA-256 均已记录；
- packaged Runner 精确三键；
- embedded entitlement 为空；
- Runner 最后签名；
- 所有 Mach-O 为 arm64；
- Bundle ID、最低系统和 iPad-only 正确；
- 无 `.appex`；
- 两个锁文件无漂移；
- IPA SHA-256 与同一 Artifact 中的 `.ipa.sha256` 及 diagnostics 记录一致；Gate B 通过后再由阶段 8 把该值写入实现报告；
- `.ipa.sha256` 只使用 basename，可直接 `shasum -a 256 -c`。

分支 Actions 全绿只能证明 `REMEDIATION_IMPLEMENTED`，不能证明 `IMPLEMENTATION_COMPLETE` 或 `ACCEPTED`。

## 14. 阶段 7：分支 IPA 真机预验收

必须使用本整改分支最终代码提交对应的新 IPA，不得复用 run 17、run 20 或基线 IPA。

设备所有者先记录：

```text
iPad 型号
iPadOS 版本
TrollStore 版本
分支 HEAD
Actions run URL / run number
IPA 文件名和 SHA-256
覆盖安装还是删除后全新安装
本地网络权限状态
Safari 是否能访问同一 Emby 地址
```

原始照片已经暴露一组 Emby 凭据。开始新一轮真机测试前，设备所有者应自行轮换该密码，并优先创建只具备验收所需权限的专用测试账号。Luna 不得登录服务器、修改账号、索取、保存或记录新密码。

run A 要求全新安装，会由设备所有者主动卸载当前 TrollStore 应用并清除应用沙盒。执行前必须由设备所有者确认当前应用没有需要保留的数据，或已经自行完成必要备份，并明确接受清除；Luna 不得远程卸载、删除数据或替设备所有者作出该决定。

覆盖升级必须使用同一 `implementation_code_head` 的两个递增构建：

```text
run A：触发同一 implementation_code_head 的构建
       → 等待 A 的两个 Job、五类 Artifact 和 checksum 全部完成
run B：A workflow 完整结束后，对同一分支/同一代码 HEAD 再次 workflow_dispatch
       → 等待 B 的两个 Job、五类 Artifact 和 checksum 全部完成
       → 确认 B 的 CFBundleVersion 高于 A

设备所有者：确认备份与清除授权
       → 卸载旧应用并全新安装 A
       → 登录并验证杀进程恢复
       → 不清除数据地覆盖安装 B
       → 验证 Session 连续性
```

必须严格等待 run A 完成后才 dispatch run B，避免同一 ref 的 workflow concurrency 用 `cancel-in-progress` 取消 A。A/B 都必须核对相同 `implementation_code_head`，B 的 CFBundleVersion 必须高于 A；记录两者的 run number、IPA 文件名、SHA-256 和 CFBundleVersion。不得用无法登录的基线 run 20 建立升级前 Session，也不得把同一个 IPA 重装称为覆盖升级验证。

### 14.1 Keychain/登录预验收

1. 全新安装后首次登录成功进入主页；
2. 设备所有者在系统设置中明确撤销本应用的“本地网络”权限，重试登录并验证出现可恢复提示；随后重新允许权限并验证登录成功。若目标 iPadOS 没有可用开关/重置方式，必须 `STOP` 并记录系统版本与现象，不能仅因未弹首次提示而写 `PASS`；
3. 错误密码显示认证错误，不显示安全存储错误；
4. 服务器离线显示网络错误；
5. 正确登录后强制结束应用，再启动可恢复 Session；
6. 退出登录后 Session 被清除；
7. 再次登录成功；
8. 使用上述 run B 覆盖 run A 后 Session 仍可读取；
9. 登录失败不留下半会话，重启后仍在登录页；
10. 诊断日志只出现固定 stage/reason/errorType，不含真实密码、Token、用户名、设备 ID 或完整 URL；
11. 已安装主程序 entitlement dump/重签后日志属于 best-effort 辅助证据；没有 NewTerm/Filza/ldid 条件时不能要求设备所有者越权操作，硬门禁仍是功能性 Keychain 写入、读取、删除、再次登录和覆盖升级；
12. 若可以取得 installed dump，三个核心值必须保持：`application-identifier = TROLLTROLL.com.jsdfhasuh.embyclient`、team identifier = `TROLLTROLL`、Keychain groups = 仅 `[TROLLTROLL.com.jsdfhasuh.embyclient]`；
13. 允许已核对固定 TrollStore 源码后出现 `com.apple.private.security.container-required = com.jsdfhasuh.embyclient`；其他附加键不得自动判定通过或失败，必须记录键和值并核对固定源码；涉及调试、跨应用共享或系统服务权限时立即停止；
14. 证据优先级：已安装主二进制 dump > TrollStore 明确的重签后 dump > 功能性 Keychain 结果；安装前 IPA dump 不得冒充 installed identity。

### 14.2 键盘预验收

1. 横屏依次点击服务器、用户名、密码，当前字段始终完整位于键盘上方；
2. 横屏可滚到登录按钮并点击；
3. 竖屏重复；
4. 键盘打开并聚焦 password 时横转竖、竖转横，焦点和输入内容不丢；
5. Next/Next/Done 顺序正确；
6. 密码显隐不跳屏；
7. 拖动页面可收键盘，收起后不残留巨大空白；
8. 系统文字调大至少一档后重复横屏，允许滚动但不截断；
9. 若设备支持浮动/分离键盘或外接键盘，至少验证一轮；
10. 登录错误框和现有登录按钮（作为重试入口）在键盘场景可访问；不得为本轮新增独立重试按钮。

Gate B 的机械判定规则：

- 14.1 的 1–10 全部是硬门禁，必须逐项 `PASS`；11–14 是辅助 entitlement 证据，其中 11 明确为 best-effort，但一旦取得 12–14 的证据且发现身份不一致，必须 `STOP`；
- 14.2 的 1–8、10 全部是硬门禁，必须逐项 `PASS`；第 9 项仅在设备实际支持相应键盘形态时执行，不支持时记录 `NOT_APPLICABLE`，不得写 `PASS`；
- 任一硬门禁为 `FAIL` 或 `NOT_TESTED`，Gate B 都不得通过；`NOT_TESTED` 不等于 `PASS`。

任一项失败：

- 保持 `IMPLEMENTATION_IN_PROGRESS` / `NOT_ACCEPTED`；
- 记录准确复现步骤、方向、焦点字段、文字大小、IPA SHA 和脱敏诊断码；
- 停止合并；
- Luna 不得自行宣布“基本通过”。

只有登录、Session 恢复、退出清理和键盘预验收全部通过，分支代码才可恢复声明：

```text
IMPLEMENTATION_COMPLETE
NOT_ACCEPTED
```

### 14.3 STOP GATE B：等待设备所有者预验收

Luna 生成 run A/run B、核验 Artifact 并汇报后必须再次停止。只有设备所有者可以执行 14.1、14.2 并返回逐项结果：

- 任一硬门禁失败或未测试：保持 `IMPLEMENTATION_IN_PROGRESS` / `NOT_ACCEPTED`，Luna 只记录脱敏失败证据并等待新决策；
- 所有硬门禁通过：设备所有者明确要求继续后，Luna 才可进入阶段 8 回填证据；
- Luna 不得把“未收到反馈”“自动测试通过”或安装前 entitlement dump写成真机 `PASS`。

## 15. 阶段 8：文档证据回填

分支真机预验收通过后：

- 更新实现报告，保留历史 run 17，并在独立核验后记录 main 基线 run 20；不得把未核验文件名写成事实；
- 在仓库内实现报告记录 `implementation_code_head`（真机 IPA 对应代码）和 `evidence_content_parent`（创建证据文档提交前的父提交 SHA）；不得要求文档预先写入包含自身的 `evidence_doc_head`；
- 新增整改代码 Actions run、A/B 两个真机 IPA run、五类 Artifact、测试总数、IPA SHA、entitlement 候选策略和真机预验收结果；
- 记录实际使用的 TrollStore 版本，以及实施阶段核对的 TrollStore 固定上游 commit；
- 记录两个 entitlement 人工策略源、resolved 文件和最终 dump 的 SHA-256；
- 在已知限制中说明精确 `TROLLTROLL.com.jsdfhasuh.embyclient` 组只缩小意外共享，不提供正式 Apple 签名体系下不可冒充的开发者隔离；
- 明确区分 `packaged_entitlement`、`installed_effective_identity` 和 `functional_keychain_result`；
- 更新验收表，只填写设备所有者实际执行项目；
- 把本次旧 FAIL 保留为历史记录，再记录新构建复测结果；
- 不删除失败历史，不用新结果覆盖复现信息；
- 状态最多为 `IMPLEMENTATION_COMPLETE` / `NOT_ACCEPTED`；
- 不更新 README 宣称已支持 iPadOS。

证据文档提交会产生新的 `evidence_doc_head` 并再次触发 Actions。该 docs-only HEAD 的两个 Job仍必须全绿；其提交 SHA、Actions run URL/number 和结果只记录在 Luna 最终汇报或未来 PR 描述中，**不得再追加一个回填自身 SHA/run 的提交**。实现报告不得用旧 code-head run冒充 doc-head run，也不得因 docs-only commit 否定已经与 `implementation_code_head` 精确对应的真机结果。

提交信息：`docs: record iPadOS remediation evidence`。

## 16. 合并门禁与 main 最终验收

Luna 不得自行合并。本整改实施任务的终点是“请求合并并停止”；修改或推送 `main` 属于计划之外的独立集成任务，只能由设备所有者在未来另一个明确授权的 turn/agent 中执行。满足以下条件后，Luna 只可以请求设备所有者/审查者决定：

- 所有 P0/P1 项完成；
- 分支最终 HEAD 的工作区干净；
- format、analyze、全量测试、ShellCheck、bash -n、Android 双构建全部通过；
- 分支最终 HEAD 的两个 Actions Job 成功；
- 五类 Artifact 完整；
- IPA/diagnostics 门禁完整；
- 分支新 IPA 的登录、Session/Keychain 和键盘预验收通过；
- 实现报告和验收记录准确；
- 未修改范围外功能；
- 分支未落后 main，或已经按审查者指示安全同步并重新验证。

未来独立集成任务取得明确授权后，才可以：

1. 以允许的快进/PR方式合并到 `main`；
2. 等待 `main` 新 HEAD 的完整 Actions；
3. 下载 `main` 新生成的 IPA、SHA、dSYM 和 diagnostics；
4. 使用 `main` IPA 完成上位 Goal 的**全部**真机清单；
5. 由设备所有者填写最终结果。

分支 IPA 只能用于预验收，不能成为最终 `ACCEPTED` 依据。

## 17. 建议提交顺序

必须保持可审查的小提交，建议顺序：

1. `docs: record iPadOS real-device remediation state`
2. `ci: build iPadOS real-device remediation branch`
3. `fix: classify iPadOS sign-in failures safely`（同提交包含阶段 1 测试）
4. **STOP GATE A：推送、等待 Actions、交付诊断 IPA并停止；等待设备所有者返回 stage/reason 和继续指令**
5. 若且仅若 Gate A 命中 missing-entitlement 分流：`fix: establish minimal TrollStore keychain identity`（同提交包含脚本测试）；否则停止并修订计划，不执行此提交
6. `fix: keep sign-in session activation atomic`（同提交包含事务测试）
7. `fix: keep iPadOS login controls above keyboard`（同提交包含键盘测试）
8. 可选：`test: cover iPadOS real-device remediation paths`，仅补跨阶段覆盖缺口
9. 完成最终代码 HEAD 的全量本地/Actions/Artifact 验证，生成同代码 HEAD 的 run A/run B
10. **STOP GATE B：交付两个 IPA并停止；等待设备所有者完成分支真机预验收**
11. Gate B 全部通过并收到继续指令后：`docs: record iPadOS remediation evidence`
12. 验证纯文档最终 HEAD 的 Actions 全绿，请求独立集成任务并停止

若某阶段代码和对应测试不可安全拆分，允许同一提交同时包含该阶段测试，但禁止把 Keychain、事务、键盘和文档全部压成一个巨大提交。

## 18. Luna 明确禁止事项

Luna 不得：

- 把 AccessToken、密码或完整 Session 写入 SharedPreferences、普通文件、SQLite 或日志；
- 因 Keychain 失败自动回退明文存储；
- 把当前高度可疑根因直接写成已确认事实；
- 继续让最终 TrollStore Runner 使用空 Keychain 数组；
- 使用 `TROLLTROLL.*`、`com.apple.token`、`get-task-allow` 或其他宽权限 entitlement；
- 把 TrollStore 假 Team ID 写入普通 Xcode Runner entitlement；
- 给 Framework/dylib 复制 Runner entitlement；
- 记录 `PlatformException.message/details`、Dio 原始请求、密码、Token、用户名、deviceId 或完整 URL；
- 吞掉错误后仍设置 `isSignedIn = true`；
- 登录失败后保留半写入 Session；
- 用固定 padding、固定滚动距离或固定设备型号修键盘；
- 设置 `resizeToAvoidBottomInset: false` 后宣称已解决；
- 对 Scaffold 和内容同时叠加完整 keyboard inset；
- 锁定屏幕方向、删除品牌区、删除服务器发现、删除字段或隐藏登录按钮；
- 禁止文字缩放或用裁剪掩盖 overflow；
- 用测试侧 `ensureVisible()`、弱化几何断言或 skip 测试伪造通过；
- 未经审查者批准删除既有测试或让总测试数下降；
- 升级依赖、Flutter、Dart、CocoaPods 或 ldid；
- 修改锁文件；
- 使用旧 run/旧 IPA 证明新代码；
- 把安装前 IPA entitlement dump 冒充安装后的有效身份；
- 看到分支没有自动 Actions 时谎报成功；
- 提交含明文密码的原始照片；
- 修改、合并或推送 `main`；
- 代替设备所有者填写真机 `PASS`；
- 在全部完成前声明 `ACCEPTED`。

## 19. Luna 最终汇报格式

Luna 完成分支实现后必须一次性汇报：

1. 分支名、`implementation_code_head` 和 `evidence_doc_head`；若尚未到 Gate B 后的文档阶段则明确写 `evidence_doc_head = NOT_CREATED`；
2. 相对基线的全部提交 SHA/信息；
3. 修改文件列表，按登录诊断、Keychain、事务、键盘、测试、CI、文档分类；
4. 根因状态：`SUSPECTED_ROOT_CAUSE` 或 `CONFIRMED_ROOT_CAUSE`，以及支持证据；
5. Runner 的 Xcode 输入 entitlement，以及 `scripts/ios/runner-entitlements.plist` 和两个镜像的 SHA-256；
6. TrollStore source/resolved/fakesign/final IPA entitlement 的准确键和值，以及 `scripts/ios/trollstore-entitlements.plist`、resolved 文件和各 dump 的 SHA-256；
7. embedded Mach-O 数量、entitlement 和签名顺序；
8. 新增测试及全量测试总数；
9. format、analyze、git diff check、bash -n、ShellCheck 结果；
10. Android 普通/三个分 ABI APK 结果；
11. Actions run URL、run number、两个 Job 状态；
12. 五类 Artifact 的准确名称；
13. IPA 文件名、SHA-256、便携校验结果；
14. Bundle ID、iOS 13、iPad-only、arm64、无 `.appex`、锁文件证据；
15. Gate A 的实际 stage/reason 分流，以及 Gate B 的 run A/run B、CFBundleVersion 和设备所有者逐项结果；尚未执行的 Gate 必须写 `WAITING_FOR_DEVICE_OWNER`，不得省略；
16. 已知限制与仍需设备所有者执行的真机步骤；
17. 明确写出：`没有代填真机 PASS，没有合并 main，没有声明 ACCEPTED`。

若任何门禁失败，汇报必须包含失败命令、最小错误摘要、是否产生 Artifact、当前安全状态和下一步需要的真实设备/审查者决定；不得只回复“未完成”。

## 20. 完成定义

### 20.1 `REMEDIATION_IMPLEMENTED`

仅表示代码、自动测试、打包门禁、Android 回归和分支 Actions 已完成，不包含真实设备结论。

### 20.2 恢复 `IMPLEMENTATION_COMPLETE`

必须同时满足：

- `REMEDIATION_IMPLEMENTED`；
- 分支新 IPA 在目标 iPad/TrollStore 上成功登录；
- Session 写入、杀进程恢复、退出清理和覆盖安装连续性通过；
- iPad 横/竖屏、旋转、较大文字和键盘可达性通过；
- 设备所有者已把真实结果写入验收记录；
- 没有未解决的 P0/P1 阻塞。

### 20.3 `ACCEPTED`

必须使用合并后 `main` 新 HEAD 生成的 IPA，完成上位 Goal 的全部真机验收。只有设备所有者可以确认。任何登录、Keychain、键盘、媒体库、播放、下载或恢复硬性项目失败时，继续保持 `NOT_ACCEPTED`。
