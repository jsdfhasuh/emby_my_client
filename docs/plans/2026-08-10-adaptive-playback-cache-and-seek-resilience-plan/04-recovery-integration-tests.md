## 14. Seek 后运行时错误恢复

### 14.1 恢复资格与可注入时间窗口

默认参数必须集中在可注入配置中：

```dart
class PlaybackRecoveryPolicy {
  const PlaybackRecoveryPolicy({
    this.seekRecoveryWindow = const Duration(seconds: 15),
    this.stablePlaybackWindow = const Duration(seconds: 5),
    this.fingerprintDedupeWindow = const Duration(seconds: 2),
  });

  final Duration seekRecoveryWindow;
  final Duration stablePlaybackWindow;
  final Duration fingerprintDedupeWindow;
}
```

仅当全部满足：

```text
当前 PlaybackItemSessionId 仍有效
当前 operationGeneration 未失效
播放器已进入 ready
远程 progressive HTTP
最近一次实际 engine.seek 已提交到底层
错误发生在 seekRecoveryWindow 内
Seek 后尚未连续稳定播放 stablePlaybackWindow
当前 PlaybackItemSessionId 尚未使用 runtime recovery
错误匹配批准 fingerprint
```

“连续稳定播放”至少要求：

```text
position 正常前进
无 buffering storm
无新的 engine error
无新的 Seek
```

一旦连续稳定达到 `stablePlaybackWindow`，该次 Seek 的恢复资格结束，即使仍在 15 秒绝对窗口内也不得触发恢复。

批准 fingerprint：

```text
Seek failed
partial file
Input/output error
error reading packet
```

不能仅凭任意 warning 触发。默认 15/5 秒只是产品默认，测试可注入更短窗口；不得在业务代码中散布魔数。

### 14.2 恢复状态与错误拦截顺序

`PlaybackPhase` 必须增加：

```text
recoveryPending
recovering
```

当前基线中 ready 后的 engine error 会直接进入 failed。本轮必须改为：

```text
收到批准 fingerprint
→ 先冻结错误，不写 PlaybackPhase.failed
→ 进入 recoveryPending
→ 交给 PlaybackOperationCoordinator 判断资格和预算
→ 符合资格则进入 recovering
→ 只有不符合资格、超出预算或恢复最终失败
→ 才进入 PlaybackPhase.failed
```

`recoveryPending` / `recovering` 期间：

- UI 显示固定恢复状态，不弹最终错误；
- 自动关闭播放器逻辑不得提前执行；
- 用户返回、item switch 和 shutdown 仍具有最高优先级；
- 旧错误事件不得覆盖恢复后的新状态。

### 14.3 错误去重

`engine.errorStream` 与 `engine.logStream` 可能报告同一故障。

规则：

```text
同一 normalized fingerprint
同一 PlaybackItemSessionId
同一 operationGeneration
fingerprintDedupeWindow 内
→ 仅生成 1 个 recovery request
```

恢复开始后，旧 operationGeneration 的后续日志不得再次触发。错误流和日志流必须先归一化，再进入同一个去重器；不得分别各发起一次恢复。

### 14.4 恢复事务

保存：

```text
latest requested/committed target
原播放/暂停状态
media source
音轨
字幕
倍速
最大码率
缓存设置
```

事务：

```text
进入 operation coordinator
→ status = 正在恢复播放…
→ 失效 pending seek
→ reporter.stop/cleanup 旧 plan（精确一次）
→ 停止缓存 monitor
→ 关闭当前媒体
→ 清理当前 cache session
→ 重新 resolve 同一 item
→ 先用适用的安全 Profile 重开
→ seek 到最新目标
→ 恢复音轨/字幕/倍速/播放状态
→ reporter.activate/reportStart 新 plan（精确一次）
```

### 14.5 重试预算

预算绑定到稳定的 `PlaybackItemSessionId`：

```text
runtimeSameMethodRecoveryUsed <= 1
runtimeTranscodeRecoveryUsed <= 1
automaticOpenCount <= 6
```

若原方法为 DirectPlay：

1. 首先重开同一 DirectPlay，消耗 `runtimeSameMethodRecoveryUsed`；
2. 若重开启动失败且服务器支持转码，最多再 force-transcode 一次，消耗 `runtimeTranscodeRecoveryUsed`；
3. force-transcode 失败后终止。

若原方法已经是 transcode：

- 只允许同方法重开一次；
- 不允许再产生第二层回退。

startup fallback、cache-create retry、cache safety reopen、memory-pressure reopen 与 runtime recovery 共享 `automaticOpenCount` 总预算；任何内部重开导致的 generation 变化都不得恢复预算。达到 6 次后直接进入固定失败状态并记录 `automaticOpenBudgetExhausted`。

### 14.6 生命周期

若应用处于 inactive/paused：

- 不立即启动新的网络恢复；
- 记录 pending recovery；
- 返回 resumed 且 route/item 仍有效后执行；
- 用户关闭路由时取消。

### 14.7 失败 UX

恢复中：

```text
正在恢复播放…
```

最终失败：

```text
播放连接异常，自动恢复失败，请返回后重试
```

不得展示原始 libmpv/FFmpeg 文本。

---

## 15. PlaybackController / PlayerScreen 集成流程

### 15.1 新媒体启动

```text
PlayerSessionCoordinator 创建 PlaybackItemSessionId
→ load latest PlaybackSettingsRepository snapshot
→ resolve PlaybackPlan
→ derive transportKind and preliminary media eligibility
→ probe/reuse MpvCacheCapabilities
→ if disk is still eligible: prepare cache session and read free space for that volume
→ 计算 lowSpaceTrigger，若已触发则不启用磁盘
→ resolve the final PlaybackCacheProfile from settings + plan + capabilities + storage snapshot
→ 根据 profileSwitchStrategy 选择同 Player 配置或创建新 Player
→ configure complete engine Profile（每个 native 操作均有 timeout）
→ read back critical properties
→ reporter.activate(plan)
→ engine.open（计入 PlaybackItemSessionId 的 automaticOpenCount）
→ wait ready
→ if cache-create-failed but ready: 验证 actual mode，必要时显示 unconfirmed，继续播放
→ start cache monitoring
```

不得在目录可写性、卷可用空间和实际 libmpv 能力尚未确定时解析最终磁盘 Profile；明确为内存、直播、HLS、离线或能力不足的媒体不得创建无用的磁盘 session。缓存创建失败但 ready 时不得直接把 actual mode 写成 memoryFallback。

### 15.2 reconfigure

```text
进入 PlaybackOperationCoordinator
→ 失效 pending seek
→ 停止 monitor
→ reporter.stop 旧 plan（3 秒 timeout）
→ 关闭旧媒体（5 秒 timeout）
→ 清理旧 cache session（3 秒 timeout）
→ resolve 新 plan/profile
→ 若 profileSwitchStrategy 要求则请求 PlayerSessionCoordinator 重建底层 Player
→ 写入完整 Profile（native read/write 1 秒 timeout）
→ open + restore position/state
```

该流程保留原 `PlaybackItemSessionId`，不得重置任何自动 fallback/recovery 预算。

### 15.3 item switch

```text
进入 PlayerSessionCoordinator
→ 禁止旧 Session 接收新操作
→ 取消旧 item 的 pending seek/recovery，并完成 cancelled
→ await old controller.shutdown（受总 timeout 保护）
→ await old player.dispose（5 秒 timeout）
→ 尽力确认旧 cache session 已清理
→ 即使旧清理超时也不得无限期阻塞路由退出或新媒体启动
→ 为新 item 创建新的 PlaybackItemSessionId
→ 创建新 player/controller
→ 加载最新 settings revision
→ 启动新 item
```

### 15.4 shutdown

```text
禁止新操作
→ 立即完成所有 pending seek/recovery 为 cancelled
→ 停止 cache monitor
→ reporter.stop（3 秒 timeout）
→ engine.stop（5 秒 timeout）
→ engine.dispose（5 秒 timeout）
→ cleanup cache session（3 秒 timeout）
→ state idle
→ 允许路由退出
```

所有步骤必须幂等。任何单一步骤超时或失败都不得阻止后续步骤和路由退出；迟到 Future 不得再写回状态。

---

## 16. 诊断、安全与仅验收测试控制

### 16.1 PlaybackDiagnosticsTestOverrides

为使真机验收可重复执行，新增仅从诊断页面进入的临时测试控制：

```dart
class PlaybackDiagnosticsTestOverrides {
  final int? streamBufferBytes;
  final int? sessionTargetBytes;
  final PlaybackCacheStorageSnapshot? simulatedStorage;
  final bool injectApprovedSeekFailureAfterNextExecutedSeek;
  final bool forceCacheCreateFailureObservation;
}
```

允许操作：

```text
下一次播放临时覆盖 stream-buffer-size
下一次播放临时使用较小会话目标
下一次播放模拟指定 storage snapshot
下一次实际执行的 Seek 后注入一个批准 fingerprint
模拟观察到 cache create failed（不伪造 native 成功状态）
清除全部测试覆盖
```

安全规则：

- 仅从诊断页的“播放验收测试”入口进入；
- 普通设置页不显示；
- 默认关闭；
- 每项覆盖均有醒目标识和二次确认；
- 只作用于下一次播放或当前明确的测试 Session；
- 应用重启、退出登录、切换账号或点击清除后全部失效；
- 不写入正常 `PlaybackSettings`；
- 不上传或导出媒体标识；
- 诊断只记录 `testOverrideActive=true` 及覆盖类型枚举；
- 生产正常播放不能自动启用任何覆盖。

用于真机验证：

- 128 KiB / 512 KiB / 1 MiB / 2 MiB 实验；
- 低空间提前保护；
- 会话预算降级；
- approved fingerprint 的 recoveryPending / recovering / success/failure；
- Gate B 条件项在没有自然故障时仍能通过安全故障注入验证。

### 16.2 固定诊断事件

新增固定事件：

```text
playback_cache_capabilities_resolved
playback_cache_profile_switch_strategy_resolved
playback_cache_settings_loaded
playback_cache_profile_resolved
playback_cache_directory_ready
playback_cache_directory_failed
playback_cache_disk_enabled
playback_cache_memory_fallback
playback_cache_actual_mode_unconfirmed
playback_cache_mpv_create_failed
playback_cache_budget_guard_reached
playback_cache_low_space
playback_cache_memory_pressure
playback_cache_session_cleaned
playback_cache_stale_cleanup
playback_cache_snapshot_unavailable
playback_operation_timeout
playback_automatic_open_budget_exhausted
playback_test_override_enabled
playback_test_override_cleared
playback_seek_requested
playback_seek_coalesced
playback_seek_executed
playback_seek_failed
playback_seek_cancelled
playback_seek_recovery_pending
playback_seek_recovery_started
playback_seek_recovery_succeeded
playback_seek_recovery_failed
```

允许记录：

```text
mpv version fingerprint
platform
capability booleans
mode/runtime mode
forward/back target bucket
actual seekable range bucket
session target bucket
file cache bytes bucket
free space bucket
fallback reason
profile switch strategy
operation timeout kind
automatic open count bucket
memory pressure level bucket
seek requested/executed/superseded/failed counts
error fingerprint
test override type（仅枚举）
```

禁止记录：

```text
完整缓存路径
服务器 URL
媒体 URL
用户名
密码
Token
设备 ID
媒体名称
itemId
真实文件名
Authorization
```

缓存路径只允许记录：

```text
cacheDirectoryReady=true/false
```

日志限流：

- 同 fingerprint 2 秒最多一次；
- budget/low-space 每 session 最多一次；
- seek progress 不得每个 position event 写日志；
- 100 次 UI 请求应输出聚合计数，不得写 100 条含目标明细日志；
- 测试覆盖只记录类型和启用状态，不记录注入目标、媒体或路径。

---

## 17. 自动测试矩阵

当前 Flutter 基线：

```text
639 tests
0 skip
```

最终必须高于 639，且不得删除、skip 或弱化现有断言。

### 17.1 能力与双门禁

- option-info 对所有必需选项返回支持；
- `demuxer-cache-unlink-files` choices 明确包含 `immediate`；
- property-list 包含必需 property；
- mpv-version/platform 读取；
- native node map 解析；
- field 暂时缺失与真正不支持区分；
- disk → stop → memory → stop → disabled 的 Profile 切换实验；
- 同一 Player 可切换时判定 `inPlaceAfterMediaStop`；
- 只有重建 Player 后可切换时判定 `requiresPlayerRecreation`；
- 两种方式均失败时判定 `unsupported`；
- 磁盘能力不足时 `STOP_GATE_DISK_CACHE_CAPABILITY=BLOCKED`；
- 磁盘能力不足时 Seek/内存缓存实现和测试仍继续，不得提前结束全部任务；
- iOS RunnerTests 使用实际链接 libmpv；
- Android 对打包 libmpv 至少完成可启动的 native capability smoke test；
- 运行时 capability diagnostics 不含敏感字段。

### 17.2 设置与 Repository

- 旧 v1 JSON 无 cache 字段；
- cache 子对象损坏只回退 cache；
- 所有模式 round-trip；
- 范围 clamp；
- 字段级 patch；
- 100 次并发 patch 串行；
- 播放器旧快照 + 设置页 cache + 播放器 rate 不互相覆盖；
- `load / patch / clear / deleteAccountSettings` 使用同一 per-account 队列；
- clear 递增 generation，使旧 patch 完成 invalidated/cancelled；
- clear 后迟到 patch 不得重新创建 key；
- delete account 与 sign-out 等待清理队列完成；
- Repository dispose 后不接受新写入。

### 17.3 存储

- 创建 marker/probe；
- flush/读取/删除；
- free space null → memoryFallback；
- 目录不可写 → memoryFallback；
- immediate unlink Profile；
- 冷启动清理全部合法非 active session；
- 无 marker 目录不删除；
- symlink 不跟随；
- engine 关闭前不 cleanup；
- cleanup 失败不影响 route close；
- 开始磁盘 session 前使用 `reserved + lowSpaceGuard` 提前判定；
- 低空间触发发生在侵入 reservedFreeBytes 之前。

### 17.4 Profile 解析

- 存储快照前不得生成最终磁盘 Profile；
- 明确非磁盘媒体不得创建 session 目录；

覆盖：

```text
<2 GiB
2–8 GiB
8–24 GiB
24–64 GiB
>=64 GiB
freeBytes=null
```

以及：

- reserved space 优先；
- 用户目标超过安全空间；
- bitrate 缺失/低/高；
- forward/back 比例缩放；
- 最低 30/15 秒仍超过 target → `targetTooSmallForMinimumWindow` + memoryFallback；
- 前向目标独立映射 `demuxer-max-bytes`；
- 后向目标独立映射 `demuxer-max-back-bytes`；
- 总 metadata 受 `metadataBudgetCap` 限制；
- metadata 最低预算无法满足 → `metadataBudgetLimited`；
- memory warning / trim-memory 触发 <=64 MiB 安全 Profile；
- DirectPlay progressive；
- DirectStream progressive；
- HLS/DASH/transcode；
- offline；
- live/unknown duration；
- transport evidence 不足；
- stream-buffer-size 4 个候选矩阵。

### 17.5 Engine 完整 Profile 与实际模式

- 磁盘 Profile 全属性；
- 内存 Profile 显式清除磁盘状态；
- disabled Profile 显式重置；
- 媒体 A disk → 媒体 B offline 不残留 cache-on-disk；
- 属性在 open 前写入；
- native property read/write 1 秒 timeout；
- read-back；
- 关键属性失败 → memory fallback；
- `requiresPlayerRecreation` 时重建 Player 且保留 PlaybackItemSessionId；
- cache create failed + ready → 不重开；
- cache create failed 后 read-back 确认 memory → memoryFallback；
- cache create failed 但无法确认 → runtimeMode=unconfirmed，不伪称内存；
- cache create failed + startup failure → 每 Session 只重开一次；
- automatic open 总数永不超过 6。

### 17.6 Cache state、预算与空间保护

- file-cache-bytes 解析；
- seekable-ranges 合并；
- actual forward/back 计算；
- raw-input-rate 缺失 fallback；
- 动态 budget guard；
- fake rate/close latency 下超调符合公式；
- lowSpaceGuard 按 10 秒空间轮询 + 关闭时延计算；
- reserved free bytes 永不被用户设置关闭；
- budget/low-space 共享一次 `cacheSafetyReopen`；
- memory pressure 与 budget/low-space 共用 `cacheSafetyReopenUsed`，合计最多一次；
- low-space 优先；
- 只有 executed seek 触发额外检查；
- 100 个请求合并为 2 个 executed 时只额外检查 2 次；
- 开始播放、executed seek、resume、reopen 前均执行空间检查；
- background/resume Timer 不重复；
- 100 次打开/关闭无 session/Timer 残留。

### 17.7 Seek 确定性压力与超时

```text
阻塞第 1 次 engine.seek
提交 99 次新请求
释放第 1 次
```

断言：

```text
engine.seek calls = 2
max concurrent = 1
final target = request 100
所有 Future 已完成
superseded count = 98
```

还需覆盖：

- 连续 relative +10 秒累积到 +100 秒；
- absolute 覆盖 pending relative；
- requested/preview/committed UI 优先级；
- 旧 position stream 不拉回；
- 横向手势 generation；
- 双击 + 横向；
- 远程 Seek + 手势；
- chapter + pending；
- cache fallback + pending seek；
- bitrate reconfigure + seek；
- item switch + seek；
- shutdown + seek；
- engine.seek call 超过 8 秒 → failed(callTimeout)，不得 executed；
- settle 超过 2 秒 → failed(settleTimeout)；
- shutdown 到达后 pending 立即 cancelled，不等待完整 8 秒；
- stop/dispose/reporter/cleanup timeout 后路由仍可退出；
- 迟到 native 事件不写回；
- no unhandled Future error。

### 17.8 运行时恢复

- 注入的 seekRecoveryWindow / stablePlaybackWindow 生效；
- 窗口内批准 fingerprint 且尚未稳定播放 → recoveryPending；
- 连续稳定播放达到 stablePlaybackWindow 后不恢复；
- 绝对恢复窗口外不恢复；
- 非 progressive 不恢复；
- error/log 同 fingerprint 只触发一次；
- 可恢复错误不得先进入 failed；
- recoveryPending → recovering → ready 状态顺序；
- DirectPlay 同方法恢复成功；
- 同方法失败后 force-transcode 一次；
- transcode 媒体只重开一次；
- PlaybackItemSessionId 在内部重开中保持不变；
- generation 改变不重置恢复预算；
- automaticOpenCount 上限 6；
- reporter stop/activate 精确次数；
- 保留音轨/字幕/倍速/暂停状态；
- inactive 延迟至 resumed；
- user back 优先取消；
- 第二次错误或预算耗尽进入固定失败状态。

### 17.9 Test Overrides、Widget 与 UX

- 诊断页存在独立“播放验收测试”入口；
- 普通设置页看不到 Test Overrides；
- stream-buffer-size 一次性覆盖；
- 小 session target 覆盖；
- simulated storage snapshot；
- 下一次 executed seek 后注入 approved fingerprint；
- 覆盖在重启、退出登录和清除后失效；
- 覆盖不写入正常 PlaybackSettings；
- 正常日志只记录覆盖类型枚举；
- 设置入口；
- 预设/自定义；
- 自定义字段仅 custom 显示；
- 可用空间 unknown 文案；
- 目标值与实际范围分开；
- actual mode unconfirmed 文案正确；
- “正在调整缓存…”；
- “正在恢复播放…”；
- 设置保存不打断当前播放；
- iPad 横竖屏、Android 手机无 overflow；
- textScaleFactor 2.0；
- 位置偏差在 fake recovery 中 <=2 秒；
- no duplicate dialog / no double pop。

### 17.10 回归

必须继续通过：

```text
登录 / Keychain
Session 恢复
iPad 键盘
播放退出方向恢复
完整播放队列
音轨/字幕/画质切换
安全诊断
完整诊断导出
Android UDP 发现
媒体库与图片整改全部测试
```

---
