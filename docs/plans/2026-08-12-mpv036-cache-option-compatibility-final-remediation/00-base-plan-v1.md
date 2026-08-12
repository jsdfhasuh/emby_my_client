# 2026-08-12 mpv 0.36 缓存兼容、运行证据与跨来源 Seek 收口计划

## 0. 文档状态

```text
plan_status = READY_FOR_IMPLEMENTATION
repository = jsdfhasuh/emby_my_client
implementation_branch = agent/ios-core-real-device-remediation
code_baseline = 705b1e0fab7b0d25d8372fa0cbcb1cf0bade9988
implementation_start_head = BRANCH_HEAD_AFTER_THIS_PLAN_COMMIT

AUTOMATED_SEEK_STABILITY_GATE = PASSED
STOP_GATE_SEEK_STABILITY = WAITING_FOR_DEVICE_OWNER
STOP_GATE_CACHE_OPTION_ALIAS = NOT_RUN
STOP_GATE_MEMORY_CACHE_PROFILE = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_CACHE_TELEMETRY = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_CACHE_LOG_OBSERVATION = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_CACHE_SESSION_SUMMARY = BLOCKED_BY_IMPLEMENTATION
STOP_GATE_DISK_CACHE_CAPABILITY = BLOCKED_BY_OPTION_ALIAS_COMPATIBILITY
STOP_GATE_B = BLOCKED_BY_IMPLEMENTATION
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

本计划是对既有自适应缓存与 Seek 稳定性实现的聚焦收口，不重写已经完成的架构。

Run 86/87 仅作为本计划实施前的历史候选。任何生产代码或文档变化后，必须重新生成同一新 HEAD 的 Actions A/B。

---

## 1. 当前已完成能力

以下内容必须保留，不得推倒或弱化：

```text
Seek single-flight / latest-wins
100 次请求仅执行首个与最终目标
相对 Seek 累积
PlaybackItemSessionId
自动 open 总预算
recoveryPending / recovering
Seek 后有界恢复
PlaybackSettingsRepository
缓存目录 marker / probe / 安全清理
动态空间与码率 Profile
前后 metadata 预算
低空间与内存压力保护
设置页面与临时验收覆盖
安全诊断和完整诊断导出
```

本轮只处理：

1. mpv 0.36 旧缓存选项名称兼容；
2. 磁盘、内存、disabled Profile 的独立能力与 read-back；
3. 当前真实播放 mpv context 的结构化缓存 telemetry；
4. 跨来源 Seek 结果导致的 UI 旧位置回退；
5. 新增 `playback_cache_observation`；
6. 新增 `playback_cache_session_summary`；
7. 重新定义缓存诊断与 Gate B 证据标准。

---

## 2. Git、安全与范围边界

实施前必须记录：

```text
git branch --show-current
git rev-parse HEAD
git rev-parse @{upstream}
git status --short
```

工作区允许存在：

```text
?? docs/test/
```

该目录属于用户文件：

- 不得修改；
- 不得暂存；
- 不得提交；
- 不得移动；
- 不得删除；
- 不得执行 `git clean`；
- 不得使用 `git add -A`。

禁止：

```text
git reset --hard
git rebase
git push --force
git commit --amend
修改或合并 main
推送 main
删除、skip 或弱化既有测试
```

本轮不得修改：

```text
pubspec.yaml
pubspec.lock
ios/Podfile.lock
ios/Runner/Info.plist
所有 entitlement
Bundle ID
MinimumOSVersion
TrollStore 三键身份
安全登录诊断 schema
完整诊断导出安全边界
```

不得新增第三方依赖，不得升级 media_kit、libmpv、Flutter、Dart、Xcode 或 CocoaPods。

本轮不做：

```text
跨播放持久化媒体缓存
本地 HTTP Range 分片代理
离线下载替代
修改 Emby 服务端或反向代理
UDP 发现
投屏协议
```

---

## 3. K0：冻结真实实施基线

本文档提交后，执行者必须以分支远端最新 HEAD 作为精确 `implementation_start_head`，不得回退到 `code_baseline`。

实施报告必须记录：

```text
implementation_start_head
implementation_code_head
首个生产提交 parent
main / origin/main
docs/test/ 状态
Flutter 测试基线 = 757
```

状态：

```text
STOP_GATE_B = BLOCKED_BY_IMPLEMENTATION
```

---

## 4. K1：mpv 缓存选项逻辑绑定与版本兼容

### 4.1 业务层只使用逻辑选项

新增：

```dart
enum PlaybackCacheLogicalOption {
  cache,
  cacheOnDisk,
  cacheDirectory,
  cacheUnlinkFiles,
  cacheSeconds,
  forwardMetadataBytes,
  backwardMetadataBytes,
  donateBuffer,
  seekableCache,
  cachePause,
  cachePauseWait,
  streamBufferSize,
}
```

新增：

```dart
class ResolvedPlaybackCacheOptionBindings {
  final Map<PlaybackCacheLogicalOption, String> nativeNames;
  final Map<PlaybackCacheLogicalOption, String> resetValues;
  final Set<PlaybackCacheLogicalOption> supported;
  final Set<PlaybackCacheLogicalOption> optionalTuningUnavailable;
}
```

业务代码不得再次直接硬编码版本相关目录和 unlink 名称。

### 4.2 候选别名

```text
cacheDirectory：
1. demuxer-cache-dir
2. cache-dir

cacheUnlinkFiles：
1. demuxer-cache-unlink-files
2. cache-unlink-files
```

规则：

- 新旧名称同时存在时优先 modern 名称；
- 仅 legacy 名称存在时使用 legacy；
- choices、default/reset、Profile write、read-back 和原生能力 manifest 必须使用同一个已解析 native name；
- 不得从 mpv 版本字符串直接猜选项名称；
- Swift 原生 probe、Dart probe、Android native smoke 使用同一候选表与同一判定规则。

### 4.3 安全诊断字段

只记录：

```text
cacheDirectoryVariant = modern / legacy / unavailable
cacheUnlinkVariant = modern / legacy / unavailable
```

不得记录实际路径、完整 option 输出或任意未知原生字符串。

### 4.4 K1 Gate

```text
STOP_GATE_CACHE_OPTION_ALIAS = PASSED
```

要求：

- 每个逻辑选项已解析到唯一实际名称或明确 unavailable；
- unlink choices 使用选中的实际名称读取；
- `immediate` 是否存在有原生证据；
- reset 证据与实际名称一致；
- 不得再把名称兼容假阴性当成底层能力缺失。

若 modern 与 legacy 都不存在，记录真实 blocked，不得猜测。

---

## 5. K2：拆分磁盘、内存、disabled 与可选调优能力

### 5.1 核心能力集合

#### 磁盘 Profile 必需

```text
cache
cache-on-disk
cacheDirectory 任一兼容名称
cacheUnlinkFiles 任一兼容名称
cache-secs
demuxer-max-bytes
demuxer-max-back-bytes
immediate unlink choice
active-player demuxer-cache-state telemetry
```

#### 内存 Profile 必需

```text
cache
cache-on-disk
cache-secs
demuxer-max-bytes
demuxer-max-back-bytes
```

内存模式不得依赖目录和 unlink 选项。

若目录或 unlink 选项存在，可以在内存 Profile 中安全 reset；不存在则跳过，不得导致整个内存 Profile 应用失败。

#### Disabled / 离线 Profile 必需

```text
cache
```

若支持 `cache-on-disk`，显式写入 `no`。

#### 可选调优

```text
demuxer-donate-buffer
demuxer-seekable-cache
cache-pause
cache-pause-wait
stream-buffer-size
```

可选项缺失或 read-back 不一致时：

```text
核心 Profile 仍可成功
记录 optionalTuningDegraded
不得关闭整个磁盘或内存 Profile
```

### 5.2 Apply Plan

新增：

```dart
class PlaybackCacheProfileApplyPlan {
  final Map<String, String> criticalValues;
  final Map<String, String> optionalValues;
  final Set<String> criticalReadBack;
  final Set<String> optionalReadBack;
}
```

关键字段失败：

```text
actualMode = unconfirmed
对应 Profile Gate = BLOCKED
```

可选字段失败：

```text
actualMode 保持已确认模式
optionalTuningDegraded = true
```

### 5.3 内存 Profile 硬验收

必须通过原生 read-back 证明：

```text
cache = yes
cache-on-disk = no
```

只有满足时才能：

```text
cacheEvidence = memoryProfileConfirmed
STOP_GATE_MEMORY_CACHE_PROFILE = PASSED
```

不得仅根据 Dart 模型中的 `memoryFallback` 宣称内存缓存已应用。

---

## 6. K3：当前真实播放 mpv context 的结构化 telemetry

### 6.1 新增抽象

```dart
abstract interface class PlaybackCacheTelemetryReader {
  Future<PlaybackNativeValue<PlaybackCacheNativeState>>
  readDemuxerCacheState();
}
```

```dart
class PlaybackCacheNativeState {
  final int? fileCacheBytes;
  final int? rawInputRateBytesPerSecond;
  final List<PlaybackCacheRange> seekableRanges;
  final bool? pausedForCache;
  final int? bufferingPercent;
  final bool? cacheOnDisk;
}
```

### 6.2 读取规则

首选：

```text
从当前正在播放的 mpv context 使用 MPV_FORMAT_NODE 读取 demuxer-cache-state
```

只有在真实 iPadOS 和 Android 集成测试证明 `NativePlayer.getProperty` 稳定返回可解析 JSON 时，才允许保留 JSON 字符串适配。

禁止：

```text
解析 Map.toString()
正则解析调试文本
依赖日志格式
使用独立 probe context 的状态冒充当前播放 context
```

### 6.3 可用性语义

必须区分：

```text
available
fieldTemporarilyAbsent
unsupported
readFailed
```

`raw-input-rate` 暂时缺失不能自动判成不支持；`file-cache-bytes` 在非磁盘模式缺失也不能判成异常。

### 6.4 K3 Gate

```text
STOP_GATE_CACHE_TELEMETRY = PASSED
```

要求在当前真实播放 context 中能安全取得：

- `cache-on-disk`；
- `file-cache-bytes`；
- `seekable-ranges`；
- `raw-input-rate` 的可用/暂缺状态。

---

## 7. K4：统一所有 Seek 来源的 UI 请求所有权

### 7.1 全局 UI Seek token

在 PlayerScreen 中新增：

```dart
int _uiSeekRequestGeneration = 0;
```

所有用户或远程来源通过统一入口：

```dart
Future<SeekResult?> _submitUiSeek(...)
```

覆盖：

```text
横向拖动
进度条
双击
章节
跳过片头
远程绝对 Seek
远程快进/后退
```

### 7.2 回写规则

```text
executed
→ 使用 committedPosition

superseded
→ 不回退，等待最新 requested/committed 状态

cancelled
→ 不回退

failed 且仍为最新 token
→ 使用 controller.state.displayPosition
→ 可显示固定安全提示
```

禁止：

```text
非 executed
→ 无条件恢复该请求自己的 startPosition
```

横向拖动和进度条只管理 preview；提交后完全交还 Controller 的：

```text
requestedPosition → committedPosition
```

---

## 8. K5：缓存诊断证据闭环

本阶段必须新增两个固定事件：

```text
playback_cache_observation
playback_cache_session_summary
```

它们必须进入普通 DiagnosticLog，因此完整诊断导出可以直接包含这些证据。

### 8.1 通用证据枚举

```text
cacheEvidence =
  diskDataObserved
  diskConfiguredOnly
  memoryProfileConfirmed
  disabled
  unconfirmed
```

判定：

#### `diskDataObserved`

只有同时满足：

```text
confirmedMode = disk
cacheOnDisk = true
telemetryAvailable = true
file-cache-bytes > 0
```

#### `diskConfiguredOnly`

```text
confirmedMode = disk
cacheOnDisk = true
file-cache-bytes = 0 或 unavailable
```

该状态不能作为磁盘数据实际增长的 PASS 证据。

#### `memoryProfileConfirmed`

只有原生 read-back 确认：

```text
cache = yes
cache-on-disk = no
```

#### `disabled`

原生 read-back 确认缓存关闭。

#### `unconfirmed`

关键证据缺失、冲突或 read-back 不完整时使用。不得由目标 Profile、设置页状态或错误日志自行推断成功。

---

## 9. 事件一：`playback_cache_observation`

### 9.1 目的

运行期间回答：

```text
缓存实际模式
telemetry 是否可用
磁盘缓存是否真的出现非零数据
当前实际前向/后向范围
fallback 是否变化
```

### 9.2 触发时机

只在以下变化发生时记录：

```text
播放器 ready 后首次取得有效 snapshot
telemetry unavailable ↔ available
confirmedMode 变化
cache-on-disk unknown / true / false 变化
file-cache-bytes 0 → 非 0
file-cache-bytes bucket 变化
actual forward bucket 变化
actual backward bucket 变化
fallbackReason 变化
cacheEvidence 变化
```

禁止每秒无条件写日志。

### 9.3 频率与去重

```text
模式变化、telemetry 可用性、0→非0：立即记录
容量/时长 bucket 变化：同一 Session 最短间隔 5 秒
字段完全相同：不得重复记录
定时采样不得一对一生成日志
```

### 9.4 固定字段

```text
event=playback_cache_observation
requestedMode=disk|memory|disabled
confirmedMode=disk|memory|memoryFallback|disabled|unconfirmed
cacheEvidence=diskDataObserved|diskConfiguredOnly|memoryProfileConfirmed|disabled|unconfirmed
telemetryAvailable=true|false
cacheOnDisk=true|false|unknown
fileCacheBytes=unavailable|zero|lte16MiB|lte64MiB|lte256MiB|lte512MiB|lte1GiB|gt1GiB
actualForward=unavailable|zero|lte30s|lte60s|lte180s|lte300s|gt300s
actualBackward=unavailable|zero|lte30s|lte60s|lte120s|lte300s|gt300s
fallbackReason=<固定枚举>
testOverrideActive=true|false
```

`fallbackReason` 只允许：

```text
none
engineCapabilityUnavailable
directoryUnavailable
storageCapacityUnknown
mpvCacheCreateFailed
actualModeUnconfirmed
targetTooSmallForMinimumWindow
metadataBudgetLimited
sessionBudgetReached
lowSpace
memoryPressure
```

### 9.5 运行聚合器

新增 Session 级聚合器，例如：

```dart
class PlaybackCacheEvidenceAccumulator {
  bool telemetryAvailableEver;
  bool observedNonZeroFileCache;
  int? peakFileCacheBytes;
  Duration? maxActualForward;
  Duration? maxActualBackward;
  bool cacheCreateFailedObserved;
  bool cacheSnapshotUnavailableObserved;
  PlaybackCacheSafetyReason? safetyReopenReason;
  PlaybackCacheEvidence lastEvidence;
}
```

聚合器绑定 `PlaybackItemSessionId`，内部重开和 Player 重建不得重置。

### 9.6 Observation Gate

```text
STOP_GATE_CACHE_LOG_OBSERVATION = PASSED
```

要求：

- 首个有效 snapshot 能写入 observation；
- 同一 bucket 不刷屏；
- 0→非0 能立即捕获；
- `diskConfiguredOnly` 与 `diskDataObserved` 可区分；
- `memoryProfileConfirmed` 有 read-back；
- `unconfirmed` 不会被误判成功。

---

## 10. 事件二：`playback_cache_session_summary`

### 10.1 目的

在一次 `PlaybackItemSessionId` 最终结束时，给出完整缓存证据总结。

### 10.2 触发路径

每个 Session 最多且必须记录一次，覆盖：

```text
用户返回
自然播放结束
远程 stop
播放最终失败
切换上一媒体
切换下一媒体
播放器路由关闭
```

以下内部操作不得产生 summary：

```text
Seek
码率重配置
音轨/字幕切换
缓存安全重开
同方法恢复
force-transcode 恢复
同一媒体底层 Player 重建
```

### 10.3 记录顺序

```text
停止 cache monitor
→ 停止当前媒体
→ reporter stop/cleanup 完成或超时
→ cache session cleanup 完成或超时
→ 汇总缓存和 Seek 统计
→ 写 playback_cache_session_summary
→ flush Seek 聚合
→ 完成 item switch 或路由退出
```

cleanup 失败或超时也必须写 summary。

### 10.4 幂等性

新增：

```text
summaryWrittenByPlaybackItemSessionId
```

`shutdown`、`dispose`、route close 和 item switch 多次进入时，summary 仍精确一条。

### 10.5 固定字段

```text
event=playback_cache_session_summary
requestedMode=disk|memory|disabled
finalConfirmedMode=disk|memory|memoryFallback|disabled|unconfirmed
cacheEvidence=diskDataObserved|diskConfiguredOnly|memoryProfileConfirmed|disabled|unconfirmed
telemetryAvailableEver=true|false
observedNonZeroFileCache=true|false
peakFileCacheBytes=unavailable|zero|lte16MiB|lte64MiB|lte256MiB|lte512MiB|lte1GiB|gt1GiB
maxActualForward=unavailable|zero|lte30s|lte60s|lte180s|lte300s|gt300s
maxActualBackward=unavailable|zero|lte30s|lte60s|lte120s|lte300s|gt300s
cacheCreateFailedObserved=true|false
cacheSnapshotUnavailableObserved=true|false
safetyReopenReason=none|budget|lowSpace|memoryPressure
runtimeRecovery=notAttempted|succeeded|failed|cancelled
cleanupResult=success|failed|timeout|notApplicable
seekRequestedCount=<非负整数>
seekExecutedCount=<非负整数>
seekSupersededCount=<非负整数>
seekFailedCount=<非负整数>
seekCancelledCount=<非负整数>
testOverrideUsed=true|false
```

### 10.6 崩溃边界

系统直接终止进程时不能保证 summary 写出。

下次启动只允许记录：

```text
playback_cache_stale_cleanup
```

不得伪造上一 Session 的 summary。

### 10.7 Summary Gate

```text
STOP_GATE_CACHE_SESSION_SUMMARY = PASSED
```

要求：

- 所有正常终止路径精确一条；
- 内部重开不重复；
- cleanup 结果可见；
- 峰值缓存与最大前后范围可见；
- Seek 聚合数正确；
- 安全扫描通过。

---

## 11. 日志安全

两个事件只允许：

```text
固定事件名
固定枚举
布尔值
容量 bucket
时长 bucket
非敏感计数
```

禁止包含：

```text
服务器 URL
媒体 URL
用户名
密码
Token
设备 ID
媒体名称
itemId
缓存完整路径
真实缓存文件名
Authorization
```

完整诊断导出安全扫描必须覆盖两个新事件。

---

## 12. K6：测试矩阵

当前 Flutter 基线：

```text
757 passed
0 skipped
```

最终必须高于 757。

### 12.1 Alias

```text
仅 modern → modern
仅 legacy → legacy
modern + legacy → modern
均不存在 → unavailable
```

choices、reset、write、read-back 使用同一实际名称。

### 12.2 Profile

```text
legacy alias + immediate → diskProfileSupported=true
目录/unlink 缺失 → disk=false、memory=true
stream-buffer-size 缺失 → 核心磁盘 Profile 仍可成功
cache-pause-wait 缺失 → optional tuning degraded
```

### 12.3 内存 read-back

```text
目录/unlink 都不存在
→ 仍写 cache=yes
→ 仍写 cache-on-disk=no
→ actualMode=memory 或 memoryFallback
→ cacheEvidence=memoryProfileConfirmed
```

### 12.4 Telemetry

覆盖：

```text
原生 Node map
空 ranges
重叠 ranges
file-cache-bytes 暂缺
raw-input-rate 暂缺
字段类型异常
媒体未打开
read timeout
```

### 12.5 跨来源 UI Seek

```text
横向 A → 远程 B → A superseded → UI 最终为 B
进度条 A → 双击 B → A 不回退
横向 A → 章节 B → A 不覆盖
route close → 旧结果不回写
```

### 12.6 Observation

```text
首次有效 snapshot → 1 条
0→非0 → diskDataObserved
同 bucket 100 次采样 → 不重复
bucket 变化 → 1 条新事件
telemetry 状态变化 → 记录
unconfirmed → cacheEvidence=unconfirmed
```

### 12.7 Summary

```text
user back / completed / error / remote stop / next item
→ 各 Session 精确 1 条

内部重开 / runtime recovery
→ 不增加 summary

重复 shutdown/dispose
→ 仍精确 1 条

cleanup success/failed/timeout
→ 正确记录

100 Seek 聚合数正确
```

### 12.8 安全

两个事件序列化后必须通过现有敏感内容扫描。

### 12.9 回归

继续通过：

```text
100 Seek → 2 次 engine.seek
relative +100 秒
runtime recovery
automatic open <= 6
设置 Repository
缓存 marker/probe
低空间
内存压力
登录 / Keychain
方向恢复
图片与媒体库
诊断导出
Android APK
```

---

## 13. 建议提交顺序

```text
fix: resolve legacy mpv playback cache option aliases
fix: apply memory cache independently of disk-only options
feat: read native playback cache telemetry from active mpv
fix: prevent stale cross-source seek UI rollback
feat: record playback cache observations and session summaries
test: close mpv cache compatibility and evidence gates
```

每个生产提交必须同时包含对应测试。

---

## 14. 本地与 CI 门禁

每阶段：

```text
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
```

最终：

```text
for file in scripts/ios/*.sh; do bash -n "$file"; done
shellcheck scripts/ios/*.sh
flutter build apk --debug
flutter build apk --debug --split-per-abi
```

Actions 必须执行：

```text
Flutter 全量测试
Swift XCTest
legacy alias native probe
active-player telemetry test
Android native capability smoke
两个新事件安全测试
entitlement 负向门禁
锁文件门禁
IPA checksum
```

---

## 15. 新 Actions A/B

完成全部代码与测试后：

1. 记录 `implementation_code_head`；
2. 推送当前分支；
3. 等待自动 Run A 完整成功；
4. Run A 完成前不得触发 Run B；
5. Run A 后不得再产生提交；
6. 同一 HEAD 触发一次 `workflow_dispatch`；
7. 等待 Run B 完整成功；
8. 核验同 HEAD、B build > A、五类 Artifact、checksum、arm64、iPad-only、entitlement、签名顺序和锁文件。

---

## 16. 自动化状态判定

### 完整磁盘缓存通过

```text
STOP_GATE_CACHE_OPTION_ALIAS = PASSED
STOP_GATE_MEMORY_CACHE_PROFILE = PASSED
STOP_GATE_CACHE_TELEMETRY = PASSED
STOP_GATE_CACHE_LOG_OBSERVATION = PASSED
STOP_GATE_CACHE_SESSION_SUMMARY = PASSED
STOP_GATE_DISK_CACHE_CAPABILITY = PASSED
AUTOMATED_SEEK_STABILITY_GATE = PASSED
STOP_GATE_SEEK_STABILITY = WAITING_FOR_DEVICE_OWNER
STOP_GATE_B = WAITING_FOR_DEVICE_OWNER
```

### 底层确实不支持磁盘，但内存与证据闭环通过

```text
STOP_GATE_CACHE_OPTION_ALIAS = BLOCKED
STOP_GATE_MEMORY_CACHE_PROFILE = PASSED
STOP_GATE_CACHE_TELEMETRY = PASSED 或 NOT_APPLICABLE_FOR_DISK
STOP_GATE_CACHE_LOG_OBSERVATION = PASSED
STOP_GATE_CACHE_SESSION_SUMMARY = PASSED
STOP_GATE_DISK_CACHE_CAPABILITY = BLOCKED_BY_BUNDLED_LIBMPV
STOP_GATE_SEEK_STABILITY = WAITING_FOR_DEVICE_OWNER
STOP_GATE_B = BLOCKED_BY_DISK_CACHE_CAPABILITY
```

任何 `cacheEvidence=unconfirmed` 都不能作为磁盘或内存缓存成功证据。

---

## 17. 真机验收字段

```text
CACHE_OBSERVATION_EVENT = PASS / FAIL / NOT_SEEN
CACHE_SESSION_SUMMARY_EVENT = PASS / FAIL / NOT_SEEN
CACHE_EVIDENCE = DISK_DATA_OBSERVED / DISK_CONFIGURED_ONLY / MEMORY_PROFILE_CONFIRMED / DISABLED / UNCONFIRMED
NON_ZERO_FILE_CACHE_OBSERVED = PASS / FAIL / UNAVAILABLE
PEAK_FILE_CACHE_BUCKET = ZERO / LTE16_MIB / LTE64_MIB / LTE256_MIB / LTE512_MIB / LTE1_GIB / GT1_GIB / UNAVAILABLE
ACTUAL_FORWARD_RANGE_LOGGED = PASS / FAIL / UNAVAILABLE
ACTUAL_BACKWARD_RANGE_LOGGED = PASS / FAIL / UNAVAILABLE
CACHE_CLEANUP_SUMMARY = PASS / FAIL / TIMEOUT / NOT_APPLICABLE
SEEK_STRESS_100 = PASS / FAIL
POST_PLAYBACK_ORIENTATION_RESTORE = PASS / FAIL
RUN_B_SETTINGS_CONTINUITY = PASS / FAIL
```

### 磁盘缓存实际生效 PASS

完整日志必须同时出现：

```text
playback_cache_observation
cacheEvidence=diskDataObserved
fileCacheBytes != zero/unavailable
```

以及：

```text
playback_cache_session_summary
cacheEvidence=diskDataObserved
observedNonZeroFileCache=true
cleanupResult=success
```

### 仅配置磁盘属性

```text
cacheEvidence=diskConfiguredOnly
```

只能记录“磁盘 Profile 已配置，实际数据增长未确认”。

### 内存缓存 PASS

```text
cacheEvidence=memoryProfileConfirmed
finalConfirmedMode=memory 或 memoryFallback
```

### 无法确认

```text
cacheEvidence=unconfirmed
```

必须记录“缓存实际状态无法确认”。

---

## 18. 最终边界

```text
未进入 LEGACY_IOS_PHASE_8
未修改或合并 main
未提交 docs/test/
未升级依赖
未实现持久化媒体缓存
未实现本地 Range 代理
未代填真机 PASS
未声明 IMPLEMENTATION_COMPLETE
未声明 ACCEPTED
```
