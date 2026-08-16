# 持续预读到媒体结尾缓存实施计划（Luna / main 直开发版）

## 0. 文档状态

- 仓库：`jsdfhasuh/emby_my_client`
- 目标开发分支：`main`
- 计划写入前 `main`：`645ef68b3c9f3aa73e249bb41dd8c78273558995`
- 计划日期：`2026-08-16`
- 执行者：Luna
- 当前状态：`PLAN_ONLY / NOT_IMPLEMENTED`
- 交付方式：Luna 在本地 `main` 上形成阶段性提交，全部门禁通过后一次性推送 `origin/main`

本计划取代此前“计划分支 + 实现分支 + Draft PR”的交付方式。本轮不创建功能分支，不创建 PR，不执行合并；但仍必须保留完整的基线、测试、提交和远端一致性证据。

---

## 1. 总体目标

新增一个显式缓存模式：

```text
持续预读
```

对符合条件的媒体，播放器应从本次播放起点或恢复位置开始，持续向媒体结尾预读。设备空间允许时，实际可 Seek 的磁盘缓存范围应最终连续覆盖到媒体结尾。

本轮必须支持：

- 普通 HTTP/HTTPS 渐进式媒体；
- 有限时长的渐进式 STRM；
- 经 Emby `/Videos/{id}/stream?Static=true` 代理的有限时长渐进式 STRM；
- Android；
- iOS/iPadOS，前提是现有 libmpv 磁盘缓存能力门禁通过。

本轮不得错误支持：

- HLS / `.m3u8`；
- DASH / `.mpd`；
- Emby 转码流；
- 直播 STRM；
- 时长未知 STRM；
- 非 HTTP/HTTPS 渐进式来源。

现有缓存模式必须保持原语义：

```text
自动
仅内存
节省空间
平衡
大缓存
自定义
```

“持续预读”是当前播放会话的临时缓存，不是永久离线下载。退出播放器后仍使用现有 Session 清理机制删除缓存。

---

## 2. 当前实现审核结论

当前缓存体系已经具备以下基础：

- `PlaybackCacheSettings` 提供自动、内存、节省、平衡、大缓存和自定义模式；
- `PlaybackCacheProfileResolver` 能区分 `progressiveHttp`、`segmentedHttp`、直播、未知和本地离线；
- `NativePlaybackCacheEngine` 能设置并读回 mpv 缓存选项；
- `PlaybackCacheCoordinator` 能读取 `file-cache-bytes`、输入速率和 `seekable-ranges`；
- `PlaybackController` 能在低空间、内存压力和预算达到时执行受控重开；
- 时间轴已经能绘制经确认的磁盘缓存范围；
- 缓存目录使用独立 Session、marker 校验、活动目录隔离和冷启动遗留清理；
- 已有测试确认有限时长渐进式 STRM 会分类为 `progressiveHttp`，HLS STRM、直播 STRM和未知时长 STRM不会进入磁盘缓存。

当前无法像 Infuse Auto 一样持续缓存到结尾，主要由三项主动限制导致：

1. `cache-secs` 被设置为固定前向窗口，最高通常为 600 秒，自定义最高 900 秒；
2. 自动模式最高 2 GiB，自定义最高 4 GiB，并受安全可用空间 25% 限制；
3. `fileCacheBytes` 达到预算阈值后会触发 `budget` 安全重开，清理磁盘 Session 并降级到内存缓存。

本轮必须新增独立策略，不能仅把 4 GiB 改成更大的常量。

---

## 3. 固定产品契约

### 3.1 新模式名称

代码枚举：

```dart
PlaybackCacheMode.fullReadAhead
```

中文名称：

```text
持续预读
```

设置摘要：

```text
持续预读 · 空间允许时预读至结尾
```

现有默认值仍为：

```dart
PlaybackCacheMode.automatic
```

不得把既有用户自动迁移到持续预读。

### 3.2 支持条件

新增统一判断，业务代码不得根据 `container == 'strm'` 直接排除：

```dart
bool isFullReadAheadEligible(PlaybackPlan plan) {
  return plan.transportKind == PlaybackTransportKind.progressiveHttp &&
      plan.duration > Duration.zero;
}
```

固定矩阵：

| 媒体 | 结果 |
|---|---|
| 普通 MP4/MKV 渐进式 HTTP | 支持持续预读 |
| 有限时长 STRM → MP4/MKV | 支持持续预读 |
| 有限时长 STRM → Emby Static stream | 支持持续预读 |
| STRM → `.m3u8` | 不支持，保持分段流内存缓存 |
| STRM → `.mpd` | 不支持，保持分段流内存缓存 |
| 直播 STRM | 不支持 |
| 时长未知 STRM | 不支持 |
| Emby Transcode | 不支持 |
| 本地离线文件 | 不需要网络缓存 |

不得改变现有 STRM URL 安全规则，不得绕过 Emby 代理策略，不得在日志中输出上游 URL、token、API key 或 query 参数。

### 3.3 预读范围定义

持续预读不是承诺缓存整个源文件的历史部分，而是：

```text
从本次播放起点或恢复位置，连续预读到媒体结尾
```

新增 `readAheadAnchor`：

- 初次播放为 0；
-恢复播放为实际恢复位置；
- 用户执行向后 Seek 后，anchor 更新为 `min(oldAnchor, committedPosition)`；
- 向前 Seek 不提高 anchor。

只有实际缓存范围连续覆盖 `readAheadAnchor → mediaEnd`，才能显示“已预读至结尾”。

### 3.4 完成证据

不得用以下内容宣称预读完成：

- 预计文件大小；
- `sessionTargetBytes`；
- `file-cache-bytes` 不再增长；
- 普通 `bufferStream`；
- 播放位置接近结尾。

唯一允许的完成证据：

```text
经确认的 seekable-ranges 中，存在连续范围：
range.start <= readAheadAnchor + 2 秒
range.end >= mediaDuration - 2 秒
```

telemetry 不可用时只能显示：

```text
实际预读范围暂不可确认
```

### 3.5 不支持场景的行为

当用户选择持续预读，但媒体不符合条件时：

- HLS/DASH/转码：使用现有 `segmentedTransport` 内存降级；
- 直播或未知时长：使用现有 `liveOrUnknownLength` 内存降级；
- mpv 能力不足：使用现有 `engineCapabilityUnavailable`；
- 目录或容量无法确认：使用现有存储降级原因。

不得为了“支持所有 STRM”而把分段流伪装成渐进式文件。

---

## 4. main 直开发强制规则

### 4.1 启动前

Luna 必须执行：

```bash
git switch main
git fetch origin
git status --short
git pull --ff-only origin main
BASE_SHA="$(git rev-parse HEAD)"
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
```

要求：

```text
BRANCH=main
WORKTREE=CLEAN
LOCAL_HEAD=ORIGIN_MAIN
```

如果工作树不干净，立即停止并报告，不得 stash、覆盖或提交用户的无关改动。

### 4.2 禁止操作

本轮禁止：

```text
git switch -c
git checkout -b
git rebase
git merge
git reset --hard
git push --force
git push --force-with-lease
创建 PR
合并 PR
删除分支
修改无关功能
```

### 4.3 提交与推送策略

- 每个阶段允许在本地 `main` 创建独立提交；
- 阶段提交前必须通过该阶段定向测试；
- 所有实现提交在最终全量门禁前不得推送；
- UI 入口最后启用，避免未完成能力提前暴露；
- 最终门禁全部通过后只执行一次：

```bash
git fetch origin
test "$(git rev-parse origin/main)" = "$BASE_SHA"
git push origin main
```

如果开发期间远端 `main` 已变化，立即停止并报告：

```text
REMOTE_MAIN_MOVED
NOT_PUSHED
```

不得自动 merge、rebase 或覆盖远端。

### 4.4 基线门禁

开始生产修改前执行：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
```

基线失败时停止，不得将已有失败归入本功能。

---

## 5. 目标架构

### 5.1 强类型策略

新增：

```dart
enum PlaybackCacheReadAheadStrategy {
  boundedWindow,
  mediaEnd,
}

enum PlaybackCacheBudgetPolicy {
  boundedReopen,
  lowSpaceOnly,
}

enum PlaybackCacheSizeConfidence {
  serverDeclared,
  estimated,
  unknown,
}
```

扩展 `ResolvedPlaybackCacheProfile`：

```dart
final PlaybackCacheReadAheadStrategy readAheadStrategy;
final PlaybackCacheBudgetPolicy budgetPolicy;
final PlaybackCacheSizeConfidence sizeConfidence;
final Duration readAheadAnchor;
final int? estimatedSourceBytes;
```

固定映射：

```text
现有模式
→ boundedWindow
→ boundedReopen

持续预读且符合条件
→ mediaEnd
→ lowSpaceOnly
```

engine、coordinator、controller 和 UI 必须依赖解析后的 Profile，不得散落判断 `settings.mode == fullReadAhead`。

### 5.2 媒体大小证据

扩展 `PlaybackPlan`：

```dart
final int? sourceSizeBytes;
```

解析优先级：

1. `MediaSource.Size` 合法且大于 0：`serverDeclared`；
2. 无 Size，但 `Bitrate > 0` 且时长有效：`estimated`；
3. 两者均不可用：`unknown`。

估算：

```text
remainingDuration = duration - readAheadAnchor
estimatedBytes = bitrate / 8 × remainingDurationSeconds × 1.25
```

服务端声明大小按剩余时长比例估算本次所需量：

```text
remainingBytes
= sourceSizeBytes × remainingDuration / duration
```

再增加安全余量：

```text
margin = clamp(remainingBytes × 10%, 64 MiB, 1 GiB)
requiredBytes = remainingBytes + margin
```

任何溢出、负数、非有限数值或异常字符串都必须降为 `unknown`，不得使播放失败。

### 5.3 安全可用空间

持续预读不得使用现有“安全可用空间 25%”和“最高 4 GiB”的限制。

计算：

```text
rate = rawInputRate ?? max(mediaBitrate / 8 × 2, 8 MiB/s)
lowSpaceGuard
= clamp(
    rate × (spacePollInterval + expectedCloseLatency),
    64 MiB,
    512 MiB,
  )

safeSpendable
= max(
    0,
    freeBytes - reservedFreeBytes - lowSpaceGuard,
  )
```

大小已知或可估算：

```text
requiredBytes <= safeSpendable
→ mediaEnd / lowSpaceOnly

requiredBytes > safeSpendable
→ 回退现有安全窗口缓存
→ fallbackReason = fullReadAheadInsufficientSpace
```

大小未知：

```text
safeSpendable >= 512 MiB
→ 允许 best-effort mediaEnd
→ sessionTargetBytes = safeSpendable
→ sizeConfidence = unknown

safeSpendable < 512 MiB
→ 回退现有安全窗口或内存缓存
```

未知大小时 UI 必须显示“按可用空间尽力预读”，不得承诺完整缓存。

### 5.4 mpv Profile

持续预读磁盘 Profile：

```text
cache=yes
cache-on-disk=yes
demuxer-cache-dir=<session directory>
demuxer-cache-unlink-files=immediate
cache-secs=<媒体总时长秒数 + 30 秒>
demuxer-seekable-cache=auto
cache-pause=yes
cache-pause-wait=1
stream-buffer-size=<resolved value>
```

使用媒体总时长而不是剩余时长，是为了用户向后 Seek 后仍能继续向结尾预读。

`cache-secs` 必须经过能力写入和读回；若当前平台无法接受该值，不得谎报持续预读，必须回退现有有界缓存。

现有内存、disabled 和有界磁盘 Profile 保持原行为。

### 5.5 metadata 预算

磁盘数据可以很大，但 demuxer metadata 仍占内存。持续预读不得把 metadata 预算设置为媒体大小。

建议规则：

```text
cap = clamp(sessionTargetBytes / 64, 64 MiB, 256 MiB)
forward = max(32 MiB, cap × 75%)
backward = max(16 MiB, cap - forward)
```

要求：

- 总和不超过 256 MiB；
- Android 和 iPadOS 真机出现明显内存压力时退回 128 MiB 上限；
- metadata 不足只能导致实际范围不完整或降级，不得使播放崩溃；
- UI 只展示 telemetry 证实的范围。

### 5.6 预算和安全重开语义

现有有界模式：

```text
fileCacheBytes >= stopThreshold
→ PlaybackCacheSafetyReason.budget
→ 保持现有一次受控重开和内存降级
```

持续预读模式：

```text
budgetPolicy = lowSpaceOnly
→ 不检查普通 file-cache budget
→ 达到旧 2 GiB / 4 GiB 阈值不重开
→ 到达媒体结尾不重开
```

以下保护仍必须保留：

- 低空间；
- 系统内存压力；
- mpv 磁盘缓存创建失败；
- 播放器恢复状态机；
- 一次性自动重开预算。

持续预读时空间检查周期调整为 2 秒；现有有界模式保持 10 秒。

### 5.7 生命周期和清理

- 用户在前台手动暂停播放时，协调器继续观察；播放器是否继续下载由当前 libmpv 实际能力决定；
- 应用进入后台时保持现有生命周期暂停，不新增后台持续下载；
- 返回前台立即检查可用空间和实际缓存范围；
- 用户退出播放器、切换媒体源、切换音轨导致重开或播放失败时，继续使用现有 Session 清理；
- 应用异常退出后的合法 marker 遗留目录继续由冷启动清理；
- 不创建第二套缓存目录或数据库。

### 5.8 UI 和诊断

设置页新增：

```text
持续预读
```

说明：

```text
对有限时长的普通 HTTP 媒体和 STRM，空间允许时从本次播放位置持续预读至结尾。
缓存仅在当前播放会话有效，退出播放器后释放。
该模式可能产生较大的网络流量和临时磁盘占用。
```

持续预读模式显示：

- 设备保留空间；
- 当前可用空间；
- 预计本次需要空间或“媒体大小未知”；
- 是否预计能够预读到结尾。

播放状态示例：

```text
缓存模式：持续预读（磁盘）
起始位置：00:42:18
预计本次需要：约 6.4 GB
已使用：2.1 GB
已连续预读至：01:31:22 / 02:08:10
状态：正在持续预读
```

完成：

```text
状态：已从本次起始位置预读至媒体结尾
```

大小未知：

```text
预计本次需要：无法确认
状态：正在按可用空间尽力预读
```

新增固定诊断字段：

```text
readAheadStrategy=boundedWindow|mediaEnd
budgetPolicy=boundedReopen|lowSpaceOnly
sizeConfidence=serverDeclared|estimated|unknown
fullReadAheadEligible=true|false
fullReadAheadReachedEnd=true|false
```

不得记录媒体标题、服务器地址、URL、query、token、缓存目录绝对路径。

---

## 6. 分阶段实施

## Phase 0：基线和 libmpv 可行性探针

### 目标

在修改产品逻辑前确认：

- 大于 900 秒的 `cache-secs` 能写入并读回；
- progressive HTTP 能创建磁盘缓存；
- `file-cache-bytes` 和 `seekable-ranges` 可观察；
- 活跃播放时缓存范围能持续扩展；
- 到达结尾后播放器不产生致命错误。

前台手动暂停时是否继续预读作为能力证据记录；若当前平台不支持，不得通过循环 play/pause 或后台任务伪造。

### 允许修改

```text
scripts/android/*cache*probe*
ios/Runner/PlaybackCacheCapabilitySupport.swift
ios/RunnerTests/RunnerTests.swift
test/playback_cache_capabilities_test.dart
```

仅在现有探针无法覆盖时修改。不得先改业务策略再补能力证据。

### Stop Gate P0

```text
BASELINE_FORMAT=PASSED
BASELINE_ANALYZE=PASSED
BASELINE_TEST=PASSED
LARGE_CACHE_SECS_READBACK=PASSED
DISK_GATE_UNCHANGED=PASSED
```

提交：

```text
test: verify media-end cache capability
```

若无需生产修改，可只记录测试证据，不强制空提交。

---

## Phase 1：模型、设置和播放源大小

### 允许修改

```text
lib/models/emby_models.dart
lib/data/emby_api.dart
lib/playback/cache/playback_cache_settings.dart
lib/playback/playback_settings.dart
lib/playback/cache/playback_cache_policy.dart

test/emby_models_test.dart
test/emby_api_playback_test.dart
test/playback_settings_test.dart
test/playback_cache_policy_test.dart
```

### 实现

- 增加 `PlaybackCacheMode.fullReadAhead`；
- 增加三类强类型策略；
- `PlaybackPlan` 增加 `sourceSizeBytes`；
- 安全解析 `MediaSource.Size`；
- `ResolvedPlaybackCacheProfile` 增加策略、anchor 和大小证据字段；
- 旧 JSON 缺少新字段时保持自动模式；
- 未知枚举仍回退自动模式；
- 有限时长 progressive STRM 分类保持不变；
- HLS、直播、未知时长 STRM 分类保持不变。

### Stop Gate P1

```text
OLD_SETTINGS_COMPAT=PASSED
FULL_MODE_JSON_ROUND_TRIP=PASSED
SOURCE_SIZE_PARSE=PASSED
FINITE_STRM_PROGRESSIVE=PASSED
HLS_STRM_SEGMENTED=PASSED
LIVE_OR_UNKNOWN_STRM_EXCLUDED=PASSED
```

提交：

```text
refactor: model full read-ahead cache policy
```

---

## Phase 2：空间预算与 Profile 解析

### 允许修改

```text
lib/playback/cache/playback_cache_policy.dart
lib/playback/playback_controller.dart

test/playback_cache_policy_test.dart
test/playback_cache_controller_test.dart
```

### 实现

- 在 `_startPlayback` 中先确定本次实际起播或恢复位置；
- 将 `readAheadAnchor` 传入 Profile resolver；
- 分离有界模式和 media-end 模式预算；
- 持续预读不受 25% 和 4 GiB 限制；
- 大小已知但安全空间不足时在 open 前回退；
- 大小未知时按 safeSpendable 尽力预读；
- 新增 `fullReadAheadInsufficientSpace`；
- 现有自动空间档位和高码率最小窗口测试不得改变。

### Stop Gate P2

```text
KNOWN_SIZE_FITS_MEDIA_END=PASSED
KNOWN_SIZE_INSUFFICIENT_FALLBACK=PASSED
ESTIMATED_SIZE_POLICY=PASSED
UNKNOWN_SIZE_BEST_EFFORT=PASSED
NO_25_PERCENT_CAP_IN_FULL_MODE=PASSED
NO_4_GIB_CAP_IN_FULL_MODE=PASSED
BOUNDED_MODES_UNCHANGED=PASSED
```

提交：

```text
feat: resolve media-end read-ahead profiles
```

---

## Phase 3：mpv 完整 Profile

### 允许修改

```text
lib/playback/cache/playback_cache_engine.dart
lib/playback/cache/playback_cache_option_bindings.dart

test/playback_cache_engine_test.dart
test/playback_cache_option_bindings_test.dart
```

### 实现

- 持续预读 `cache-secs = duration + 30 秒`；
- 完整写入并读回关键选项；
- 应用持续预读 metadata cap；
- optional option 失败只标记 degraded；
- critical option 失败回退既有安全 Profile；
- 内存、disabled 和有界磁盘 Profile 不变；
- 不依赖上一个媒体残留属性。

### Stop Gate P3

```text
MEDIA_DURATION_CACHE_SECS=PASSED
CRITICAL_READBACK=PASSED
METADATA_CAP=PASSED
MEMORY_PROFILE_UNCHANGED=PASSED
DISABLED_PROFILE_UNCHANGED=PASSED
```

提交：

```text
feat: apply media-end mpv cache profile
```

---

## Phase 4：协调器、完成证据和安全重开

### 允许修改

```text
lib/playback/cache/playback_cache_coordinator.dart
lib/playback/playback_controller.dart
lib/playback/playback_state.dart
lib/playback/cache/playback_cache_telemetry.dart

test/playback_cache_coordinator_test.dart
test/playback_cache_controller_test.dart
test/playback_controller_test.dart
```

### 实现

- `budgetPolicy=lowSpaceOnly` 时忽略普通 budget threshold；
- 有界模式保留现有 budget reopen；
- 持续预读空间轮询改为 2 秒；
- 低空间优先于所有普通事件；
- 内存压力只触发一次受控重开；
- 实际执行向后 Seek 后降低 readAheadAnchor；
- 归一化缓存范围并计算连续 anchor-to-end 覆盖；
- 到达结尾只更新状态，不重开播放器；
- stale generation / stale engine / stale session 不得发布完成状态；
- 受控重开必须保持位置、播放状态、倍速、音轨、字幕和 reporter 一致性。

### Stop Gate P4

```text
FULL_MODE_IGNORES_BUDGET_REOPEN=PASSED
BOUNDED_MODE_BUDGET_REOPEN=PASSED
LOW_SPACE_REOPEN_ONCE=PASSED
MEMORY_PRESSURE_REOPEN_ONCE=PASSED
ANCHOR_MOVES_BACKWARD_ONLY=PASSED
CONTIGUOUS_RANGE_REQUIRED=PASSED
REACHED_END_NO_REOPEN=PASSED
STALE_TELEMETRY_REJECTED=PASSED
POSITION_AND_PRESENTATION_PRESERVED=PASSED
```

提交：

```text
fix: keep full read-ahead active to media end
```

---

## Phase 5：设置入口和播放状态

### 允许修改

```text
lib/ui/playback_cache_settings_screen.dart
lib/ui/widgets/playback_cache_status_section.dart
lib/ui/widgets/playback_timeline.dart
lib/ui/player_screen.dart

test/playback_cache_settings_ui_test.dart
test/playback_timeline_test.dart
test/player_screen_test.dart
```

### 实现

- 最后才在设置页暴露“持续预读”；
- 持续预读显示保留空间，不显示固定前向/后向秒数和 4 GiB 自定义目标；
- 显示 serverDeclared、estimated 或 unknown 对应文案；
- 显示实际连续预读终点；
- 只有真实范围达到结尾才显示完成；
- HLS STRM、直播 STRM和未知时长 STRM显示准确降级原因；
- 时间轴继续只绘制已确认的磁盘缓存范围；
- 不改变播放进度主色层级和 Seek 交互。

### Stop Gate P5

```text
FULL_MODE_VISIBLE=PASSED
CUSTOM_MODE_UI_UNCHANGED=PASSED
UNKNOWN_SIZE_COPY=PASSED
ACTUAL_RANGE_NOT_TARGET=PASSED
REACHED_END_COPY_REQUIRES_EVIDENCE=PASSED
TIMELINE_RANGE_TRUTHFUL=PASSED
```

提交：

```text
feat: expose full read-ahead controls and status
```

---

## Phase 6：诊断、回归和平台构建

### 允许修改

```text
lib/playback/playback_diagnostics.dart
lib/playback/cache/playback_cache_evidence.dart

test/playback_diagnostics_test.dart
test/playback_cache_evidence_test.dart
.github/workflows/ios-core.yml
```

工作流仅在现有命令无法覆盖新增测试时修改；不得修改签名、entitlement、UDP 或发布配置。

### 定向测试

```bash
flutter test test/emby_api_playback_test.dart
flutter test test/playback_cache_policy_test.dart
flutter test test/playback_cache_engine_test.dart
flutter test test/playback_cache_coordinator_test.dart
flutter test test/playback_cache_controller_test.dart
flutter test test/playback_controller_test.dart
flutter test test/playback_cache_settings_ui_test.dart
flutter test test/playback_timeline_test.dart
flutter test test/playback_diagnostics_test.dart
```

### 全量门禁

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
```

### Android

```bash
flutter build apk --debug --split-per-abi
```

要求：

```text
armeabi-v7a=PASSED
arm64-v8a=PASSED
x86_64=PASSED
```

### iOS/iPadOS

在 macOS 或现有 CI 执行：

```bash
flutter build ios --debug --no-codesign
```

要求：

- 不绕过现有 mpv capability gate；
- 不修改 entitlement；
- 不因 iOS 不支持某项能力而影响 Android；
- iOS 能力不足时准确降级。

提交：

```text
test: close full read-ahead cache gates
```

---

## Phase 7：真实设备验收和最终推送

### Android / iPadOS 场景

| 场景 | 预期 |
|---|---|
| 普通 MP4，空间充足 | 从起播位置持续预读至结尾 |
| 普通 MKV，空间充足 | 从起播位置持续预读至结尾 |
| STRM → MP4/MKV，时长明确 | 支持持续预读 |
| STRM → Emby Static stream | 支持持续预读 |
| STRM → `.m3u8` | 内存降级，不伪装完整预读 |
| 直播 STRM | 不启用磁盘持续预读 |
| 未知时长 STRM | 不启用磁盘持续预读 |
| 已知媒体空间不足 | open 前回退有界缓存 |
| 大小未知、空间足够 | 按可用空间尽力预读 |
| 从中间恢复播放 | anchor 为恢复位置 |
| 向后 Seek | anchor 向前移动，完成条件变严格 |
| 达到旧 2 GiB / 4 GiB | 不重开 |
| 实际范围到达结尾 | 显示完成且不重开 |
| 低空间 | 一次受控重开并降级内存 |
| 内存压力 | 一次受控重开并降级内存 |
| 退出播放器 | 当前 Session 被清理 |
| 应用异常退出后重启 | 合法 marker 遗留 Session 被清理 |

前台手动暂停时是否继续预读必须记录真实结果，但不允许通过额外后台下载器改变本轮范围。

### 最终远端一致性检查

```bash
git status --short
git fetch origin
test "$(git rev-parse origin/main)" = "$BASE_SHA"
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
git log --oneline "$BASE_SHA"..HEAD
git push origin main
git fetch origin
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
```

如果任一检查失败：

```text
NOT_PUSHED
STOPPED_AT_FINAL_GATE
```

不得强推。

最终文档提交：

```text
docs: record full read-ahead cache acceptance
```

---

## 7. 强制回归测试矩阵

必须覆盖：

1. 旧设置 JSON；
2. 新模式 JSON round-trip；
3. `MediaSource.Size` int/string/null/负数/溢出；
4. 普通 progressive HTTP；
5. 有限时长 progressive STRM；
6. 有限时长 HLS STRM；
7. 直播 STRM；
8. 未知时长 STRM；
9. 已知大小可容纳；
10. 已知大小不可容纳；
11. 仅有码率估算；
12. 大小完全未知；
13. full mode 不受 25% 限制；
14. full mode 不受 4 GiB 限制；
15. bounded mode 保持原限制；
16. 大 `cache-secs` 写入读回；
17. metadata cap；
18. full mode 忽略 budget reopen；
19. bounded mode 保留 budget reopen；
20. low-space 一次重开；
21. memory-pressure 一次重开；
22. anchor 向后更新；
23. 不连续 ranges 不得显示完成；
24. stale telemetry 不得显示完成；
25. 完成后不重开；
26. Session 正常清理；
27. 冷启动遗留清理；
28. UI 文案不把目标冒充实际；
29. timeline 只画已确认范围；
30. Android 三 ABI；
31. iOS 无签名构建。

---

## 8. 停止条件

出现以下任一情况立即停止并报告：

- 工作树存在无关改动；
- `main` 与 `origin/main` 不一致；
- 远端 `main` 在开发期间移动；
- 基线全量测试失败；
- 需要新增大型第三方依赖；
- 需要绕过 mpv capability gate；
- 需要修改签名、entitlement 或下载模块；
- 需要记录 STRM 上游 URL 或凭据；
- 真实 mpv 无法接受媒体时长级 `cache-secs`；
- full mode 只能通过永久文件下载才能实现；
- 低空间保护无法在侵入 reserved space 前触发；
- iOS/Android 任一平台出现无法解释的播放回归；
- 最终 push 需要 force。

停止输出必须包含：

```text
STOP_REASON
BASE_SHA
CURRENT_HEAD
ORIGIN_MAIN
CHANGED_FILES
PASSED_CHECKS
FAILED_CHECKS
NOT_PUSHED
```

---

## 9. 最终验收标准

仅在以下全部满足时标记：

```text
IMPLEMENTATION_COMPLETE
PUSHED_TO_MAIN
```

1. 普通渐进式 HTTP 能从起播位置持续预读到结尾；
2. 有限时长渐进式 STRM 同样支持；
3. HLS/DASH/直播/未知时长 STRM 不错误进入持续预读；
4. full mode 不受原 25%、2 GiB、4 GiB 正常预算限制；
5. full mode 达到旧预算不重开；
6. 实际连续 ranges 到达结尾时不重开；
7. 低空间和内存压力保护仍有效；
8. telemetry 不可用时不虚假显示完成；
9. 现有六种缓存模式行为不变；
10. 退出播放器后 Session 清理；
11. Android 三 ABI 构建通过；
12. iOS/iPadOS 无签名构建通过；
13. format、analyze、全量测试和 `git diff --check` 通过；
14. 本地 `main`、`origin/main` 和最终 HEAD 完全一致；
15. 未创建功能分支、PR 或 merge commit；
16. 未 force-push。

---

## 10. 建议本地提交顺序

```text
1. test: verify media-end cache capability
2. refactor: model full read-ahead cache policy
3. feat: resolve media-end read-ahead profiles
4. feat: apply media-end mpv cache profile
5. fix: keep full read-ahead active to media end
6. feat: expose full read-ahead controls and status
7. test: close full read-ahead cache gates
8. docs: record full read-ahead cache acceptance
```

无需修改的阶段不得制造空提交。最终一次性推送全部提交到 `main`。

---

## 11. Luna 最终输出格式

```text
STATUS=IMPLEMENTATION_COMPLETE|STOPPED
BASE_SHA=<sha>
FINAL_HEAD=<sha>
BRANCH=main
REMOTE_MAIN=<sha>
COMMITS=<ordered list>
CHANGED_FILES=<ordered list>
FORMAT=PASSED|FAILED
ANALYZE=PASSED|FAILED
FULL_TEST=PASSED|FAILED
ANDROID_ARMEABI_V7A=PASSED|FAILED|NOT_RUN
ANDROID_ARM64_V8A=PASSED|FAILED|NOT_RUN
ANDROID_X86_64=PASSED|FAILED|NOT_RUN
IOS_NO_CODESIGN=PASSED|FAILED|NOT_RUN
REAL_DEVICE_PROGRESSIVE_HTTP=PASSED|FAILED|OWNER_GATE
REAL_DEVICE_PROGRESSIVE_STRM=PASSED|FAILED|OWNER_GATE
REAL_DEVICE_HLS_STRM_FALLBACK=PASSED|FAILED|OWNER_GATE
PUSHED_TO_MAIN=true|false
WORKTREE=CLEAN|DIRTY
NOTES=<remaining risks or owner gates>
```

不得只输出“已完成”。所有结论必须附带提交、测试和远端一致性证据。
