# 播放器横向滑动跨度与实时画面预览完整实施计划（Luna）

> 文档状态：`READY_FOR_IMPLEMENTATION`
>
> 计划分支：`agent/player-scrub-live-preview-goal`
>
> 计划基线：`main@69128cf3c8100a51741c187d28cbb622e008ccb0`
>
> 建议实现分支：`agent/player-scrub-live-preview`
>
> 计划日期：`2026-08-17`
>
> 实施执行者：`Luna`

## 0. 执行契约

本文件是本功能的实施依据。Luna 开始开发前必须先完整阅读本文，并以仓库实际代码为准核对所有符号、依赖版本和平台能力。

实施时必须遵守以下约束：

1. 从开始实施时最新的 `origin/main` 创建 `agent/player-scrub-live-preview`；记录实际基线 SHA。若 `main` 已经超过本计划基线，先核对差异再实施，不得把计划分支当成代码基线。
2. 不直接修改或合并 `main`，不在计划分支上实现产品代码。
3. 先完成客户端抽帧可行性验证，再决定正式启用范围；不得先假设第二个 `media_kit Player` 在 Android、iPhone、iPad 上一定稳定。
4. 不升级 `media_kit`、`media_kit_video`、`media_kit_libs_video`，除非现有锁定版本经验证确实无法提供所需公开 API，且仓库所有者另行批准升级。
5. 预览通道不得创建第二个 Emby 播放会话，不得重新调用播放解析，不得创建第二个 `PlaybackController`、`PlaybackSessionReporter` 或进度上报器。
6. 拖动过程中不得反复 seek 主播放器；主播放器仅在手势正常结束时提交一次 `SeekSource.horizontalDrag`。
7. 客户端抽帧失败、Trickplay 图片失败或预览超时都不得阻止用户完成 seek。
8. 不记录完整媒体 URL、鉴权 Header、AccessToken、本地完整路径或媒体名称。
9. 每个阶段必须独立提交、独立验证；达到阶段门禁后再继续。
10. 最终保持实现 PR 为 Draft 且不合并，等待所有者真机验收。

## 1. 背景与问题定义

当前播放器已经支持横向滑动定位：开始拖动时保存起始位置，拖动过程中更新 `_horizontalDragPreviewPosition` 和界面 `_position`，手势结束后才通过统一 seek 路径提交目标位置，手势取消时恢复起始位置。该行为是正确基础，必须保留。

当前体验仍存在两个缺口：

- 横向滑动灵敏度由固定规则决定，用户无法按短视频、剧集、电影或超长视频调整整屏滑动对应的时间跨度。
- 当前预览依赖 Emby Trickplay。服务端没有生成 Trickplay、离线媒体没有缩略图资源或图片加载失败时，用户无法看到目标时间对应的视频画面。

目标体验接近 Infuse 的 Live Preview：优先使用服务器已经生成的缩略图；服务器没有可用缩略图时，在客户端使用独立解码通道即时获取目标时间画面；两种画面来源都不可用时，仍显示目标时间、偏移量和进度条。

## 2. 当前仓库基线

实施前应重点审查以下文件：

- `lib/ui/player_screen.dart`
- `lib/ui/widgets/trickplay_preview.dart`
- `lib/ui/widgets/playback_timeline.dart`
- `lib/playback/playback_settings.dart`
- `lib/playback/playback_settings_repository.dart`
- `lib/playback/playback_controller.dart`
- `lib/playback/playback_state.dart`
- `lib/playback/playback_engine.dart`
- `lib/models/emby_models.dart`
- `lib/offline/offline_playback_resolver.dart`
- `pubspec.yaml`
- `pubspec.lock`

基线事实：

- `PlayerScreen` 已维护 `_horizontalDragStartPosition`、`_horizontalDragPreviewPosition`、`_horizontalDragDx`、`_position`、`_duration`、`_buffer`、`_settings` 和 `_plan`。
- `PlaybackState` 已包含当前 `PlaybackPlan? plan`。
- `PlaybackController` 已持有当前播放计划、播放认证 Header、主播放引擎和唯一的播放上报器。
- `PlaybackSettings` 已支持默认值、`copyWith`、JSON 序列化和反序列化。
- `PlaybackSettingsRepository` 已按账户串行保存 Patch，存储 Key 为 `playback_settings_v1_*`；新增向后兼容字段不需要更换 Key。
- `TrickplayPreview` 已能从雪碧图中裁切指定行列，但加载失败时目前显示破损图片图标，需改为无破损图标的降级流程。
- `PlaybackTimeline` 的回调允许为 `null`，可以在横滑预览状态中以只读方式复用，同时保留现有缓存范围绘制。
- 当前依赖基线为 `media_kit ^1.2.6`、`media_kit_libs_video ^1.0.7`、`media_kit_video ^2.0.1`。

## 3. 功能目标

### 3.1 可调横向滑动跨度

新增账户级设置：

```dart
final int horizontalSwipeSeekSpanSeconds;
```

定义：手指横跨当前播放器可用宽度时，目标位置相对手势起始位置前进或后退的秒数。

允许值固定为：

```text
30、60、120、300、600 秒
```

默认值：

```text
120 秒
```

默认值必须保持当前用户的基本操作手感。

计算公式：

```text
offset = dragDistance / viewportWidth * horizontalSwipeSeekSpanSeconds
target = clamp(startPosition + offset, 0, duration)
```

要求：

- 向右滑为前进，向左滑为后退。
- 拖回起点时目标位置同步回到起始播放位置。
- 超出左边界时目标为 `Duration.zero`。
- 超出右边界时实际 seek 目标可为视频总时长。
- 预览画面取样位置在视频末尾时使用 `duration - 1ms` 或可用帧上限，避免请求不存在的末尾索引。
- `viewportWidth <= 0`、总时长无效或设置值非法时不得产生异常。

### 3.2 横滑目标画面预览

横滑开始后进入专用定位预览状态：

- 隐藏顶部标题、中央播放按钮和普通控制层。
- 底部显示专用预览区域。
- 底部进度条显示目标位置，并继续保留已有缓存范围可视化。
- 进度条目标位置上方显示预览卡片。
- 预览卡片尽量以目标进度位置为中心，靠近左右边缘时自动限制在安全区域内。
- 显示 `目标时间 / 总时长`。
- 显示相对手势起点的 `前进 X`、`后退 X` 或 `当前位置`。
- 新画面正在加载时保留上一张成功画面，避免闪烁。
- 图片不可用时显示中性的时间卡片，不显示破损图片图标。
- 手势结束后立即提交主播放器 seek，不等待仍在执行的预览请求。
- 手势取消后恢复起始位置，不提交 seek。

### 3.3 预览来源优先级

自动模式下固定使用以下优先级：

```text
1. Emby Trickplay
2. 客户端独立解码抽帧
3. 仅时间与进度条
```

有可用 Trickplay 时不得同时启动客户端预览播放器。

## 4. 设置与产品决策

### 4.1 预览模式

新增枚举：

```dart
enum SeekPreviewMode {
  automatic,
  serverOnly,
  off,
}
```

用户可见文案：

| 值 | 文案 | 行为 |
|---|---|---|
| `automatic` | 自动（推荐） | Trickplay 优先，无可用 Trickplay 时尝试客户端抽帧 |
| `serverOnly` | 仅服务器缩略图 | 只使用 Emby Trickplay，失败后回退时间预览 |
| `off` | 关闭画面预览 | 只显示目标时间、偏移量和进度条 |

默认值：

```dart
SeekPreviewMode.automatic
```

未知 JSON 值、空值或旧设置缺失字段时必须回退到 `automatic`。

### 4.2 设置入口

第一版设置放在播放器右上角的“播放设置”页面中，跟现有快进、快退、播放速度和画面模式放在同一“播放”分组。

新增两项：

1. `横向滑动跨度`
   - 说明：`横跨整个屏幕对应的快进或快退时间`
   - 选项：`30 秒`、`1 分钟`、`2 分钟`、`5 分钟`、`10 分钟`
2. `滑动预览画面`
   - 选项：`自动（推荐）`、`仅服务器缩略图`、`关闭画面预览`

稳定测试 Key：

```text
horizontal-swipe-seek-span-setting
seek-preview-mode-setting
```

### 4.3 设置兼容性

在 `PlaybackSettings` 中补全：

- 构造参数和默认值；
- final 字段；
- `copyWith`；
- `fromJson`；
- `toJson`。

在 `PlaybackSettingsPatch` 中补全：

- 构造参数；
- Patch 字段；
- `applyTo` 映射。

约束：

- 不更换 `playback_settings_v1_*` 存储 Key。
- `horizontalSwipeSeekSpanSeconds` 仅接受允许集合；JSON 中的其他值回退到 120，不能让异常值进入运行时。
- Patch 层同样应进行规范化，不能只依赖界面选项。
- 旧设置 JSON、部分字段 JSON、损坏 JSON 的现有回退行为不得退化。

## 5. 支持范围与能力策略

### 5.1 Trickplay

以下情况优先使用 Trickplay：

- 当前媒体项包含对应 `mediaSourceId` 的 Trickplay 元数据；
- 能选择到有效分辨率；
- 目标时间能够映射到合法 tile；
- 雪碧图能够成功加载。

Trickplay 不受客户端抽帧平台能力限制。

### 5.2 客户端抽帧初始候选范围

只有通过 Phase 0 验证的范围才能正式启用。初始候选：

- `PlaybackTransportKind.offlineLocal`；
- 非直播的 `PlaybackTransportKind.progressiveHttp`；
- 经真机验证的 DirectPlay；
- 经真机验证且不会新建会话的 DirectStream。

默认不启用：

- `PlaybackTransportKind.live`；
- 直播或存在 `liveStreamId` 的计划；
- 未验证的 `segmentedHttp` / HLS；
- 转码媒体；
- `unknown` 传输类型；
- 无法随机读取或 seek 的媒体源。

对于未启用类型：

```text
Trickplay 可用 -> Trickplay
Trickplay 不可用 -> 时间预览
```

### 5.3 平台能力不是静态假设

需要建立显式能力结果，例如：

```dart
class ClientFramePreviewCapabilities {
  const ClientFramePreviewCapabilities({
    required this.supported,
    required this.reason,
    required this.supportedTransports,
  });
}
```

能力来源可由编译平台、Phase 0 固化结果和当前播放计划共同决定。不得仅通过 `Platform.isIOS` 或 `Platform.isAndroid` 直接返回支持。

## 6. 总体架构

建议结构：

```text
PlayerScreen
├── HorizontalScrubController / HorizontalScrubSession
│   ├── startPosition
│   ├── dragDistance
│   ├── targetPosition
│   ├── begin / update / complete / cancel
│   └── 纯计算与状态转换
│
├── SeekPreviewCoordinator
│   ├── TrickplaySeekPreviewProvider
│   ├── ClientDecodedSeekPreviewProvider
│   ├── 来源优先级
│   ├── 最新请求优先
│   ├── generation 失效控制
│   ├── 节流与去重
│   ├── LRU 缓存
│   └── 连续失败熔断
│
└── HorizontalSeekPreviewOverlay
    ├── Trickplay 雪碧图画面
    ├── 客户端内存画面
    ├── 加载状态
    ├── 时间降级卡片
    └── 只读 PlaybackTimeline
```

### 6.1 分层原则

- 手势和时间换算不依赖 Flutter Widget，必须可纯单元测试。
- Provider 返回预览数据，不返回 Widget。
- UI 不直接创建或管理第二个播放器。
- Coordinator 不调用主播放器 seek。
- `PlayerScreen` 只负责把当前媒体身份、计划、Header、目标时间和生命周期事件传给 Coordinator。
- Trickplay 与客户端帧使用统一的预览状态模型。
- 所有异步结果必须带媒体身份和 generation 校验。

### 6.2 建议数据模型

```dart
enum SeekPreviewSource {
  trickplay,
  clientDecoded,
  timeOnly,
}

class SeekPreviewRequest {
  const SeekPreviewRequest({
    required this.mediaIdentity,
    required this.target,
    required this.duration,
    required this.generation,
  });
}

sealed class SeekPreviewVisual {
  const SeekPreviewVisual();
}

class TrickplaySeekPreviewVisual extends SeekPreviewVisual {
  // ImageProvider 或受控图片描述、tile 行列、宽高
}

class MemorySeekPreviewVisual extends SeekPreviewVisual {
  // 压缩后 Uint8List 与尺寸信息
}

class NoSeekPreviewVisual extends SeekPreviewVisual {
  const NoSeekPreviewVisual();
}

class SeekPreviewPresentation {
  const SeekPreviewPresentation({
    required this.target,
    required this.source,
    required this.visual,
    required this.isLoading,
  });
}
```

命名可按现有代码风格调整，但必须保持数据层与 Widget 层隔离。

### 6.3 媒体身份

缓存、过期检查和 Provider 生命周期必须使用稳定媒体身份，至少包含：

```text
itemId
mediaSourceId
transportKind
playMethod
当前播放资源 generation/session identity
```

不得把 AccessToken 或完整 URL 写入等号、日志或缓存 Key。若需要区分 URI，可在内存中使用不可逆短哈希，但不得导出原始值。

## 7. 横滑状态机

### 7.1 开始

满足以下全部条件才允许开始横滑：

- 控制未锁定；
- 当前无播放错误；
- 总时长大于 0；
- 主播放计划已可用；
- 当前不在媒体切换或关闭流程；
- 当前不是不可 seek 的直播。

开始时：

1. 保存真实起始位置。
2. 清除旧手势残留和旧预览 generation。
3. 设置 `_seeking = true`。
4. 隐藏普通控制层。
5. 立即显示时间与只读进度条，不等待图片。
6. 若模式允许，调度目标位置的预览请求。

### 7.2 更新

每次拖动更新必须同步完成：

- 累计横向距离；
- 按设置计算目标时间；
- 更新界面目标时间和进度条；
- 更新前进或后退偏移文案。

图片请求异步执行，并经过节流、时间桶去重和 generation 校验。

### 7.3 正常结束

1. 保存最终目标位置。
2. 立即使所有未完成预览请求失效。
3. 清理横滑状态。
4. 恢复普通控制层。
5. 通过现有统一入口提交一次：

```dart
_seekAbsolute(target, source: SeekSource.horizontalDrag)
```

不得等待客户端截图完成。

### 7.4 取消

1. 使预览请求失效。
2. 把显示位置恢复到手势起始位置或主播放器最新可信位置。
3. 清理横滑状态。
4. 不调用主播放器 seek。
5. 恢复普通控制层。

### 7.5 强制中止

以下事件必须等价于取消预览，并释放或暂停客户端预览资源：

- 切换剧集或媒体源；
- 主播放器重建；
- 进入画中画；
- App 进入后台；
- 页面关闭；
- 主播放失败；
- 账户退出；
- 播放总时长或计划发生身份变化。

## 8. Phase 0：客户端即时抽帧可行性验证

### 8.1 目的

此阶段只回答一个问题：在仓库当前锁定的 `media_kit` 版本和现有 Android/iOS 播放内核下，能否使用与主播放器隔离的轻量预览通道，在不干扰主播放的情况下获取指定时间帧。

不得在可行性结论之前大规模接入正式 UI。

### 8.2 API 核对

先检查 `pubspec.lock` 和本地已解析 package 源码，确认当前版本公开支持的截图 API。候选路径为当前锁定版本的公开 `Player.screenshot(...)` 或等价公开能力。

规则：

- 有公开 API：使用公开 API做 Probe。
- 只有私有实现、未导出的 FFI 或需要修改第三方 package：本阶段判定该路线不可直接采用。
- 不得为了通过 Probe 自动升级依赖。
- 不得在本功能内复制 media_kit 私有 FFI 实现。

### 8.3 Probe 结构

建议新增临时或可保留的内部 Probe：

```text
lib/playback/preview/media_kit_frame_probe.dart
```

Probe 必须复用已经生效的当前播放计划：

```text
PlaybackPlan.uri
PlaybackPlan.usesServerAuthentication
PlaybackController.playbackHeaders
PlaybackTransportKind
PlayMethod
```

不得再次调用 `resolver.resolve()`。

候选流程：

```dart
final previewPlayer = Player(
  configuration: const PlayerConfiguration(
    logLevel: MPVLogLevel.warn,
  ),
);

await previewPlayer.open(
  Media(
    plan.uri.toString(),
    httpHeaders: plan.usesServerAuthentication
        ? playbackHeaders
        : const <String, String>{},
  ),
  play: false,
);

// 使用当前版本公开 API关闭音频、字幕并静音。
// seek 到目标位置，等待已解码画面稳定，再截图。
// finally 中 stop/dispose。
```

要求：

- 默认不创建可见 `VideoController` 或第二个 Flutter 纹理；只有截图 API确实要求视频输出时才可在 Provider 内封装不可见轻量输出，并在报告中说明。
- 音量必须为 0，同时禁用音轨；仅静音但仍解码音频不算完整优化。
- 禁用字幕轨道和外部字幕。
- `play: false`，预览通道不得持续播放。
- 不设置主播放缓存策略，不读写主播放器的缓存协调器状态。
- 不激活 Emby reporter，不发送 started/progress/stopped 请求。
- 所有异常必须在 `finally` 中释放预览 Player。

### 8.4 Probe 媒体矩阵

至少验证：

| 类型 | Android 真机 | iPhone 真机 | iPad 真机 |
|---|---:|---:|---:|
| 离线本地文件 | 必测 | 必测 | 必测 |
| Progressive HTTP DirectPlay | 必测 | 必测 | 必测 |
| 带认证 Header 的 DirectPlay | 必测 | 必测 | 必测 |
| 无 Trickplay 的普通视频 | 必测 | 必测 | 必测 |
| HLS / segmentedHttp | 记录结果，不默认启用 | 记录结果，不默认启用 | 记录结果，不默认启用 |
| 转码流 | 记录结果，不默认启用 | 记录结果，不默认启用 | 记录结果，不默认启用 |
| 直播 | 不执行抽帧 | 不执行抽帧 | 不执行抽帧 |

至少覆盖一种 H.264 1080p 和一种 HEVC 高码率媒体；设备条件允许时覆盖 4K/HDR，结果只用于能力边界，不得因单个高负载样本拖垮主播放器。

### 8.5 Probe 压力验证

每个平台至少完成：

- 同一个媒体连续随机抽取 100 个时间点；
- 快速连续提交 100 个目标，只允许最新目标最终展示；
- 连续进入并退出播放器页面 20 次；
- 主播放器播放时执行预览，确认播放时间、音频、字幕和缓存状态不被修改；
- 中途关闭页面，确认网络读取和解码资源停止；
- 网络断开后预览失败，但主播放器和最终 seek 行为不崩溃；
- 快速切换下一集，旧媒体帧不得出现在新媒体界面。

### 8.6 性能记录

报告至少记录：

```text
首次打开预览通道耗时 p50 / p95
热通道抽帧耗时 p50 / p95
单帧字节数与解码尺寸
连续 100 次后的内存变化
主播放器是否发生 buffering 增加
是否出现硬件解码器创建失败
是否出现黑屏、Surface、纹理或截图空数据
预览 Player dispose 后网络是否停止
```

性能目标：

- 时间和进度条更新必须同步、无网络等待。
- 首次客户端画面 p95 目标不高于 2000ms。
- 已打开预览通道后的抽帧 p50 目标不高于 450ms，p95 目标不高于 1200ms。
- 即使帧较慢，UI 也必须继续显示上一次画面和当前目标时间，不能卡住手势。

### 8.7 Gate A 决策

#### A：Android、iPhone、iPad 均稳定

继续实现统一 `MediaKitClientFrameExtractor`，按已验证传输类型启用。

#### B：部分平台或部分传输稳定

固化能力矩阵，只在证据通过的平台和传输类型启用；其他情况回退 Trickplay 或时间预览。

#### C：独立 media_kit 抽帧不稳定或无公开 API

停止客户端抽帧正式实现，不引入新大型依赖。继续交付：

```text
可调横滑跨度 + 进度条上方 Trickplay + 时间降级
```

另开原生 FFmpeg/平台抽帧专项，不得在本功能中临时拼接不受控实现。

Gate A 结论必须写入实现报告并提交，不能只在最终回复中口头说明。

## 9. Phase 1：横滑计算与设置模型

### 9.1 新增纯计算模块

建议新增：

```text
lib/playback/horizontal_scrub_mapping.dart
```

核心 API：

```dart
Duration calculateHorizontalScrubTarget({
  required Duration startPosition,
  required Duration duration,
  required double dragDistance,
  required double viewportWidth,
  required int spanSeconds,
});
```

可额外提供：

```dart
Duration previewSamplePosition({
  required Duration target,
  required Duration duration,
});
```

要求：

- 纯函数，无 `BuildContext`；
- 不直接依赖 `MediaQuery`；
- 统一处理舍入和边界；
- 设置值非法时使用受控默认值或返回起始位置；
- 不在 `player_screen.dart` 中保留另一套重复公式。

### 9.2 设置模型与 UI

修改：

```text
lib/playback/playback_settings.dart
lib/playback/playback_settings_repository.dart
lib/ui/player_screen.dart
```

加入设置、规范化和 UI 控件。设置保存失败继续使用现有统一错误处理，不应影响当前播放。

### 9.3 Gate B

执行：

```bash
dart format --set-exit-if-changed .
flutter analyze
flutter test test/playback_settings_test.dart
flutter test test/playback_settings_repository_test.dart
flutter test test/horizontal_scrub_mapping_test.dart
git diff --check
```

此阶段不得改变主播放器最终 seek 次数和取消语义。

## 10. Phase 2：进度条上方预览 UI 与 Trickplay 完整化

### 10.1 新增组件

```text
lib/ui/widgets/horizontal_seek_preview_overlay.dart
```

建议参数：

```dart
class HorizontalSeekPreviewOverlay extends StatelessWidget {
  const HorizontalSeekPreviewOverlay({
    super.key,
    required this.startPosition,
    required this.targetPosition,
    required this.duration,
    required this.buffer,
    required this.presentation,
    required this.cacheRuntimeMode,
    required this.cacheSnapshot,
  });
}
```

具体参数可按现有缓存状态模型调整。

### 10.2 稳定 Key

```text
horizontal-seek-preview-overlay
horizontal-seek-preview-image
horizontal-seek-preview-loading
horizontal-seek-preview-timeline
horizontal-seek-target-time
horizontal-seek-offset-label
```

### 10.3 卡片位置算法

基于视频时间比例，不基于手指坐标：

```text
fraction = target / duration
desiredCenterX = timelineWidth * fraction
left = clamp(desiredCenterX - cardWidth / 2,
             safeLeft,
             timelineWidth - cardWidth - safeRight)
```

必须考虑：

- SafeArea；
- 手机刘海和圆角；
- iPad 横屏宽度；
- 文字缩放；
- 目标接近 0 和接近 100%；
- 超长总时长文案；
- RTL 布局不应造成越界，时间比例仍保持语义正确。

### 10.4 Trickplay 适配

复用现有：

- 当前 `EmbyTrickplay` 元数据；
- `resolutionFor(mediaSourceId)`；
- `trickplayTileUrl`；
- `playbackHeaders`；
- `TrickplayPreview` 的雪碧图裁切逻辑。

补强：

- 对目标时间做末尾边界处理；
- 校验 tile index、sheet index、row 和 column；
- 图片加载错误不再显示 `broken_image_outlined`；
- 图片加载错误必须回报给 Coordinator，并在 automatic 模式下触发客户端 fallback；
- serverOnly 模式下直接回退时间预览；
- 新 URL 加载时保留上一张成功图片；
- 已过期图片加载结果不得覆盖当前目标或新媒体。

图片错误回报可通过受控 `ImageStreamListener`、加载状态对象或安全的 post-frame 回调实现，禁止在 `build` 中直接递归触发 `setState`。

### 10.5 只读时间轴

复用 `PlaybackTimeline`，将三个交互回调传 `null`。不得复制一套普通 Slider，否则会丢失现有缓存范围绘制和后续时间轴改进。

### 10.6 Gate C

这一阶段结束时必须得到可独立交付的稳定功能：

- 横滑跨度可设置；
- Trickplay 位于进度条上方；
- 无 Trickplay 或图片错误时显示时间预览；
- 拖动期间不 seek 主播放器；
- 松手只 seek 一次；
- 取消不 seek。

即使 Gate A 结果为 C，仍应完成 Gate C。

## 11. Phase 3：统一预览域模型与 Coordinator

建议新增：

```text
lib/playback/preview/seek_preview_frame.dart
lib/playback/preview/seek_preview_request.dart
lib/playback/preview/seek_preview_provider.dart
lib/playback/preview/seek_preview_coordinator.dart
lib/playback/preview/seek_preview_capabilities.dart
lib/playback/preview/seek_preview_cache.dart
lib/playback/preview/trickplay_seek_preview_provider.dart
```

### 11.1 Provider 接口

示例：

```dart
abstract interface class SeekPreviewProvider {
  Future<SeekPreviewFrame?> frameAt(SeekPreviewRequest request);

  Future<void> cancelActiveRequest();

  Future<void> dispose();
}
```

取消可以采用 generation/latest-wins 语义，不要求底层所有网络调用都支持物理取消，但过期结果绝不能生效。

### 11.2 Coordinator 职责

- 根据设置模式决定是否请求图片；
- 判断 Trickplay 是否可用；
- 管理客户端抽帧能力和熔断；
- 调度节流；
- 时间桶去重；
- 缓存命中；
- 维护一个执行中的请求和一个最新待处理目标；
- 丢弃过期结果；
- 输出可监听的 presentation 状态；
- 媒体变化时原子清空旧状态。

### 11.3 依赖注入

为了测试，`PlayerScreen` 必须允许注入 Coordinator 或工厂，例如：

```dart
final SeekPreviewCoordinatorFactory? seekPreviewCoordinatorFactory;
```

生产默认创建真实实现，Widget 测试使用 Fake。不得让 Widget 测试启动真实 `media_kit Player` 或真实网络请求。

## 12. Phase 4：客户端独立解码抽帧

仅在 Gate A 为 A 或 B 时执行。

建议新增：

```text
lib/playback/preview/client_frame_extractor.dart
lib/playback/preview/media_kit_client_frame_extractor.dart
lib/playback/preview/client_decoded_seek_preview_provider.dart
```

### 12.1 预览源快照

Provider 使用只读快照：

```dart
class SeekPreviewMediaSource {
  const SeekPreviewMediaSource({
    required this.itemId,
    required this.mediaSourceId,
    required this.uri,
    required this.headers,
    required this.transportKind,
    required this.playMethod,
    required this.duration,
    required this.isLive,
    required this.isOffline,
    required this.resourceGeneration,
  });
}
```

Header 只保存在内存，不得进入日志、`toString`、缓存 Key 或诊断导出。

### 12.2 生命周期

- 第一次需要客户端帧时懒创建预览 Player。
- 同一媒体内复用一个预览 Player，不得每次移动都创建。
- 同一时间只执行一个客户端解码任务。
- 手势结束后可短暂保温复用；建议 30 秒无预览请求后释放。
- App 后台、PiP、媒体切换、主 Player 重建、错误和页面退出时立即释放。
- 创建或释放失败不能影响主播放关闭流程。

### 12.3 解码设置

使用当前锁定版本公开 API完成：

- `play: false`；
- volume = 0；
- 禁用音轨；
- 禁用字幕轨；
- 不加载外部字幕；
- 不启动持续播放；
- seek 到取样目标；
- 等待可用画面后截图；
- 输出低分辨率压缩帧。

目标显示尺寸：

```text
手机约 240×135
iPad 约 320×180
最大宽度不高于 320（第一版）
```

如果公开截图 API支持目标尺寸，优先让底层直接缩放；否则在进入缓存前完成受控缩放。禁止把完整 4K 原始 BGRA 帧长期保存在 Dart 内存。

### 12.4 超时

建议：

```text
预览 Player 首次打开超时：3 秒
单次 seek + screenshot 超时：2 秒
释放超时：2 秒
```

超时后：

- 当前请求回退时间预览；
- 记录安全诊断；
- 增加连续失败计数；
- 不阻塞主播放器 seek。

### 12.5 失败熔断

同一媒体源连续失败 3 次后，在当前播放资源 generation 内禁用客户端抽帧：

```text
client preview disabled for current media -> time fallback
```

切换媒体后重置。不要每次拖动都重复创建失败的第二播放器。

## 13. Phase 5：节流、去重、缓存与最新请求优先

### 13.1 节流

手指更新事件不直接对应抽帧次数。建议默认：

```dart
const previewDebounce = Duration(milliseconds: 120);
```

时间文本和进度条仍然每次同步更新，只有图片请求节流。

### 13.2 时间桶

客户端帧第一版按 2 秒归一化：

```text
bucket = floor(targetSeconds / 2) * 2
```

Trickplay 继续使用服务器自身间隔，不强制改成 2 秒。

### 13.3 并发模型

最多保留：

```text
1 个执行中的抽帧请求
1 个待执行的最新目标
```

新目标覆盖旧的等待目标。禁止把所有拖动位置排成队列。

### 13.4 Generation

以下事件必须递增 generation：

- 新横滑会话开始；
- 新目标替换旧目标；
- 手势结束；
- 手势取消；
- 媒体或媒体源变化；
- 主播放器重建；
- App 后台；
- PiP；
- 页面关闭；
- 播放错误。

异步结果同时满足以下条件才可展示：

```text
request generation == current generation
media identity == current media identity
horizontal scrub session still active
```

### 13.5 LRU 缓存

客户端帧缓存同时限制数量与字节：

```text
最多 32 项
最多约 8 MiB 压缩数据
任一上限达到即按 LRU 淘汰
```

Key 至少包含：

```text
itemId + mediaSourceId + resourceGeneration + timeBucket
```

媒体切换时清空当前内存缓存。第一版不写磁盘，不跨 App 会话保存客户端抽帧。

Trickplay 继续复用 Flutter/网络图片缓存，不把整个雪碧图复制到客户端帧 LRU。

## 14. 生命周期、缓存与主播放器隔离

必须证明客户端预览不会：

- 修改主播放器 position；
- 修改主播放器 playing/paused 状态；
- 修改主播放器音轨、字幕轨、速率、延迟或画面模式；
- 修改主播放器缓存 profile、缓存证据或 seek 统计；
- 触发主播放 recovery；
- 发送 Emby started/progress/stopped；
- 增加已播放次数；
- 改变下一集自动播放；
- 阻塞页面关闭和亮度恢复。

如果第二播放器与主播放器竞争硬件解码器，必须通过能力矩阵禁用对应平台或媒体类型，不得让主播放承担风险。

## 15. 诊断与隐私

建议增加安全事件：

```text
event=seek_preview_session_started
event=seek_preview_request
event=seek_preview_ready
event=seek_preview_cache_hit
event=seek_preview_failed
event=seek_preview_client_disabled
event=seek_preview_session_cancelled
event=seek_preview_disposed
```

允许字段：

```text
source=trickplay|clientDecoded|timeOnly
transport=offlineLocal|progressiveHttp|segmentedHttp|live|unknown
latencyMs=<number>
cacheHit=true|false
reason=<枚举或稳定短字符串>
errorType=<runtime type>
generation=<非敏感序号>
```

禁止字段：

```text
完整播放 URL
query 中的 token
AccessToken
HTTP Header
本地完整路径
用户名
服务器地址
媒体名称
```

高频拖动日志必须采样或聚合，不能每个 pointer update 写一条日志。

## 16. 预计文件清单

### 16.1 修改

```text
lib/ui/player_screen.dart
lib/ui/widgets/trickplay_preview.dart
lib/playback/playback_settings.dart
lib/playback/playback_settings_repository.dart
lib/playback/playback_controller.dart（仅在需要安全只读快照或注入接口时）
lib/playback/playback_engine.dart（仅在抽象截图能力时）
test/playback_settings_test.dart
test/playback_settings_repository_test.dart
test/playback_timeline_test.dart
```

### 16.2 新增

```text
lib/playback/horizontal_scrub_mapping.dart
lib/playback/seek_preview_mode.dart
lib/playback/preview/seek_preview_request.dart
lib/playback/preview/seek_preview_frame.dart
lib/playback/preview/seek_preview_provider.dart
lib/playback/preview/seek_preview_coordinator.dart
lib/playback/preview/seek_preview_capabilities.dart
lib/playback/preview/seek_preview_cache.dart
lib/playback/preview/trickplay_seek_preview_provider.dart
lib/playback/preview/client_frame_extractor.dart
lib/playback/preview/media_kit_client_frame_extractor.dart
lib/playback/preview/client_decoded_seek_preview_provider.dart
lib/ui/widgets/horizontal_seek_preview_overlay.dart

test/horizontal_scrub_mapping_test.dart
test/seek_preview_mode_test.dart
test/seek_preview_capabilities_test.dart
test/seek_preview_cache_test.dart
test/seek_preview_coordinator_test.dart
test/trickplay_seek_preview_provider_test.dart
test/client_decoded_seek_preview_provider_test.dart
test/horizontal_seek_preview_overlay_test.dart
```

文件名可在不降低职责边界的前提下调整。不得把所有逻辑继续堆入已较大的 `player_screen.dart`。

## 17. 自动化测试计划

### 17.1 设置测试

覆盖：

- 默认跨度为 120；
- 默认模式为 automatic；
- 旧 JSON 缺少字段；
- JSON round trip；
- `copyWith`；
- Patch 保存后重新 load；
- 非法跨度回退；
- 未知预览模式回退；
- 并发 Patch 不覆盖其他字段；
- clear/deactivate/dispose 语义不退化。

### 17.2 横滑映射测试

覆盖：

- 向左和向右；
- 四分之一屏、半屏、整屏；
- 30、60、120、300、600 秒；
- 反向拖回；
- 开头 clamp；
- 结尾 clamp；
- duration 为 0；
- viewportWidth 为 0、负数和非有限值；
- 非法 span；
- 视频末尾预览取样位置。

### 17.3 Coordinator 测试

使用 Fake Provider，覆盖：

- Trickplay 优先，不调用客户端 Provider；
- Trickplay 不可用时客户端 fallback；
- Trickplay 加载失败时客户端 fallback；
- serverOnly 不调用客户端；
- off 不调用任何图片 Provider；
- 两种 Provider 失败后时间 fallback；
- generation 过期结果被丢弃；
- 媒体身份变化后旧帧被丢弃；
- 仅一个 in-flight；
- 最新等待目标覆盖旧目标；
- 时间桶去重；
- 缓存命中；
- LRU 淘汰；
- 连续 3 次失败熔断；
- 新媒体重置熔断；
- dispose 幂等。

### 17.4 Widget 测试

覆盖：

- 左端、中间、右端位置；
- 预览卡片不越界；
- 手机与 iPad 横屏尺寸；
- 大文字缩放；
- Trickplay visual；
- Memory visual；
- loading 保留上一帧；
- 无图时间降级；
- 前进、后退、当前位置文案；
- 超过一小时视频时间格式；
- 只读 Timeline 不接受交互；
- 原有缓存区间仍然绘制；
- 图片错误不显示 broken-image 图标。

### 17.5 播放器交互测试

通过注入 Fake Coordinator 和可观察 seek dispatcher，覆盖：

- 拖动过程中主 seek 次数为 0；
- 正常结束后主 seek 次数恰好为 1；
- 取消后主 seek 次数为 0；
- 取消恢复起始显示位置；
- 控制锁定时不能横滑；
- 错误和 duration=0 时不能横滑；
- 切换媒体使旧请求失效；
- 页面关闭使 Provider dispose；
- 预览失败仍可完成 seek；
- 垂直亮度和音量手势不退化；
- 双击快进快退不退化。

### 17.6 客户端抽帧测试

纯 Dart/Widget 测试使用 Fake Extractor，不启动真实 native player。真实 `media_kit` 截图能力由平台 Probe 和真机证据覆盖。

Fake 测试覆盖：

- open 使用正确 URI 和条件 Header；
- 不携带 Header 的计划传空 Header；
- seek 目标正确；
- 超时回退；
- cancel/latest-wins；
- stop/dispose 一定执行；
- 失败熔断；
- Header 不出现在异常文案或日志中。

## 18. 真机验收矩阵

### 18.1 设备

至少：

```text
Android 真机 1 台
iPhone 真机 1 台
iPad 真机 1 台
```

模拟器只能辅助，不能替代客户端双解码通道验收。

### 18.2 场景

- 有 Trickplay 的远程视频；
- 无 Trickplay 的 Progressive DirectPlay；
- 带认证 Header 的远程视频；
- 离线下载视频；
- 30/60/120/300/600 秒跨度；
- 滑至开头；
- 滑至结尾；
- 快速左右往返；
- 手势取消；
- 网络中断；
- 切换下一集；
- 进入 PiP；
- App 后台再回来；
- 连续进入退出播放器；
- 横竖屏系统状态恢复；
- 高码率 HEVC；
- 不支持客户端抽帧的 HLS/转码/直播降级。

### 18.3 验收结果

每个场景记录：

```text
预览来源
首帧耗时
是否出现旧帧串台
是否影响主播放音频/画面
松手 seek 次数
取消 seek 次数
资源释放结果
降级是否正确
```

建议新增：

```text
docs/implementation/2026-08-player-scrub-live-preview-report.md
docs/acceptance/2026-08-player-scrub-live-preview-acceptance.md
```

## 19. 阶段提交策略

建议提交顺序：

```text
1. test: probe isolated media kit seek preview frames
2. feat: add configurable horizontal scrub settings
3. refactor: extract horizontal scrub mapping
4. feat: move seek preview above playback timeline
5. refactor: introduce seek preview coordinator
6. feat: add client decoded preview fallback
7. fix: harden preview cancellation cache and lifecycle
8. test: cover scrub preview priority and fallback
9. docs: record scrub preview implementation evidence
```

若 Gate A 为 C，第 6 个提交不得伪造完成，应改为记录不可用能力与稳定降级。

每个提交必须：

- 只包含该阶段相关文件；
- 通过定向测试；
- `git diff --check` 通过；
- 不夹带格式化整个仓库造成的无关 diff。

## 20. 验证门禁

最终必须执行：

```bash
dart format --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
flutter build apk --debug
flutter build ios --debug --no-codesign
```

同时执行仓库现有与播放器相关的原生能力/CI 门禁；不得删除、跳过或弱化现有断言来让新代码通过。

若某构建因执行环境缺少 SDK 或签名资源无法运行，必须记录命令、环境阻塞和已完成的替代验证，不能写成通过。

## 21. 功能验收标准

### 21.1 设置

- 默认整屏跨度为 120 秒；
- 30、60、120、300、600 秒均可保存；
- 设置按 Emby 账户隔离；
- 重启后保持；
- 旧设置无新字段时正常；
- 模式 automatic/serverOnly/off 正确持久化。

### 21.2 横滑

- 拖动距离与跨度线性对应；
- 左滑后退、右滑前进；
- 目标不越界；
- 拖动期间不 seek 主播放器；
- 正常结束只 seek 一次；
- 取消不 seek；
- 锁定、错误、无时长和不可 seek 直播禁用横滑。

### 21.3 画面预览

- 预览显示在底部进度条上方；
- 卡片跟随目标时间且不越界；
- 有 Trickplay 时优先 Trickplay；
- 无 Trickplay 且客户端能力通过时显示客户端帧；
- 图片或客户端抽帧失败时显示时间预览；
- 加载新帧时不闪烁破损图；
- 旧请求不能覆盖新目标；
- 旧媒体帧不能出现在新媒体。

### 21.4 性能与资源

- 时间和进度条更新不等待图片；
- 快速拖动不会建立无界请求队列；
- 客户端抽帧最多一个 in-flight；
- 缓存有明确上限；
- 页面退出后资源和网络停止；
- 主播放器无音频、字幕、position、缓存和上报串扰；
- 客户端预览失败不导致播放器崩溃。

## 22. 明确非目标

本轮不做：

- 为整个媒体库后台批量生成缩略图；
- 将客户端帧持久化到磁盘；
- 为直播生成历史帧；
- 默认支持未验证的 HLS 或转码流客户端抽帧；
- 修改 Emby 服务器配置；
- 修改播放进度上报协议；
- 重写主播放器内核；
- 引入新的大型 FFmpeg 插件；
- 升级 media_kit 依赖；
- 把普通进度条拖动也扩展成全新交互体系。

后续可另行评估：服务端 Trickplay 预下载、离线 Trickplay、磁盘缩略图缓存、电视端遥控器预览和更多预览质量设置。

## 23. 风险与回滚

### 风险 1：双播放器竞争硬件解码器

处理：Phase 0 真机门禁；能力按平台和传输类型限制；失败立即时间降级。

### 风险 2：远程抽帧放大带宽和请求数

处理：Trickplay 优先、120ms 节流、2 秒时间桶、单 in-flight、LRU、30 秒空闲释放、连续失败熔断。

### 风险 3：旧帧串到新目标或下一集

处理：媒体身份 + generation 双重校验；切换媒体原子清理。

### 风险 4：图片错误破坏拖动

处理：所有图片来源都可回退 `NoSeekPreviewVisual`，最终 seek 与预览完全解耦。

### 风险 5：设置数据异常

处理：允许值白名单、未知枚举回退、维持 v1 存储兼容。

### 回滚顺序

1. 通过设置 `off` 关闭画面预览，保留可调跨度。
2. 关闭客户端 Provider，保留 Trickplay + 时间降级。
3. 若 UI 存在严重问题，回退专用 Overlay，保留纯计算与设置模型。
4. 不回滚现有统一 seek、安全关闭和缓存功能。

## 24. Definition of Done

只有同时满足以下条件才可标记 `IMPLEMENTATION_COMPLETE`：

- Phase 0 有可审查报告和明确 A/B/C 结论；
- Gate B、Gate C 通过；
- Gate A 为 A/B 时，客户端抽帧仅在证据支持范围启用；
- 全部设置、映射、Coordinator、Widget 和生命周期测试通过；
- 全量 `flutter test` 通过；
- `flutter analyze` 通过；
- Android Debug 构建通过；
- iOS no-codesign 构建通过；
- Android、iPhone、iPad 真机矩阵有结果；
- 无敏感日志；
- 实现分支已推送；
- Draft PR 已更新；
- 未合并 `main`；
- 工作树干净，本地 HEAD 与远端 tracking 一致。

## 25. Luna 最终回报格式

```text
STATUS=
PLAN_FILE=docs/plans/2026-08-17-player-horizontal-scrub-live-preview-luna-plan.md
PLAN_BASE_COMMIT=69128cf3c8100a51741c187d28cbb622e008ccb0
IMPLEMENTATION_BASE_COMMIT=
BRANCH=agent/player-scrub-live-preview
FINAL_COMMIT=
PHASE_0_RESULT=A|B|C
ANDROID_CLIENT_PREVIEW=SUPPORTED|PARTIAL|UNSUPPORTED|NOT_TESTED
iPhone_CLIENT_PREVIEW=SUPPORTED|PARTIAL|UNSUPPORTED|NOT_TESTED
iPAD_CLIENT_PREVIEW=SUPPORTED|PARTIAL|UNSUPPORTED|NOT_TESTED
SUPPORTED_TRANSPORTS=
DISABLED_TRANSPORTS=
TRICKPLAY_RESULT=
CLIENT_FALLBACK_RESULT=
TIME_FALLBACK_RESULT=
HORIZONTAL_SPAN_SETTINGS=
GESTURE_SEEK_COUNT_RESULT=
CANCELLATION_RESULT=
LIFECYCLE_RESULT=
PRIVACY_LOG_RESULT=
CHANGED_FILES=
TARGETED_TESTS=
FULL_FLUTTER_TEST=
FLUTTER_ANALYZE=
ANDROID_DEBUG_BUILD=
IOS_NO_CODESIGN_BUILD=
REAL_DEVICE_EVIDENCE=
DRAFT_PR=
PUSHED=true|false
MERGED_TO_MAIN=false
WORKTREE_CLEAN=true|false
REMOTE_TRACKING_EXACT=true|false
BLOCKERS=
```

任何未执行项目必须写 `NOT_RUN` 或 `NOT_TESTED`，不得写 `PASSED`。

## 26. Luna 开始实施时的简化指令

```text
阅读并严格执行：
docs/plans/2026-08-17-player-horizontal-scrub-live-preview-luna-plan.md

先从最新 origin/main 创建 agent/player-scrub-live-preview，记录实际 base SHA。
不要在 goal 分支开发，不要合并 main。
先完成 Phase 0 客户端独立抽帧 Probe，并按 Gate A 的 A/B/C 结果继续。
无论客户端抽帧是否可行，都必须至少完成 Gate C：可调横滑跨度、进度条上方 Trickplay、时间降级、松手单次 seek、取消不 seek。
按阶段提交、推送 Draft PR，并用本文第 25 节格式回报。
```
