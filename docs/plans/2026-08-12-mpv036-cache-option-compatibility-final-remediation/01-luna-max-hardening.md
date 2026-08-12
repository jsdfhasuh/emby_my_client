# 2026-08-12 mpv 0.36 缓存兼容计划：Luna Max 最终加固与覆盖条款

## 0. 文档作用

本文件是对 `00-base-plan-v1.md` 的最终加固。

规则：

```text
本文件与基础计划冲突时，以本文件为准。
本文件没有覆盖的基础条款继续有效。
执行者必须完成基础计划 K0–K6 以及本文件全部条款。
```

本轮只做聚焦收口，不重写已经完成的：

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

---

## 1. 精确实施起点与远端同步

### 1.1 提示词必须写死精确 HEAD

本文档提交后，设备所有者给 Luna Max 的实施提示词必须包含：

```text
implementation_start_head = <本加固提交后的精确远端 HEAD>
```

不得只写：

```text
BRANCH_HEAD_AFTER_THIS_HARDENING_COMMIT
latest
current branch
```

### 1.2 前置核验必须查询实时远端

执行前必须：

```text
git branch --show-current
git status --short
git remote -v
git ls-remote --heads <tracking-remote> agent/ios-core-real-device-remediation
git fetch <tracking-remote> agent/ios-core-real-device-remediation
git rev-parse HEAD
git rev-parse @{upstream}
```

若本地 HEAD 落后，且工作区除允许的 `?? docs/test/` 外干净，只允许：

```text
git merge --ff-only <tracking-remote>/agent/ios-core-real-device-remediation
```

禁止使用 reset、rebase、强推或普通 merge commit 解决基线不一致。

### 1.3 首个生产提交

```text
首个生产提交 parent
= 实施提示词中的精确 implementation_start_head
```

否则立即停止。

---

## 2. 逻辑选项完整映射表

业务层只能使用逻辑枚举，不得散布版本相关 native 名称。

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

固定映射：

| 逻辑选项 | native 候选，按顺序 |
|---|---|
| `cache` | `cache` |
| `cacheOnDisk` | `cache-on-disk` |
| `cacheDirectory` | `demuxer-cache-dir`, `cache-dir` |
| `cacheUnlinkFiles` | `demuxer-cache-unlink-files`, `cache-unlink-files` |
| `cacheSeconds` | `cache-secs` |
| `forwardMetadataBytes` | `demuxer-max-bytes` |
| `backwardMetadataBytes` | `demuxer-max-back-bytes` |
| `donateBuffer` | `demuxer-donate-buffer` |
| `seekableCache` | `demuxer-seekable-cache` |
| `cachePause` | `cache-pause` |
| `cachePauseWait` | `cache-pause-wait` |
| `streamBufferSize` | `stream-buffer-size` |

Swift、Dart 与 Android native smoke 必须从同一个固定规范生成或镜像该表；测试必须断言三端候选表一致。

---

## 3. Alias 选择：首个“完整可用”候选，而非首个“存在”候选

### 3.1 统一候选结果

```dart
enum PlaybackNativeOptionCandidateStatus {
  unavailable,
  presentButIncomplete,
  usable,
}

class PlaybackNativeOptionCandidateEvidence {
  final String nativeName;
  final PlaybackNativeOptionCandidateStatus status;
  final bool optionExists;
  final bool resetAvailable;
  final bool requiredChoiceAvailable;
  final bool writeReadBackPassed;
}
```

### 3.2 `cacheDirectory` 候选可用条件

候选只有同时满足以下条件才是 `usable`：

```text
option-info/<name>/name 精确等于该名称
且 default/reset 值读取成功
且在隔离能力实验或已 stop 的 Player 上写入并 read-back 成功
```

### 3.3 `cacheUnlinkFiles` 候选可用条件

候选只有同时满足以下条件才是 `usable`：

```text
option 存在
且 option-info/<name>/choices 明确包含 immediate
且 default/reset 值读取成功
且写入 immediate 后 read-back 成功
```

### 3.4 选择算法

```text
按候选顺序逐个验证完整条件
→ 选择第一个 usable 候选

modern 仅“存在”但 reset、choice 或 read-back 不完整
→ 标记 presentButIncomplete
→ 必须继续尝试 legacy

所有候选都不是 usable
→ 逻辑选项 unavailable
```

禁止：

```text
modern 名称存在
→ 立即选择 modern
→ 因 reset 不完整直接阻断
→ 不再尝试 legacy
```

### 3.5 安全诊断

只允许记录：

```text
cacheDirectoryVariant=modern|legacy|unavailable
cacheDirectoryModernStatus=unavailable|incomplete|usable
cacheDirectoryLegacyStatus=unavailable|incomplete|usable
cacheUnlinkVariant=modern|legacy|unavailable
cacheUnlinkModernStatus=unavailable|incomplete|usable
cacheUnlinkLegacyStatus=unavailable|incomplete|usable
```

禁止记录完整 option 输出、路径或未知原生字符串。

---

## 4. Native 值统一规范化与等价比较

### 4.1 不允许裸字符串直接比较

新增统一规范化器：

```dart
enum PlaybackNativeValueKind {
  boolean,
  number,
  enumValue,
  path,
  rawString,
}

abstract interface class PlaybackNativeValueCanonicalizer {
  String? canonicalize(
    PlaybackCacheLogicalOption option,
    String raw,
  );
}
```

每个逻辑选项的类型固定：

| 逻辑选项 | 类型 |
|---|---|
| `cache` | boolean/enum，允许 `auto` |
| `cacheOnDisk` | boolean |
| `cacheDirectory` | path |
| `cacheUnlinkFiles` | enum |
| `cacheSeconds` | number |
| `forwardMetadataBytes` | number |
| `backwardMetadataBytes` | number |
| `donateBuffer` | boolean |
| `seekableCache` | enum |
| `cachePause` | boolean |
| `cachePauseWait` | number |
| `streamBufferSize` | number |

### 4.2 Boolean 等价

```text
yes / true / 1 → true
no / false / 0 → false
```

大小写和首尾空格忽略。

### 4.3 Number 等价

以下必须等价：

```text
1 = 1.0
3600000 = 3600000.0
16777216 = 16777216.000
```

要求：

- 只接受有限数；
- 不接受 NaN 或 Infinity；
- 整数型选项比较时，小数部分必须为 0；
- 解析失败时关键字段判失败、可选字段判 degraded。

### 4.4 Enum 等价

```text
trim
→ lowercase
→ 精确比较批准值
```

不得模糊匹配。

### 4.5 Path 等价

路径只用于本机 write/read-back 比较：

```text
统一分隔符
去除多余尾部分隔符
规范化 . 和 ..
必要时比较绝对路径
```

规则：

- 不解析或跟随 symlink 作为等价依据；
- 不将规范化后的完整路径写入日志；
- reset 为空字符串时，只有原生 default-value 明确为空且 read-back 规范化一致才允许；
- 当前平台路径大小写规则由本机文件系统决定，不跨平台硬编码。

### 4.6 测试

必须覆盖：

```text
yes/true/1
no/false/0
1/1.0
空路径 reset
尾部分隔符
modern 与 legacy read-back
非法数值
未知 enum
```

---

## 5. Profile 能力、必需项与可选项

基础计划中的 Profile 拆分继续有效，并补充以下确定规则。

### 5.1 磁盘 Profile 必需逻辑项

```text
cache
cacheOnDisk
cacheDirectory
cacheUnlinkFiles
cacheSeconds
forwardMetadataBytes
backwardMetadataBytes
```

附加硬要求：

```text
cacheUnlinkFiles 的已选候选支持 immediate
active-context telemetry reader 已实现
```

### 5.2 内存 Profile 必需逻辑项

```text
cache
cacheOnDisk
cacheSeconds
forwardMetadataBytes
backwardMetadataBytes
```

内存 Profile 不依赖：

```text
cacheDirectory
cacheUnlinkFiles
```

若目录或 unlink 候选存在且有安全 reset，允许额外 reset；不存在时直接跳过。

### 5.3 Disabled Profile 必需逻辑项

```text
cache
```

若 `cacheOnDisk` 可用，必须额外写 `no` 并 read-back。

### 5.4 可选调优项

```text
donateBuffer
seekableCache
cachePause
cachePauseWait
streamBufferSize
```

任一可选调优项：

```text
不存在
read-back 不一致
写入失败
```

只能：

```text
optionalTuningDegraded=true
```

不能使核心磁盘或内存 Profile 失败。

### 5.5 Apply Plan

```dart
class PlaybackCacheProfileApplyPlan {
  final Map<PlaybackCacheLogicalOption, String> criticalValues;
  final Map<PlaybackCacheLogicalOption, String> optionalValues;
  final Set<PlaybackCacheLogicalOption> criticalReadBack;
  final Set<PlaybackCacheLogicalOption> optionalReadBack;
}
```

Apply 时先通过 bindings 转为 native 名称，再写入。

禁止在 Profile builder 中直接使用：

```text
demuxer-cache-dir
cache-dir
demuxer-cache-unlink-files
cache-unlink-files
```

### 5.6 内存 Profile 成功条件

只有原生 read-back 通过：

```text
cache = yes 或批准的等价启用值
cache-on-disk = no
```

才允许：

```text
cacheEvidence=memoryProfileConfirmed
STOP_GATE_MEMORY_CACHE_PROFILE=PASSED
```

---

## 6. 活动 mpv context 的结构化 telemetry 接入

### 6.1 生产所有权

生产路径必须从当前 `MediaKitPlaybackEngine` 使用的同一 `NativePlayer` 获取活动 mpv handle/context。

流程：

```text
Player
→ player.platform
→ NativePlayer
→ 当前 NativePlayer 的已有 mpv handle/context
→ ActiveMpvTelemetryReader
```

禁止创建第二个 mpv context 来读取当前播放缓存状态。

### 6.2 handle 访问方式

实施者必须先查看锁定版本 `media_kit` 的实际源码和公开接口，确认当前 `NativePlayer` 的 handle 访问方式。

允许：

1. 直接使用该版本公开的稳定 handle；
2. 若没有公开稳定 handle，增加最小范围、受测试的 platform/FFI bridge，把同一 Player 的现有 handle 传给 telemetry reader。

禁止：

```text
创建独立 probe context
通过日志猜状态
通过第二个 Player 冒充当前 Player
```

### 6.3 原生读取

从当前活动 handle 调用：

```text
mpv_get_property(
  context,
  "demuxer-cache-state",
  MPV_FORMAT_NODE,
  &node,
)
```

无论解析成功或失败，必须：

```text
finally → mpv_free_node_contents(&node)
```

Node parser 只接受预期字段：

```text
file-cache-bytes
raw-input-rate
seekable-ranges
cache-duration
reader-pts
```

`cache-on-disk` 可用原生 string/flag read-back补充。

### 6.4 生命周期

每次读取必须捕获：

```text
PlaybackItemSessionId
engine identity
operationGeneration
```

读取结果写回前必须再次验证三者仍有效。

以下时机拒绝新 telemetry：

```text
engine dispose 已开始
Player 正在重建
item switch 已开始
shutdown 已开始
```

迟到结果必须丢弃。

### 6.5 超时与并发

```text
原生 telemetry 读取 timeout = 1 秒
同一 engine 同时最多 1 个 telemetry read
后续轮询 latest-pending 合并
```

超时返回：

```text
telemetryStatus=readFailed
```

不得导致播放失败。

### 6.6 状态语义

```dart
enum PlaybackCacheTelemetryStatus {
  available,
  fieldTemporarilyAbsent,
  unsupported,
  readFailed,
}
```

禁止把四种状态压缩为一个无法诊断的布尔值。

`raw-input-rate` 暂缺可以是 `fieldTemporarilyAbsent`；非磁盘模式下 `file-cache-bytes` 暂缺不自动等于错误。

---

## 7. 确定性 active-context telemetry 测试夹具

### 7.1 禁止公网依赖

Actions 测试不得下载公网媒体或依赖外部 Emby。

### 7.2 测试媒体

使用测试代码确定性生成的无版权 PCM WAV fixture：

```text
固定采样率
固定声道
固定时长
固定 Content-Length
足够产生非零文件缓存
```

fixture 不包含真实媒体或用户数据。

### 7.3 Loopback Range Server

测试内启动 localhost HTTP server，必须支持：

```text
HEAD
GET
Accept-Ranges: bytes
Range 请求
206 Partial Content
Content-Range
固定 Content-Length
固定 ETag
416 非法范围
```

禁止连接公网。

### 7.4 iOS / native 集成流程

```text
创建一个 mpv context 或 app 使用的 Player context
→ 在同一个 context 上设置已解析 Profile
→ 通过 loopback Range server 打开 fixture
→ 等待 ready，最长 10 秒
→ 使用同一个 context 的 MPV_FORMAT_NODE 读取 telemetry
```

这里“测试 context”可以由测试创建，但**读 telemetry 的必须是实际打开 fixture 的同一 context**，不能再创建第二个 context。

### 7.5 磁盘模式通过条件

```text
cache-on-disk 原生 read-back = true
file-cache-bytes 曾经 > 0
seekable-ranges 至少出现一个合法范围
Node 已释放
没有读取泄漏
```

若当前捆绑 libmpv 不具备磁盘能力，则该测试必须得到明确 blocked 证据，不得伪造 PASS。

### 7.6 内存模式通过条件

```text
cache 启用 read-back 成功
cache-on-disk = false
不要求 file-cache-bytes > 0
```

### 7.7 测试层级

```text
Dart 单元测试：
Alias、canonicalizer、bindings、parser、accumulator

Native XCTest：
MPV_FORMAT_NODE、释放、错误码、同 context 读取

活动 Player 集成测试：
loopback Range + 实际打开媒体 + 同 handle telemetry

iPad 真机 Gate：
最终运行证据
```

独立 capability probe 不能替代活动 Player 集成测试。

---

## 8. Gate 语义拆分

基础计划中的旧 Gate：

```text
STOP_GATE_CACHE_OPTION_ALIAS
STOP_GATE_CACHE_TELEMETRY
```

废弃，不得继续输出。

### 8.1 Binding 实现 Gate

```text
STOP_GATE_CACHE_OPTION_BINDING_IMPLEMENTATION
= NOT_RUN | PASSED | BLOCKED_BY_IMPLEMENTATION
```

`PASSED` 表示：

```text
resolver 能确定性地输出 modern / legacy / unavailable
选择首个完整可用候选
三端映射一致
测试通过
```

即使当前 libmpv 最终结果是 `unavailable`，只要判断正确，该实现 Gate 仍应是 `PASSED`。

### 8.2 磁盘能力 Gate

```text
STOP_GATE_DISK_CACHE_CAPABILITY
= NOT_RUN | PASSED | BLOCKED_BY_BUNDLED_LIBMPV
```

`PASSED` 需要：

```text
磁盘 Profile 必需逻辑项全部 usable
immediate unlink 可用
Profile 原生 read-back 通过
```

### 8.3 活动 context reader Gate

```text
STOP_GATE_ACTIVE_CONTEXT_TELEMETRY_READER
= NOT_RUN | PASSED | BLOCKED_BY_IMPLEMENTATION
```

表示：

```text
能从当前播放 context 读取结构化 Node
生命周期和内存释放正确
确定性测试通过
```

它与磁盘是否可用无关。

### 8.4 磁盘 telemetry 证据 Gate

```text
STOP_GATE_DISK_TELEMETRY_EVIDENCE
= NOT_RUN | PASSED | BLOCKED_BY_BUNDLED_LIBMPV | NOT_APPLICABLE
```

判定：

- 磁盘能力 PASS 且活动媒体观察到非零字节与合法 range → `PASSED`；
- 底层无磁盘能力 → `BLOCKED_BY_BUNDLED_LIBMPV`；
- 纯内存测试路径 → `NOT_APPLICABLE`，但不能用于宣称磁盘能力通过。

### 8.5 内存 Profile Gate

```text
STOP_GATE_MEMORY_CACHE_PROFILE
= NOT_RUN | PASSED | BLOCKED_BY_IMPLEMENTATION | BLOCKED_BY_BUNDLED_LIBMPV
```

只有原生 read-back：

```text
cache 启用
cache-on-disk=false
```

才允许 `PASSED`。

### 8.6 日志 Gate

```text
STOP_GATE_CACHE_LOG_OBSERVATION
STOP_GATE_CACHE_SESSION_SUMMARY
```

沿用基础计划，但必须满足本文件的节流与聚合规则。

### 8.7 STOP_GATE_B

完整磁盘缓存路径进入真机 Gate 的条件：

```text
STOP_GATE_CACHE_OPTION_BINDING_IMPLEMENTATION=PASSED
STOP_GATE_MEMORY_CACHE_PROFILE=PASSED
STOP_GATE_ACTIVE_CONTEXT_TELEMETRY_READER=PASSED
STOP_GATE_DISK_CACHE_CAPABILITY=PASSED
STOP_GATE_DISK_TELEMETRY_EVIDENCE=PASSED
STOP_GATE_CACHE_LOG_OBSERVATION=PASSED
STOP_GATE_CACHE_SESSION_SUMMARY=PASSED
AUTOMATED_SEEK_STABILITY_GATE=PASSED
```

若底层真实不支持磁盘：

```text
Binding 实现、内存 Profile、活动 reader、Observation、Summary 和 Seek 仍必须完成
STOP_GATE_DISK_CACHE_CAPABILITY=BLOCKED_BY_BUNDLED_LIBMPV
STOP_GATE_B=BLOCKED_BY_DISK_CACHE_CAPABILITY
```

---

## 9. 统一跨来源 UI Seek 所有权

### 9.1 全局 token

```dart
int _uiSeekRequestGeneration = 0;
```

所有来源必须通过：

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
远程 rewind/fastforward
恢复位置的 UI 提交路径
```

### 9.2 每次提交

```text
_uiSeekRequestGeneration++
捕获 requestToken
提交 Controller
返回时检查 mounted、Controller identity、SessionId、requestToken
```

### 9.3 回写

```text
executed
→ 使用 committedPosition

superseded
→ 不回退、不提示

cancelled
→ 不回退、不提示

failed 且仍为最新 requestToken
→ 使用 controller.state.displayPosition
→ 显示固定提示：跳转失败，请重试
```

禁止旧横向或进度条请求恢复到自己的 `startPosition`。

### 9.4 Preview

横向拖动与进度条只管理：

```text
previewPosition
```

提交后立即清除 preview，页面位置完全由：

```text
requestedPosition → committedPosition
```

驱动。

---

## 10. `playback_cache_observation` 确定性节流

### 10.1 Schema

固定增加：

```text
eventSchemaVersion=1
settingsMode=automatic|memoryOnly|spaceSaving|balanced|aggressive|custom
telemetryStatus=available|fieldTemporarilyAbsent|unsupported|readFailed
optionalTuningDegraded=true|false
optionalTuningUnavailable=none|streamBufferSize|cachePause|cachePauseWait|multiple
```

`requestedMode` 允许：

```text
disk|memory|disabled|unavailable
```

### 10.2 立即记录的关键变化

以下不受 5 秒窗口限制：

```text
confirmedMode 变化
telemetryStatus 变化
cacheOnDisk 变化
file-cache-bytes 0 → 非0
cacheEvidence 变化
fallbackReason 变化
```

### 10.3 普通 bucket 变化

```text
fileCacheBytes bucket
actualForward bucket
actualBackward bucket
```

处理：

```text
若距上一条 observation >=5 秒
→ 立即写最新 snapshot

若不足 5 秒
→ 只保存 latest pending snapshot
→ 覆盖旧 pending
→ 到 5 秒边界后只写最新值
```

禁止：

- 全部丢弃；
- 把窗口内每个中间值都写出；
- 只保留第一个中间值。

### 10.4 去重

构造安全 fingerprint：

```text
schemaVersion
settingsMode
requestedMode
confirmedMode
cacheEvidence
telemetryStatus
cacheOnDisk
fileCacheBytesBucket
actualForwardBucket
actualBackwardBucket
fallbackReason
optionalTuningDegraded
optionalTuningUnavailable
testOverrideActive
```

fingerprint 完全相同不得重复写。

### 10.5 Session 结束

```text
停止新采样
→ 若存在 pending observation，立即强制 flush 最新值
→ 再生成 session summary
```

每个 Session 最多一个节流 Timer；summary 后取消 Timer 并释放 pending。

---

## 11. `playback_cache_session_summary` 聚合规则

### 11.1 聚合器所有权

```dart
class PlaybackCacheEvidenceAccumulator {
  final PlaybackItemSessionId sessionId;
  bool summaryWritten;
  ...
}
```

`summaryWritten` 属于该 Session 聚合器，不得使用会无限增长的全局 `Set<PlaybackItemSessionId>`。

Session 释放时整个 accumulator 一并释放。

### 11.2 requestedMode

定义为该 PlaybackItemSessionId **首次成功解析出的运行 Profile 请求模式**。

如果 Session 在 Profile 解析前失败：

```text
requestedMode=unavailable
```

不得根据用户设置猜测。

另加：

```text
settingsMode=<用户缓存设置模式>
```

### 11.3 finalConfirmedMode

表示 Session 最终结束时最后一个有原生证据的模式：

```text
disk|memory|memoryFallback|disabled|unconfirmed
```

### 11.4 cacheEvidence 使用“本 Session 最强证据”

优先级固定：

```text
1. Session 任意时刻观察到 file-cache-bytes > 0
   → diskDataObserved

2. 否则，Session 任意时刻原生确认 memory/memoryFallback
   → memoryProfileConfirmed

3. 否则，Session 任意时刻确认磁盘 Profile，但未观察到非零字节
   → diskConfiguredOnly

4. 否则，明确确认 disabled
   → disabled

5. 其他
   → unconfirmed
```

示例：

```text
先 diskDataObserved
→ 因 lowSpace 切换 memoryFallback
→ 退出

summary.cacheEvidence=diskDataObserved
summary.finalConfirmedMode=memoryFallback
```

两字段表达不同语义，不能互相覆盖。

### 11.5 telemetryAvailableEver

基础字段改为：

```text
telemetryStatusEver=
available|temporarilyAbsentOnly|unsupported|readFailed|neverAttempted
```

若兼容旧布尔字段，可额外派生：

```text
telemetryAvailableEver=true|false
```

但 Gate 判定使用枚举。

### 11.6 cleanup 最坏结果聚合

同一 PlaybackItemSessionId 可能经历多个内部缓存 Session。

```text
cleanupResult 优先级：
timeout > failed > success > notApplicable
```

任何一次 timeout 不能被后续 success 覆盖。

新增：

```text
cleanupAttemptCountBucket=zero|one|two|threeOrMore
```

### 11.7 safetyReopenReason

同一 Session 可能发生多个原因，字段允许：

```text
none|budget|lowSpace|memoryPressure|multiple
```

两种及以上不同原因 → `multiple`。

### 11.8 runtimeRecovery 聚合

```text
failed
> succeeded
> cancelled
> notAttempted
```

若最终播放因恢复失败而结束，必须是 `failed`。

### 11.9 testOverrideUsed

只要 Session 任意时刻使用过测试覆盖：

```text
testOverrideUsed=true
```

### 11.10 Seek 计数冻结顺序

Session 结束时：

```text
1. 禁止接受新的 UI/远程 Seek
2. 从同一 Seek 统计器冻结不可变计数快照
3. 停止 cache monitor
4. 完成或超时 cleanup
5. flush latest pending observation
6. 用冻结快照写 playback_cache_session_summary
7. 用同一冻结快照写现有 Seek summary
8. 释放 accumulator 与统计器
```

不得先 reset Seek 计数再生成缓存 summary。

### 11.11 幂等性

以下并发/重复入口：

```text
shutdown
dispose
route close
item switch
remote stop
natural completed
```

都必须通过 Session 内部原子 `summaryWritten`，最终精确写一条。

### 11.12 Schema 字段

两个新事件都必须包含：

```text
eventSchemaVersion=1
settingsMode=<固定枚举>
optionalTuningDegraded=<bool>
optionalTuningUnavailable=<固定枚举>
```

summary 额外包含：

```text
cleanupAttemptCountBucket
telemetryStatusEver
```

---

## 12. 日志安全与容量控制

### 12.1 允许内容

```text
固定事件名
schema version
固定枚举
布尔值
容量 bucket
时长 bucket
非敏感聚合计数
```

### 12.2 禁止内容

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
NativePlayer handle 数值
mpv context 地址
原始 Node dump
```

### 12.3 数量门禁

对 10 分钟持续播放、每秒采样的测试：

```text
无状态变化时 observation <= 2 条
只有 bucket 变化时按窗口合并
Session summary 精确 1 条
```

---

## 13. 追加自动测试矩阵

### 13.1 Alias 完整可用候选

```text
modern usable + legacy usable → modern
modern present but reset missing + legacy usable → legacy
modern choice 不含 immediate + legacy usable → legacy
modern write/read-back 失败 + legacy usable → legacy
modern/legacy 均 incomplete → unavailable
```

### 13.2 Canonicalizer

```text
yes=true=1
no=false=0
1=1.0
路径尾分隔符
空 reset
非法数值
未知 enum
```

### 13.3 Profile 核心/可选

```text
stream-buffer-size 缺失 → disk 仍可通过，optional degraded
cache-pause-wait 缺失 → memory 仍可通过
目录/unlink 缺失 → disk blocked、memory passed
```

### 13.4 活动 context

```text
同一 context 打开 loopback fixture 并读取 Node
第二 context 读取不得作为通过证据
Node 在成功、解析失败和异常路径均释放
engine dispose 后拒绝新读取
旧 generation 结果不写回
```

### 13.5 Observation 节流

```text
关键变化立即写
5 秒内 3 次 bucket 变化只写 latest
Session 结束前 flush pending
完全相同 fingerprint 不重复
telemetry 四态正确
```

### 13.6 Summary 聚合

```text
disk nonzero → memoryFallback → summary evidence=diskDataObserved，final=memoryFallback
cleanup failed 后 success → failed
cleanup timeout 后 success → timeout
多个 safety reason → multiple
profile 前失败 → requestedMode=unavailable
重复 shutdown/dispose → 1 条
Seek 冻结计数与两份 summary 一致
```

### 13.7 UI Seek

```text
横向 A → 远程 B → A superseded，不回退
进度条 A → 双击 B，不回退
章节 B 覆盖旧 preview
只有最新 failed 显示“跳转失败，请重试”
superseded/cancelled 不提示
```

---

## 14. CI 与 Actions 可执行夹具

Actions 必须实际运行：

```text
Dart Alias/canonicalizer/Profile/accumulator tests
Swift MPV_FORMAT_NODE tests
loopback Range server active-context test
Android 同语义 native smoke
两个新事件安全扫描
```

禁止以 Fake Map 单元测试替代 active-context Gate。

若 CI 平台无法运行真正活动 Player 集成：

```text
STOP_GATE_ACTIVE_CONTEXT_TELEMETRY_READER
不得标记 PASSED
```

必须停止并汇报缺少的执行环境，而不是弱化 Gate。

---

## 15. 建议提交顺序

```text
fix: resolve fully usable mpv cache option aliases
fix: canonicalize native playback option readback
fix: apply memory cache independently of disk-only options
feat: read cache telemetry from the active mpv context
fix: unify cross-source seek UI ownership
feat: record deterministic cache observations and summaries
test: close Luna Max cache compatibility gates
```

每个生产提交必须同时包含对应测试。

---

## 16. 最终自动化状态

### 16.1 当前捆绑 libmpv 支持磁盘缓存

```text
STOP_GATE_CACHE_OPTION_BINDING_IMPLEMENTATION=PASSED
STOP_GATE_MEMORY_CACHE_PROFILE=PASSED
STOP_GATE_ACTIVE_CONTEXT_TELEMETRY_READER=PASSED
STOP_GATE_DISK_CACHE_CAPABILITY=PASSED
STOP_GATE_DISK_TELEMETRY_EVIDENCE=PASSED
STOP_GATE_CACHE_LOG_OBSERVATION=PASSED
STOP_GATE_CACHE_SESSION_SUMMARY=PASSED
AUTOMATED_SEEK_STABILITY_GATE=PASSED
STOP_GATE_SEEK_STABILITY=WAITING_FOR_DEVICE_OWNER
STOP_GATE_B=WAITING_FOR_DEVICE_OWNER
```

### 16.2 当前捆绑 libmpv 真实不支持磁盘缓存

```text
STOP_GATE_CACHE_OPTION_BINDING_IMPLEMENTATION=PASSED
STOP_GATE_MEMORY_CACHE_PROFILE=PASSED
STOP_GATE_ACTIVE_CONTEXT_TELEMETRY_READER=PASSED
STOP_GATE_DISK_CACHE_CAPABILITY=BLOCKED_BY_BUNDLED_LIBMPV
STOP_GATE_DISK_TELEMETRY_EVIDENCE=BLOCKED_BY_BUNDLED_LIBMPV
STOP_GATE_CACHE_LOG_OBSERVATION=PASSED
STOP_GATE_CACHE_SESSION_SUMMARY=PASSED
AUTOMATED_SEEK_STABILITY_GATE=PASSED
STOP_GATE_SEEK_STABILITY=WAITING_FOR_DEVICE_OWNER
STOP_GATE_B=BLOCKED_BY_DISK_CACHE_CAPABILITY
```

任何 `unconfirmed` 都不能作为磁盘或内存 PASS。

---

## 17. Luna Max 最终汇报要求

完成代码、测试和新同 HEAD Actions A/B 后，必须一次性报告：

1. `implementation_start_head`；
2. `implementation_code_head`；
3. 相对起点的提交列表；
4. modern/legacy 每个候选的完整证据；
5. 最终选中的 native 名称；
6. canonicalizer 规则与测试；
7. disk/memory/disabled 核心能力和可选降级；
8. `NativePlayer` 当前 handle 的真实接入方式；
9. `MPV_FORMAT_NODE` 获取与释放证据；
10. loopback active-context 测试结果；
11. 所有新 Gate；
12. Observation 的实际样例与节流计数；
13. Summary 的实际样例与聚合结果；
14. 跨来源 Seek UI 测试；
15. 最终测试总数；
16. 本地门禁；
17. Run A/B；
18. IPA 与签名证据；
19. 仍需设备所有者执行的真机项目；
20. 明确说明未修改 `main`、未提交 `docs/test/`、未升级依赖、未代填真机 PASS。

不得输出已经废弃的：

```text
STOP_GATE_CACHE_OPTION_ALIAS
STOP_GATE_CACHE_TELEMETRY
```

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
