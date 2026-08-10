## 10. mpv Engine 适配与完整 Profile 重置

### 10.1 PlaybackEngine 接口

建议扩展：

```dart
Future<PlaybackCacheApplyResult> configureCache(
  ResolvedPlaybackCacheProfile profile,
);

Future<PlaybackCacheEngineSnapshot?> readCacheSnapshot();

Stream<PlaybackCacheEngineEvent> get cacheEvents;

Future<PlaybackCacheEngineCapabilities> probeCacheCapabilities();
```

`configureCache` 必须遵守 `profileSwitchStrategy`：

```text
inPlaceAfterMediaStop
→ 当前媒体已 stop 后可在同一 NativePlayer 写入完整新 Profile

requiresPlayerRecreation
→ 不得在旧 Player 上尝试半切换
→ 交给 PlayerSessionCoordinator 重新创建 Player
→ 内部重建仍沿用同一 PlaybackItemSessionId

unsupported
→ 磁盘 Profile 禁用，继续使用内存 Profile
```

所有 native property read/write 必须由统一 timeout wrapper 执行，不得在业务代码中无限等待。

### 10.2 强类型运行状态

```dart
class PlaybackCacheEngineSnapshot {
  final int? fileCacheBytes;
  final int? rawInputRateBytesPerSecond;
  final List<PlaybackCacheRange> seekableRanges;
  final bool pausedForCache;
  final int? cacheBufferingPercent;
}
```

原生 node 解析必须：

- 验证类型；
- 忽略未知字段；
- 缺失字段返回 null；
- 不因单个字段损坏使播放失败。

### 10.3 每次 open 前写入完整 Profile

不能依赖上一个媒体的残留属性。

#### 磁盘 Profile

```text
cache=yes
cache-on-disk=yes
demuxer-cache-dir=<session directory>
demuxer-cache-unlink-files=immediate
cache-secs=<effective forward seconds>
demuxer-max-bytes=<forward metadata budget>
demuxer-max-back-bytes=<backward metadata budget>
demuxer-donate-buffer=yes
demuxer-seekable-cache=auto
cache-pause=yes
cache-pause-wait=1
stream-buffer-size=<resolved value>
```

#### 内存 Profile

```text
cache=yes
cache-on-disk=no
demuxer-cache-dir=<empty/default reset value approved by capability probe>
demuxer-cache-unlink-files=immediate
cache-secs=<30–60 seconds>
demuxer-max-bytes<=64 MiB
demuxer-max-back-bytes<=16 MiB
demuxer-donate-buffer=yes
demuxer-seekable-cache=auto
cache-pause=yes
cache-pause-wait=1
stream-buffer-size=<resolved/default>
```

#### 离线/disabled Profile

```text
cache=no
cache-on-disk=no
demuxer-cache-dir=<reset>
cache-secs=0 或当前 libmpv 批准的 disabled 值
demuxer-max-bytes=<安全默认>
demuxer-max-back-bytes=<安全默认>
demuxer-donate-buffer=yes
demuxer-seekable-cache=auto
cache-pause=no
stream-buffer-size=128 KiB
```

所有 reset 值必须经过 C0 能力探测确认。

若 `profileSwitchStrategy = requiresPlayerRecreation`，上述“完整重置”由新建 Player 的初始 Profile 完成；不得为了避免重建而把旧磁盘目录或 `cache-on-disk=yes` 留在原 Player 中。

### 10.4 应用顺序

```text
媒体已经关闭
→ 写入完整 Profile
→ 读回关键 option 值
→ 确认 generation 未失效
→ player.open
```

关键读回：

```text
cache
cache-on-disk
demuxer-cache-dir
demuxer-cache-unlink-files
cache-secs
```

可选属性失败可以降级；关键磁盘属性失败时改为内存 Profile，再读回一次。

### 10.5 缓存创建失败状态机

收到：

```text
Failed to create file cache
```

必须先：

```text
标记 diskCacheFailureObserved = true
fallbackReason = mpvCacheCreateFailed
不立即中止当前 open
不立即宣称 actual runtime mode = memoryFallback
```

随后通过以下证据确认实际模式：

```text
cache-on-disk read-back
demuxer-cache-state
file-cache-bytes（若能力支持）
```

判定：

```text
cache-on-disk 已明确为 no
→ actual runtime mode = memoryFallback

file-cache-bytes 可用且 > 0
→ actual runtime mode = disk
→ 将该日志记录为非致命告警并继续观察

无法确认
→ actual runtime mode = unconfirmed
→ fallbackReason = actualModeUnconfirmed
```

UI 在无法确认时只能显示：

```text
磁盘缓存创建失败，当前缓存模式暂无法确认
```

不得显示“已使用内存缓存”。

后续：

```text
若当前媒体仍成功 ready
→ 继续播放，不重开

若同时发生 startup timeout / open failure
→ 每个 PlaybackItemSessionId 最多一次使用显式 memory Profile 重开
```

重开后必须再次 read-back；只有确认 `cache-on-disk=no` 后，才能显示 `memoryFallback`。generation 仅用于屏蔽旧异步结果，不得重置该一次性预算。

---

## 11. 缓存状态监控与空间保护

### 11.1 新增协调器

```text
lib/playback/cache/playback_cache_coordinator.dart
```

职责：

- 持有当前 cache session；
- 解析并应用 Profile；
- 读取 `demuxer-cache-state`；
- 计算实际可前向/后向 Seek 范围；
- 监控 `file-cache-bytes`；
- 监控设备可用空间；
- 触发一次受控内存降级；
- 关闭后清理 session。

### 11.2 采样频率

磁盘缓存实际启用时：

```text
每 1 秒读取一次 demuxer-cache-state
每 10 秒读取一次卷可用空间
每次实际执行并完成的 engine.seek 后额外读取一次
应用恢复前台后立即读取一次
```

说明：

- 100 个 UI Seek 请求若合并为 2 个 engine.seek，只额外检查 2 次；
- superseded 请求不得触发文件系统或 native property 检查；
- 后台暂停高频 Timer；
- 同一时间只能有一个状态 Timer 和一个空间 Timer。

### 11.3 实际范围计算

从 `seekable-ranges` 中找到包含当前 committed position 的范围：

```text
actualBackward = committedPosition - range.start
actualForward = range.end - committedPosition
```

若多个范围重叠，先归一化/合并；若当前 position 不在任何范围，实际前后范围显示不可用。

### 11.4 动态 guard

```text
pollInterval = 1 秒
expectedCloseLatency = 2 秒
rate = rawInputRate ?? max(mediaBitrate / 8 * 2, 8 MiB/s)
rawGuard = rate * (pollInterval + expectedCloseLatency)
guardBytes = clamp(rawGuard, 32 MiB, min(256 MiB, target / 2))
stopThreshold = max(64 MiB, target - guardBytes)
```

当：

```text
fileCacheBytes >= stopThreshold
```

排队执行受控降级。

`target` 是 best-effort 目标。自动测试不得要求所有真实网络下绝对不超过固定 64 MiB；应验证：

```text
实际超调 <= 模拟输入率 × 模拟关闭延迟 + 明确容差
```

### 11.5 强制保留空间

不能等到已经侵入 `reservedFreeBytes` 才开始关闭媒体。必须提前计算：

```text
spacePollInterval = 10 秒
expectedCloseLatency = 2 秒
rate = rawInputRate ?? max(mediaBitrate / 8 * 2, 8 MiB/s)
lowSpaceGuardBytes
= clamp(
    rate × (spacePollInterval + expectedCloseLatency),
    64 MiB,
    512 MiB,
  )

lowSpaceTrigger
= reservedFreeBytes + lowSpaceGuardBytes
```

当：

```text
availableBytes <= lowSpaceTrigger
```

即触发受控内存降级。若开始播放前已经：

```text
availableBytes <= lowSpaceTrigger
```

则不得启用磁盘缓存。

空间还必须在以下时机立即检查，而不能只依赖 10 秒 Timer：

```text
开始创建磁盘缓存 session 前
每次实际执行并完成的 engine.seek 后
应用恢复前台后
任何缓存重开或 runtime recovery 前
```

硬安全规则：

- 用户不能关闭该保护；
- 低空间优先级高于普通预算目标；
- 触发后禁止创建新的磁盘 session；
- 若检查时已经低于 `reservedFreeBytes`，立即进入最高优先级降级，并记录安全告警；
- 自动测试必须验证触发发生在侵入保留空间之前。

### 11.6 受控内存降级 UX

开始：

```text
statusMessage = 正在调整缓存…
```

完成：

- 不弹错误框；
- 恢复原播放/暂停状态；
- 位置偏差目标 `<= 2 秒`；
- 一次重开最多出现一次 buffering 过渡；
- 不能重复闪黑；
- 超过 15 秒未恢复才进入固定失败状态。

预算达到、低空间与内存压力降级共享同一 `cacheSafetyReopenUsed` 一次性预算；每个 `PlaybackItemSessionId` 合计最多一次。generation 改变不得重置该预算。

### 11.7 metadata 内存压力保护

增加平台内存压力信号：

```text
iPadOS：didReceiveMemoryWarning 或等价 Flutter/native bridge
Android：onTrimMemory 的高等级事件
```

触发后：

- 停止扩大 metadata 预算；
- 将总 metadata 目标降到不超过 64 MiB；
- 若当前 libmpv 支持安全原地重配，则在媒体 stop 后应用；
- 否则通过操作协调器受控重开；
- 与预算/低空间共用 `cacheSafetyReopenUsed`，每个 `PlaybackItemSessionId` 合计最多一次；
- 不得同时与低空间、runtime recovery 或 item switch 并发；
- 内存压力处理失败不得阻止用户退出播放器。

诊断只记录压力等级、旧/新预算桶和结果，不记录媒体信息。

---

## 12. 两层播放操作协调器与稳定 Session 身份

当前职责跨越 `PlaybackController` 与 `PlayerScreen`，必须拆成两层；一次性预算必须绑定到稳定媒体 Session，而不是可变化的 generation。

### 12.1 PlaybackItemSessionId

建议新增：

```dart
class PlaybackItemSessionId {
  const PlaybackItemSessionId(this.value);
  final String value;
}
```

生命周期：

```text
进入一个媒体并准备首次 open
→ 创建新的 PlaybackItemSessionId

内部 Seek
码率/音轨/字幕重配置
缓存创建失败后的内存重试
缓存预算或低空间降级
DirectPlay 同方法重开
force-transcode
runtime recovery
Player 因 profileSwitchStrategy 要求而重建
→ PlaybackItemSessionId 均不变化

切换到上一/下一媒体
退出后重新进入该媒体
→ 才创建新的 PlaybackItemSessionId
```

`generation` 只负责屏蔽旧异步结果，禁止用于重置重试预算。

每个 `PlaybackItemSessionId` 持有：

```text
diskCacheCreateFallbackUsed <= 1
cacheSafetyReopenUsed <= 1（预算 / 低空间 / 内存压力共享）
startupTranscodeFallbackUsed <= 1
runtimeSameMethodRecoveryUsed <= 1
runtimeTranscodeRecoveryUsed <= 1
automaticOpenCount
```

非用户主动触发的 `engine.open` 总预算冻结为：

```text
initial open                                      1
cache-create startup memory retry                 1
startup force-transcode fallback                  1
cache budget / low-space safety reopen（共享）     1
runtime same-method recovery                      1
runtime force-transcode recovery                  1
---------------------------------------------------
每个 PlaybackItemSessionId 最大 automatic opens = 6
```

未使用的预算可以为空，但不能互相递归或因 generation 改变而恢复。用户主动切换码率、音轨或媒体源不计入该自动预算，但仍必须经过统一操作协调器，并且不能重置任何自动预算。

### 12.2 PlaybackOperationCoordinator

所有权：

```text
PlaybackController
单 item session
单逻辑播放引擎
```

管理：

```text
seek
reconfigure
cache fallback reopen
memory-pressure reopen
runtime error recovery
shutdown
```

若 `profileSwitchStrategy = requiresPlayerRecreation`，协调器向 `PlayerSessionCoordinator` 请求重建底层 Player，但逻辑 `PlaybackItemSessionId` 保持不变。

协调器维护单调递增的：

```text
operationGeneration
```

每个异步操作开始时捕获 token。更高优先级操作、重建 Player、item switch 或 shutdown 会递增 `operationGeneration`；任何 token 不匹配的迟到 position、error、property、reporter 或 cleanup 结果都必须丢弃。

### 12.3 PlayerSessionCoordinator

所有权：

```text
PlayerScreen
跨 item / 跨 controller / 跨底层 Player
```

管理：

```text
创建并持有 PlaybackItemSessionId
旧 controller shutdown
旧 player dispose
按要求重建同一 item 的底层 Player
创建新 player
启动新 controller
播放队列 next/previous
路由关闭
```

“同一 item 内为切换 Profile 而重建 Player”与“切换到另一个媒体”必须使用不同 API，前者保留 SessionId，后者创建新 SessionId。

### 12.4 固定优先级

```text
shutdown / item switch
> runtime recovery
> memory pressure / low-space / cache budget fallback
> user reconfigure
> seek
```

行为：

- 高优先级操作使低优先级 pending generation 失效；
- seek 不得阻塞 shutdown；
- 旧 item 的恢复不能覆盖新 item；
- item switch 必须等旧 controller 关闭和 cache session 清理进入终态后创建新 player；
- shutdown 到达后立即拒绝新操作，并将所有尚未提交的 Seek 完成 `cancelled`。

### 12.5 超时与强制退出契约

所有 native/engine 操作必须有明确 deadline：

```text
native property read/write timeout = 1 秒
engine.seek call timeout = 8 秒
seek settle timeout = 2 秒
engine.stop timeout = 5 秒
engine.dispose timeout = 5 秒
reporter stop/cleanup timeout = 3 秒
cache session cleanup timeout = 3 秒
```

规则：

```text
shutdown 到达
→ 立即取消 pending Seek / recovery / reconfigure
→ 不再接受新操作
→ in-flight Seek 超过 deadline 后不再等待
→ 继续 stop / dispose
→ 即使 stop、dispose、reporter 或 cleanup 超时，路由仍必须可退出
```

超时操作必须记录固定失败类型，不能把原始异常展示给用户。已经超时的 Seek 不得返回 `executed`，迟到结果不得写回 position、state 或 reporter。

---

## 13. Seek 调度契约

### 13.1 结果类型

```dart
enum SeekDisposition {
  executed,
  superseded,
  cancelled,
  failed,
}

enum SeekFailureKind {
  engineError,
  callTimeout,
  settleTimeout,
  higherPriorityOperation,
  staleSession,
}

class SeekResult {
  const SeekResult({
    required this.disposition,
    required this.requestedTarget,
    required this.settled,
    this.committedPosition,
    this.failureKind,
  });

  final SeekDisposition disposition;
  final Duration requestedTarget;
  final bool settled;
  final Duration? committedPosition;
  final SeekFailureKind? failureKind;
}
```

所有 Seek Future 必须最终完成：

- 实际提交并在容差内 settle：`executed, settled=true`；
- 实际提交但 settle 超时：`failed, failureKind=settleTimeout`；
- engine call 超时或抛错：`failed`；
- 在提交前被更新目标替代：`superseded`；
- shutdown/item switch/session 失效：`cancelled`。

不得让旧 Future 永久等待，也不得把 `superseded` 或 `cancelled` 当成播放错误。超时或失败的 Seek 不得伪装为 `executed`。

### 13.2 API

```dart
Future<SeekResult> seekAbsolute(
  Duration target, {
  required SeekSource source,
});

Future<SeekResult> seekRelative(
  Duration delta, {
  required SeekSource source,
});
```

### 13.3 single-flight + latest-wins

```text
同一时间最多 1 个 engine.seek
in-flight 期间只保留 1 个 pending latest target
新 pending 替换旧 pending 时，旧 pending Future 立即完成 superseded
in-flight 完成后仅执行最终 pending target
```

若 in-flight Seek call 超时：

- 当前请求完成 `failed(callTimeout)`；
- pending latest target 不得与超时调用并发执行；
- 必须先由操作协调器决定恢复、重建引擎或取消；
- shutdown / item switch 始终可以越过该等待并继续强制清理。

确定性压力测试：

```text
阻塞第 1 次 engine.seek
期间提交其余 99 次
释放第 1 次

期望：
engine.seek 精确执行 2 次
最大并发 = 1
最终目标 = 第 100 个请求
98 个中间 pending 请求完成 superseded
无未完成 Future
```

### 13.4 相对 Seek 累积

连续相对 Seek 的基准：

```text
latestRequestedPosition
否则 pending target
否则 committedPosition
```

例如连续双击 10 次 `+10 秒`：

```text
最终目标 = 基准 +100 秒
```

不得每次都以旧 engine position 计算成同一个 `+10 秒`。

### 13.5 位置状态

明确区分：

```text
committedPosition = engine 已确认位置
requestedPosition = 最近请求的目标
previewPosition = 当前手势拖动预览
```

UI 优先级：

```text
previewPosition
→ requestedPosition（pending/in-flight）
→ committedPosition
```

pending Seek 期间，旧 position stream 事件不得把 UI 拉回旧位置。

Seek 提交后：

- `engine.seek()` 调用本身最多等待 8 秒；
- 调用成功后等待 engine position 到达目标容差；
- 默认容差 `2 秒`；
- settle timeout `2 秒`；
- call timeout 或 settle timeout 均不产生第二个并发 Seek；
- 失败结果交给批准的恢复策略判断；
- shutdown 到达时不再等待剩余 timeout，pending 立即 cancelled；
- 迟到的 native position/error 事件必须按 `PlaybackItemSessionId + operationGeneration` 丢弃。

### 13.6 所有入口

必须统一进入调度器：

```text
横向滑动
双击快进/后退
进度条
章节
跳过片头
远程 WebSocket Seek
恢复播放位置
错误恢复位置
```

### 13.7 页面手势 generation

- 手势结束后先结束 preview 状态，再提交 target；
- 每个手势使用 generation；
- 旧 Future 返回不得清除新 preview；
- 旧 Seek 不得覆盖新 requested position；
- item switch、route close、dispose 后不得回写。

---
