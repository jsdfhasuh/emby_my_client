# 2026-08-10 自适应播放缓存与连续 Seek 稳定性整改计划（最终修订版）

## 0. 文档状态与权威性

```text
plan_status = READY_FOR_OWNER_FREEZE
repository = jsdfhasuh/emby_my_client
implementation_branch = agent/ios-core-real-device-remediation
code_baseline = 66232fc4ff8cf1f71068322abf67a69cf82a687d
implementation_start_head = BRANCH_HEAD_AFTER_PLAN_FREEZE
```

`implementation_start_head` 不在本文档中填写自引用提交 SHA。原因是：一旦修改文档写入“当前计划提交 SHA”，又会产生新的提交，文档内 SHA 会再次过期。

冻结规则如下：

1. 本文档提交并推送后，以该分支远端最新 HEAD 作为真实 `implementation_start_head`；
2. 真实 SHA 必须写入后续 Codex/Sol 执行提示词、Owner 检查记录和实施报告；
3. 实施不得回退到 `code_baseline`；
4. 不得 amend、rebase、force push 或重写已经推送的历史；
5. 若执行提示词中的 SHA 与远端分支 HEAD 不一致，必须停止，不得自行猜测。

当前门禁：

```text
STOP_GATE_B = BLOCKED_BY_RUNTIME_PLAYBACK_DEFECT
STOP_GATE_DISK_CACHE_CAPABILITY = NOT_RUN
STOP_GATE_SEEK_STABILITY = BLOCKED_BY_IMPLEMENTATION
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

Run 68/69 只能作为本轮缓存与连续 Seek 整改前的历史候选，不再作为最终 Gate B 构建。

### 0.1 本修订版关闭的计划缺口

本修订版明确补齐：

```text
1. 消除 implementation_start_head 自引用；
2. 增加当前捆绑 libmpv 的能力探测门禁；
3. 默认使用 immediate unlink 与 demuxer-cache-state 监控；
4. 将用户“后向秒数”映射为实际 metadata 预算，并显示真实 seekable range；
5. 每次打开媒体完整重置全部缓存 Profile；
6. 缓存创建失败不再立即中断原本可成功的启动；
7. 会话目标改为 best-effort，并增加动态 guard；
8. 冷启动立即清理合法 marker 的非活动残留，不再等待 24 小时；
9. 增加 PlaybackSettingsRepository，消除旧快照覆盖新设置；
10. 将单媒体操作与跨媒体 Session 操作拆成两层协调器；
11. 冻结 absolute/relative Seek、Future 完成和 UI position 语义；
12. 冻结 Seek 错误恢复窗口、去重、事务和重试上限；
13. 增加 stream-buffer-size 的受控实验矩阵；
14. 冻结媒体缓存资格算法和 free-space unknown 行为；
15. 只有实际执行的 Seek 才触发额外缓存检查；
16. 冻结受控重开期间的用户体验门禁；
17. 修正最终缓存 Profile 必须在能力探测与存储快照之后解析的启动顺序；
18. 将磁盘缓存能力门禁与 Seek 稳定性门禁拆分，磁盘能力不足不得阻断 Seek 修复；
19. 探测选项允许值以及 disk → memory → disabled 的 Profile 切换策略；
20. 使用稳定 PlaybackItemSessionId 持有一次性预算，禁止 generation 重置重试次数；
21. 解决高码率最小时长与会话目标的数学冲突，并独立解析前向/后向 metadata 预算；
22. 在侵入保留空间之前按输入速率和关闭时延提前触发低空间保护；
23. 为 native property、Seek、stop、dispose 和 reporter cleanup 冻结超时与强制退出契约；
24. 在可恢复错误进入 failed 前增加 recoveryPending / recovering 状态；
25. 增加仅验收使用、重启自动清除的 PlaybackDiagnosticsTestOverrides；
26. 将恢复窗口改为可注入参数，并结合连续稳定播放窗口判定；
27. 缓存创建失败后先验证实际运行模式，无法确认时不得伪称已进入内存缓存；
28. 增加总 metadata 内存预算和 iOS/Android 内存压力降级；
29. Repository 的 load / patch / clear / delete-account 必须进入同一串行队列，clear 后旧 patch 不得复活。
```

---

## 1. 现场证据与问题定义

真机完整诊断报告：

```text
filename = emby-full-diagnostics-b56-20260809T073422Z.txt
schema = emby-full-diagnostics/v1
buildNumber = 56
platform = iPadOS
truncated = false
```

已确认的故障链：

```text
DirectPlay MP4 正常开始
→ libmpv 多次记录 Failed to create file cache
→ 用户连续进行大量横向 Seek
→ Input/output error
→ Seek failed
→ partial file
→ error reading packet: Invalid data found when processing input
→ playback_error
→ 播放器退出
```

现场证据表明：

- `Failed to create file cache` 本身并不总会阻止播放 ready；
- 密集 Seek 后出现 FFmpeg/HTTP/MP4 demux 错误；
- 当前应用没有统一 Seek 调度、latest-wins 合并和一次有界恢复；
- 文件缓存不可用会让短距离回退更频繁触发底层 HTTP Range Seek；
- 不能仅通过“调大缓存”或“吞掉错误”解决。

本轮必须同时关闭：

1. iPadOS 上 mpv 文件缓存目录不可用或配置未生效；
2. 缓存策略无法根据设备剩余空间、媒体码率、传输类型和用户偏好动态解析；
3. 用户不能设置前向缓存、后向缓存和会话目标；
4. 缓存真实状态、实际可回退范围、磁盘文件字节和降级原因不可见；
5. 所有 Seek 来源直接进入 `engine.seek()`，缺少 single-flight/latest-wins；
6. 相对 Seek 可能基于旧 position，连续双击不能保证累积；
7. 旧 Seek Future 可能在新手势后写回旧状态；
8. 缓存降级、码率重配、媒体切换、恢复和 shutdown 缺少统一优先级；
9. Seek 后 `partial file`、`I/O error` 没有一次有界恢复；
10. 设置页与播放器各自保存完整 PlaybackSettings，存在旧快照覆盖新缓存设置风险。

---

## 2. 最终产品决策

### 2.1 默认行为

```text
默认缓存模式 = 自动（推荐）
缓存作用域 = 当前媒体播放会话
退出当前媒体后 = 释放缓存
跨媒体复用 = 不支持
离线下载替代 = 不支持
```

### 2.2 用户可选模式

```text
自动（推荐）
仅内存
节省空间
平衡
大缓存
自定义
```

自定义模式允许：

```text
前向缓存目标
后向缓存目标
最大会话缓存目标
设备保留空间
```

用户设置是“目标和上限”，系统始终保留最终安全裁决权。

### 2.3 前向/后向语义

- 前向缓存目标可通过 `cache-secs` 直接影响预读目标；
- 后向缓存没有精确“秒数”底层参数，只能通过 `demuxer-max-back-bytes` 提供保留预算；
- 设置页显示“后向目标”；
- 播放器运行状态显示基于 `seekable-ranges` 计算的“当前实际可回退范围”；
- 不得把目标时长伪装成实际已缓存时长。

示例：

```text
后向目标：2 分钟
当前实际可回退：1 分 47 秒
```

### 2.4 会话目标语义

UI 必须写：

```text
最大会话缓存目标
```

不得写：

```text
磁盘缓存硬上限
绝不会超过 512 MB
```

原因：mpv 磁盘缓存文件为 append-only，应用只能提供 best-effort 目标、动态 guard 和强制设备保留空间保护。

### 2.5 达到目标时的产品行为

达到会话目标或设备进入低空间时，允许：

```text
显示“正在调整缓存…”
→ 保存最新位置和播放/暂停状态
→ 关闭当前媒体缓存文件
→ 切换到内存 Profile 重开
→ 恢复原状态
```

该行为可能产生一次短暂缓冲，但不得：

- 弹出错误对话框；
- 自动退出播放器；
- 重复闪黑；
- 无限重开；
- 丢失最终 Seek 位置。

---

## 3. 范围与非目标

### 3.1 本轮范围

- iPadOS 与 Android；
- 当前捆绑的 `media_kit` / `libmpv`；
- 有限长度网络媒体；
- DirectPlay 或 DirectStream 的渐进式 HTTP；
- mpv 会话级磁盘缓存与内存缓存；
- 动态空间、码率和媒体资格 Profile；
- 前向/后向用户目标；
- 实际缓存状态和可回退范围；
- Seek single-flight/latest-wins；
- 一次有界错误恢复；
- 设置迁移、诊断、自动测试、Actions A/B 和真机 Gate。

### 3.2 本轮不做

```text
跨播放持久化媒体缓存
多个视频之间复用缓存
后台下载整部视频
自建本地 HTTP Range 分片代理
严格分片 LRU
HLS 分片持久缓存
直播回看缓存
DRM 缓存
修改 Emby 服务端
修改反向代理
升级 media_kit 或 libmpv
```

若 C0 能力门禁证明当前捆绑 libmpv 不支持必需能力，不得偷偷升级依赖；必须停止并由 Owner 另行授权依赖升级计划。

### 3.3 关键限制

- `cache-on-disk` 文件为 append-only；
- 逻辑淘汰不会复用已经占用的文件空间；
- `demuxer-max-bytes` 与 `demuxer-max-back-bytes` 在磁盘模式下主要约束 packet metadata；
- 真正严格的磁盘硬上限需要本地 Range 分片代理，不属于本轮；
- `seekable-ranges` 才是可以缓存内 Seek 的真实范围；
- `file-cache-bytes` 是磁盘缓存实际累计字节；
- `raw-input-rate` 只能作为估算，可能缺失或不准确；
- `stream-buffer-size` 对部分 MP4 有帮助，但过大也可能降低性能，因此只做受控实验。

---

## 4. Git 与受保护边界

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
安全诊断 schema
完整诊断导出安全边界
main / origin/main
```

必须复用现有依赖：

```text
path_provider
disk_space_plus
media_kit
media_kit_video
media_kit_libs_video
flutter_secure_storage
```

不得新增第三方依赖。

用户未跟踪目录：

```text
docs/test/
```

必须原样保留：

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
修改或合并 main
重写已经推送的历史
```

---

## 5. C0：捆绑 libmpv 能力门禁

不得仅根据最新 mpv 文档假定当前 IPA/APK 中锁定的二进制支持全部选项和属性。

### 5.1 新增能力模型

建议新增：

```text
lib/playback/cache/playback_cache_capabilities.dart
```

```dart
enum PlaybackCacheProfileSwitchStrategy {
  inPlaceAfterMediaStop,
  requiresPlayerRecreation,
  unsupported,
}

class PlaybackCacheEngineCapabilities {
  const PlaybackCacheEngineCapabilities({
    required this.mpvVersionFingerprint,
    required this.platform,
    required this.supportsDiskCache,
    required this.supportsCacheDirectory,
    required this.supportsImmediateUnlink,
    required this.supportsNativeCacheState,
    required this.supportsSeekableRanges,
    required this.supportsFileCacheBytes,
    required this.supportsRawInputRate,
    required this.supportsStreamBufferSize,
    required this.profileSwitchStrategy,
  });

  final String mpvVersionFingerprint;
  final String platform;
  final bool supportsDiskCache;
  final bool supportsCacheDirectory;
  final bool supportsImmediateUnlink;
  final bool supportsNativeCacheState;
  final bool supportsSeekableRanges;
  final bool supportsFileCacheBytes;
  final bool supportsRawInputRate;
  final bool supportsStreamBufferSize;
  final PlaybackCacheProfileSwitchStrategy profileSwitchStrategy;
}
```

### 5.2 必须探测的 mpv 选项

通过 `option-info/<name>` 或等价 libmpv client API 验证：

```text
cache
cache-on-disk
demuxer-cache-dir
demuxer-cache-unlink-files
cache-secs
demuxer-max-bytes
demuxer-max-back-bytes
demuxer-donate-buffer
demuxer-seekable-cache
cache-pause
cache-pause-wait
stream-buffer-size
```

### 5.2.1 选项允许值与 Profile 切换能力

仅确认选项名称存在不够。C0 还必须读取并验证：

```text
option-info/demuxer-cache-unlink-files/choices
```

要求：

```text
choices 必须明确包含 immediate
```

还必须验证当前捆绑 libmpv 对 reset 值和 Profile 切换的真实行为：

```text
同一个 NativePlayer：

写入 disk Profile
→ open 测试媒体
→ stop 当前媒体
→ 写入 memory Profile
→ open
→ stop
→ 写入 disabled Profile
→ open
```

每一步都必须 read-back，确认：

- `cache-on-disk` 不残留旧值；
- `demuxer-cache-dir` 不残留旧 session；
- `cache`、`cache-secs`、前后 metadata 预算均切换为目标 Profile；
- 已关闭媒体的缓存文件引用被释放。

判定：

```text
同一 NativePlayer 在 stop 后可可靠切换
→ profileSwitchStrategy = inPlaceAfterMediaStop

同一 NativePlayer 不可靠，但重新创建 Player 后可靠
→ profileSwitchStrategy = requiresPlayerRecreation

重新创建 Player 后仍不可靠
→ profileSwitchStrategy = unsupported
```

业务代码不得自行猜测空字符串、`default`、`no` 等 reset 值。所有 reset 值必须来自该能力实验并写入 capability manifest。

### 5.3 必须探测的属性

```text
mpv-version
platform
property-list
demuxer-cache-state
```

在媒体实际打开并启用磁盘缓存后，运行时探测：

```text
demuxer-cache-state/file-cache-bytes
demuxer-cache-state/seekable-ranges
demuxer-cache-state/raw-input-rate
```

说明：这些子字段可能在媒体未打开、缓存未启用或当前流不适用时缺失；“当前缺失”不等于“不支持”。能力判断必须区分：

```text
property unavailable now
property not supported
property supported but field absent for this stream
```

### 5.4 实现方式

扩展 NativePlayer 适配层，提供强类型：

```dart
abstract interface class NativePlaybackPropertyAccess {
  Future<void> setString(String name, String value);
  Future<String?> getString(String name);
  Future<Object?> getNative(String name);
  Future<bool> hasOption(String name);
  Future<bool> hasProperty(String name);
}
```

不得在业务代码中散布 `dynamic` 和裸 property name。

### 5.5 CI 与运行时门禁

自动化至少包含：

1. Dart fake adapter 测试；
2. iOS RunnerTests 中对实际链接 libmpv 的选项/属性探测；
3. Android 构建产物中验证 native library 存在；
4. 新 IPA/APK 首次播放时记录运行时能力清单；
5. 能力清单只记录版本指纹和布尔能力，不记录路径或媒体信息。

本轮使用两个相互独立的门禁：

```text
STOP_GATE_DISK_CACHE_CAPABILITY
STOP_GATE_SEEK_STABILITY
```

若以下任一磁盘必需能力缺失：

```text
cache
cache-on-disk
demuxer-cache-dir
demuxer-cache-unlink-files=immediate
profileSwitchStrategy ∈ {inPlaceAfterMediaStop, requiresPlayerRecreation}
```

则：

```text
STOP_GATE_DISK_CACHE_CAPABILITY = BLOCKED
磁盘缓存功能不得宣称完成
应用必须安全降级为内存缓存
```

但是不得因此停止整个整改。仍必须继续完成：

- PlaybackSettingsRepository；
- 内存缓存 Profile；
- Seek single-flight / latest-wins；
- 操作超时和 shutdown 强制退出；
- Seek 后一次有界恢复；
- 诊断、压力测试和新的 Actions A/B。

此时：

```text
STOP_GATE_SEEK_STABILITY = BLOCKED_BY_IMPLEMENTATION
```

继续推进到实现和真机验收，不等待 Owner 决定是否升级依赖。依赖升级仅作为后续恢复磁盘缓存能力的独立计划。

若磁盘基本选项可用，但 `file-cache-bytes` / `seekable-ranges` 不可用：

- 自动动态磁盘预算不得宣称完成；
- `STOP_GATE_DISK_CACHE_CAPABILITY = BLOCKED`；
- 默认降级为内存模式；
- 不得静默改用 `whendone + 目录遍历` 作为正式默认；
- 目录遍历方案仅允许作为内部诊断实验，必须另获 Owner 明确授权；
- Seek 稳定性整改继续执行。

磁盘能力全部通过后：

```text
STOP_GATE_DISK_CACHE_CAPABILITY = PASSED
```

Seek 自动化实现完成后单独进入：

```text
STOP_GATE_SEEK_STABILITY = WAITING_FOR_DEVICE_OWNER
```

两个门禁不得互相覆盖或重置。

---
