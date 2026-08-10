## 6. PlaybackSettingsRepository 与设置迁移

当前完整 JSON 保存方式存在旧快照覆盖新设置风险。本轮必须先建立唯一设置所有者。

### 6.1 新增设置模型

建议新增：

```text
lib/playback/cache/playback_cache_settings.dart
```

```dart
enum PlaybackCacheMode {
  automatic,
  memoryOnly,
  spaceSaving,
  balanced,
  aggressive,
  custom,
}

class PlaybackCacheSettings {
  const PlaybackCacheSettings({
    this.mode = PlaybackCacheMode.automatic,
    this.customForwardSeconds = 180,
    this.customBackwardSeconds = 120,
    this.customSessionTargetBytes = 512 * 1024 * 1024,
    this.reservedFreeBytes = 2 * 1024 * 1024 * 1024,
  });

  final PlaybackCacheMode mode;
  final int customForwardSeconds;
  final int customBackwardSeconds;
  final int customSessionTargetBytes;
  final int reservedFreeBytes;
}
```

允许范围：

```text
前向缓存：30–900 秒
后向缓存：15–600 秒
会话目标：128 MiB–4 GiB
设备保留空间：1–8 GiB
```

所有反序列化输入必须 clamp。非法枚举、负数、超范围数值和未知字段不得导致应用启动失败。

### 6.2 集成到 PlaybackSettings

```dart
final PlaybackCacheSettings cache;
```

JSON 使用嵌套键：

```json
{
  "cache": {
    "mode": "automatic",
    "forwardSeconds": 180,
    "backwardSeconds": 120,
    "sessionTargetBytes": 536870912,
    "reservedFreeBytes": 2147483648
  }
}
```

迁移规则：

- 继续使用 `playback_settings_v1_<serverId>_<userId>`；
- 旧 JSON 缺少 `cache` 时使用自动默认；
- 不改名已有字段；
- cache 子对象损坏时只回退 cache 默认，不得丢失码率、字幕、倍速等其他字段；
- 账户数据删除继续删除同一 key。

### 6.3 新增 Repository

建议新增：

```text
lib/playback/playback_settings_repository.dart
```

职责：

```text
按 serverId + userId 串行
read-modify-write
字段级 patch
revision/generation
单 key 原子保存
```

建议 API：

```dart
class PlaybackSettingsRepository {
  Future<PlaybackSettingsSnapshot> load(EmbySession session);

  Future<PlaybackSettingsSnapshot> patch(
    EmbySession session,
    PlaybackSettingsPatch patch,
  );

  Future<void> clear(EmbySession session);

  Future<void> deleteAccountSettings(EmbySession session);
}
```

禁止业务页面继续执行：

```text
读取完整旧 settings
→ 修改一个字段
→ 把旧完整对象整体覆盖保存
```

播放器修改倍速时只能 patch 倍速；设置页修改 cache 时只能 patch cache。

`load`、`patch`、`clear`、`deleteAccountSettings` 和 sign-out cleanup 必须进入同一个 per-account 串行执行器。`clear` / `deleteAccountSettings` 必须：

```text
递增 account settings generation
→ 使尚未提交的旧 patch 失效
→ 等待当前持锁操作安全结束
→ 删除 key
→ 阻止旧 Future 在 clear 后重新写回
```

禁止出现：

```text
delete account 正在 clear
→ 之前排队的 patch 随后完成
→ 已删除 key 被重新创建
```

sign-out 和 delete-account 必须等待该队列清理完成后再释放账户上下文。

必须测试：

```text
播放器持有旧快照 A
→ 设置页保存新 cache B
→ 播放器保存新 rate C
→ 最终 cache = B 且 rate = C
```

### 6.4 所有权

- Repository 由 `AppController` 创建和持有；
- `HomeShell` 将设置读取和 patch 回调传给 SettingsScreen；
- `PlayerScreen` 使用同一 Repository；
- sign-out / delete account / dispose 使用同一清理路径；
- `clear` 和账户删除使用与 patch 相同的锁、generation 和串行队列；
- Repository dispose 后拒绝新操作并使未提交 patch 完成 cancelled/invalidated；
- 不得创建互不共享锁的多个 Store 实例。

---

## 7. 设置页与运行状态 UI

### 7.1 设置入口

在 SettingsScreen 增加：

```text
播放缓存
自动 · 前向 3 分钟 · 后向 2 分钟
```

点击进入：

```text
PlaybackCacheSettingsScreen
```

不得把全部高级字段直接堆在主设置页。

### 7.2 设置页面

```text
缓存模式
自动（推荐）
仅内存
节省空间
平衡
大缓存
自定义

[仅自定义显示]
前向缓存目标
后向缓存目标
最大会话缓存目标
设备保留空间

当前设备
可用于缓存的空间：约 N GB / 无法确认

说明
缓存仅在当前媒体播放会话有效，退出后释放。
后向时间为目标，实际范围取决于媒体格式和播放器缓存状态。
```

预设：

| 模式 | 前向目标 | 后向目标 | 会话目标 |
|---|---:|---:|---:|
| 仅内存 | 60 秒 | 30 秒 | 0 |
| 节省空间 | 90 秒 | 60 秒 | 256 MiB |
| 平衡 | 180 秒 | 120 秒 | 512 MiB |
| 大缓存 | 600 秒 | 300 秒 | 2 GiB |

自动模式由空间策略决定。

### 7.3 当前播放只读状态

播放器“播放”选项页显示：

```text
缓存模式：自动（磁盘）
本次目标：512 MB
前向目标：3 分钟
后向目标：2 分钟
实际可前向 Seek：约 2 分 26 秒
实际可回退：约 1 分 47 秒
文件缓存已使用：186 MB
状态：正常
```

降级时：

```text
缓存模式：内存
原因：目录不可用 / 能力不支持 / 空间不足 / 已达到会话目标
```

属性字段缺失时显示：

```text
实际缓存范围：暂不可用
```

不得用目标值冒充实际值。

### 7.4 设置生效时机

用户在设置页修改缓存：

- 默认从下一次打开媒体生效；
- 不因设置页保存而中断当前播放；
- 当前播放器可显示“新设置将在下次播放生效”；
- 只有用户在播放器内明确点击“立即应用缓存设置”时，才允许受控重开；本轮默认不提供该按钮。

---

## 8. 缓存目录与存储探测

### 8.1 抽象

建议新增：

```text
lib/playback/cache/playback_cache_storage.dart
```

```dart
abstract interface class PlaybackCacheStorage {
  Future<PlaybackCacheStorageSnapshot> prepareSession();
  Future<int?> freeBytesFor(Directory directory);
  Future<void> cleanupSession(PlaybackCacheSession session);
  Future<void> cleanupNonActiveMarkedSessions();
}
```

默认实现复用：

```text
path_provider
disk_space_plus
dart:io
```

不新增权限和第三方依赖。

### 8.2 根目录与 marker

```text
<app-cache>/emby-playback-cache/
session-<random-id>/
```

每个应用创建的 session 目录必须包含：

```text
.emby-playback-cache-session-v1
```

marker 内容只能包含随机 session nonce 和 schema 版本，不得包含服务器、账号、itemId、媒体名称或路径。

### 8.3 播放前探测

```text
创建 session 目录
→ 写入 marker
→ 创建小型 probe 文件
→ flush
→ close
→ 重新读取长度
→ 删除 probe
→ 查询该目录所在卷可用空间
```

任一步失败：

```text
runtimeMode = memoryFallback
reason = directoryUnavailable / storageCapacityUnknown
```

`freeBytes == null` 时必须使用内存缓存，不得假定有足够磁盘空间。

### 8.4 默认 unlink 策略

正式默认：

```text
demuxer-cache-unlink-files=immediate
```

原因：缓存文件创建后立即从目录项解除链接；即使进程崩溃，操作系统也能在进程终止后释放文件。

因此：

- 正常预算监控不依赖递归目录大小；
- 使用 `demuxer-cache-state/file-cache-bytes`；
- session 目录通常只保留 marker；
- engine 关闭后删除 session 目录。

不得默认使用：

```text
whendone + 每 2 秒目录遍历
```

### 8.5 残留清理

冷启动、Session 激活和新播放开始前：

```text
扫描根目录直接子目录
→ 只接受具有合法 marker 的 session
→ 排除 activeSessionRegistry 中当前进程活动 session
→ 立即删除其他合法 session
```

不得等待 24 小时。

不得：

- 删除没有合法 marker 的目录；
- 跟随符号链接；
- 清理根目录以外路径；
- 因清理失败阻止应用启动。

### 8.6 正常退出顺序

```text
停止缓存状态观察
→ 关闭当前媒体
→ 释放 mpv 对缓存文件的引用
→ 删除 session 目录
```

不得在媒体仍打开时先切换 `cache-on-disk=no` 并假定旧文件立即关闭；mpv 只有在媒体关闭后才关闭原缓存文件。

---

## 9. 动态缓存 Profile

### 9.1 新增模型

```text
lib/playback/cache/playback_cache_policy.dart
```

```dart
enum PlaybackCacheRuntimeMode {
  disabled,
  memory,
  disk,
  memoryFallback,
  unconfirmed,
}

enum PlaybackTransportKind {
  offlineLocal,
  progressiveHttp,
  segmentedHttp,
  live,
  unknown,
}

enum PlaybackCacheFallbackReason {
  none,
  offlineMedia,
  liveOrUnknownLength,
  segmentedTransport,
  insufficientSpace,
  storageCapacityUnknown,
  directoryUnavailable,
  engineCapabilityUnavailable,
  mpvCacheCreateFailed,
  actualModeUnconfirmed,
  targetTooSmallForMinimumWindow,
  metadataBudgetLimited,
  sessionBudgetReached,
  lowSpace,
  memoryPressure,
}

class ResolvedPlaybackCacheProfile {
  final PlaybackCacheRuntimeMode runtimeMode;
  final PlaybackTransportKind transportKind;
  final PlaybackCacheFallbackReason fallbackReason;
  final Duration forwardTarget;
  final Duration backwardTarget;
  final int sessionTargetBytes;
  final int reservedFreeBytes;
  final int demuxerForwardMetadataBytes;
  final int demuxerBackwardMetadataBytes;
  final int metadataBudgetCapBytes;
  final int streamBufferBytes;
  final bool donateBuffer;
  final Directory? sessionDirectory;
}
```

### 9.2 媒体资格算法

不得仅根据 URL 后缀判断。

由 resolver 在 `PlaybackPlan` 中输出结构化 `transportKind`，综合：

```text
PlaybackMethod
resolved URI scheme
MediaSource.Protocol
MediaSource.Container
TranscodingUrl / direct stream URL
是否 LiveStream
Duration 是否有效
服务器返回的流类型
```

规则：

```text
本地离线文件
→ offlineLocal

HTTP/HTTPS + 非 live + duration > 0 + 非分段 manifest
→ progressiveHttp

HLS/m3u8/DASH/服务器分段转码
→ segmentedHttp

live 或 duration 不可用
→ live

证据不足
→ unknown
```

磁盘缓存仅允许：

```text
transportKind == progressiveHttp
且 capability 支持磁盘缓存和 native telemetry
```

其他全部使用内存或 disabled。

### 9.3 自动空间档位

| 可用空间 | 自动会话目标 | 前向 | 后向 |
|---:|---:|---:|---:|
| `< 2 GiB` | 内存模式 | 60 秒 | 30 秒 |
| `2–8 GiB` | 256 MiB | 90 秒 | 60 秒 |
| `8–24 GiB` | 512 MiB | 180 秒 | 120 秒 |
| `24–64 GiB` | 1 GiB | 300 秒 | 180 秒 |
| `>= 64 GiB` | 2 GiB | 600 秒 | 300 秒 |

```text
safeSpendable = max(0, availableBytes - reservedFreeBytes)
effectiveTarget = min(modeTarget, floor(safeSpendable * 0.25), 4 GiB)
```

若：

```text
effectiveTarget < 128 MiB
```

则：

```text
runtimeMode = memoryFallback
reason = insufficientSpace
```

### 9.4 码率缩放

从已选择 MediaSource 获取 bitrate；缺失时使用保守默认 8 Mbps。

```text
estimatedPayloadBytes
= bitrate / 8
× (forwardSeconds + backwardSeconds)
× 1.25
```

若估算值大于有效目标，先按比例缩短前向/后向目标。

磁盘模式的最低有效窗口为：

```text
前向 30 秒
后向 15 秒
```

但最低窗口不能凌驾于会话目标。必须先计算：

```text
minimumWindowBytes
= bitrate / 8
× (30 + 15)
× 1.25
```

若：

```text
minimumWindowBytes > effectiveTarget
```

则不得同时宣称“保持 30/15 秒”又“遵守会话目标”。本轮冻结为：

```text
runtimeMode = memoryFallback
fallbackReason = targetTooSmallForMinimumWindow
```

播放器继续使用保守内存 Profile；UI 显示“当前码率过高，磁盘缓存目标不足，已使用内存缓存”。不得静默突破用户目标，也不得把实际窗口压到低于 30/15 秒后仍显示磁盘模式。

### 9.5 前向/后向目标到 metadata 预算的确定性映射

本轮不宣称 metadata 预算能精确产生同等秒数。前向和后向目标由用户独立设置，因此必须独立映射，禁止使用“后向预算 × 2”推导前向预算。

前向目标映射：

| 前向目标 | demuxer-max-bytes |
|---:|---:|
| `<= 60 秒` | 16 MiB |
| `61–180 秒` | 32 MiB |
| `181–300 秒` | 64 MiB |
| `301–600 秒` | 96 MiB |
| `601–900 秒` | 128 MiB |

后向目标映射：

| 后向目标 | demuxer-max-back-bytes |
|---:|---:|
| `<= 30 秒` | 8 MiB |
| `31–60 秒` | 16 MiB |
| `61–120 秒` | 32 MiB |
| `121–300 秒` | 64 MiB |
| `301–600 秒` | 96 MiB |

总 metadata 预算必须再受平台安全上限约束：

```text
metadataBudgetCap
= clamp(
    floor(sessionTargetBytes / 8),
    32 MiB,
    128 MiB,
  )
```

解析顺序：

1. 按前向/后向表得到原始预算；
2. 若两者之和不超过 `metadataBudgetCap`，直接使用；
3. 若超过，则按前向/后向目标时长比例缩放；
4. 前向最低 16 MiB，后向最低 8 MiB；
5. 若连最低 24 MiB 都无法安全提供，则：

```text
runtimeMode = memoryFallback
fallbackReason = metadataBudgetLimited
```

所有普通模式：

```text
demuxer-donate-buffer=yes
```

本轮不增加“严格分离前后预算”的用户开关。实际后向范围以 `seekable-ranges` 为准。

iPadOS 收到 memory warning、Android 收到高等级 trim-memory 时，不得继续维持高 metadata 预算。必须通过操作协调器将总 metadata 预算降到不超过 64 MiB；若当前 Profile 无法安全原地重配，则受控重开并记录 `memoryPressure`；该重开与预算/低空间共用 `cacheSafetyReopenUsed`，每个 PlaybackItemSessionId 合计最多一次。

### 9.6 stream-buffer-size 受控实验

候选值：

```text
128 KiB（当前默认）
512 KiB
1 MiB
2 MiB
```

只对：

```text
progressive HTTP MP4
```

运行实验。

实施规则：

- 默认保持 128 KiB，除非真机/CI 证据证明更大值改善且不回归；
- 不允许未经测试直接将所有媒体设为 2 MiB；
- 最终值必须记录到计划实施证据；
- 不适用媒体显式重置为默认值。

---
