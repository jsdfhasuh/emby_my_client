# Moonfin-Core 借鉴迁移计划

更新日期：2026-07-30

参考仓库：[Moonfin-Client/Moonfin-Core](https://github.com/Moonfin-Client/Moonfin-Core)

分析基线：`main` 分支提交 `1b203f43efb3bd0e9d2589340c00b6c443d3ee8c`

## 1. 目标

在保留当前 Flutter Android 客户端轻量结构的前提下，借鉴 Moonfin-Core
成熟的 Emby 播放协商、播放状态管理和观看体验，逐步完成一个稳定、可诊断、
可长期扩展的 Emby 客户端。

本计划优先解决播放可靠性，再增加轨道、清晰度、连续播放和服务端实时联动。
离线下载、Live TV、投屏和多服务器属于后续独立项目，不进入第一轮改造。

## 2. 当前基线

当前已实现：

- Emby 服务器登录及会话安全存储。
- 首页、媒体库、搜索、详情、季和剧集列表。
- 基于 `media_kit` 和 libmpv 的 Android 视频播放。
- DirectPlay、DirectStream、Transcode 分级协商和单次自动转码回退。
- ready 后断点恢复、播放会话上报和服务端转码资源清理。
- 媒体版本、最大码率、音轨、字幕和外挂字幕选择。
- 横滑定位、双击快进/后退、亮度、音量、控制锁和画中画。
- 播放队列、跨季连续播放、章节、片头跳过和 Trickplay 预览。
- 播放请求认证头。
- 持久化、脱敏的诊断日志。

当前剩余缺口：

- 阶段 2 至阶段 7 已完成代码实现和本地质量门槛，但仍缺 Android
  真机端到端验收。
- 收藏、观看状态、WebSocket 事件和远程控制需要在真实 Emby 服务器验收。
- UDP 7359 发现需要在有 Emby 服务器的真实局域网和 Android 设备验收。
- 阶段 8.0 共同基础已完成代码和本地门槛。
- 阶段 8.1 的数据库、原始下载、Android `dataSync` 前台服务、下载策略、
  附属资源、清理、最小离线播放和进度冲突同步已完成代码与本地测试。
- 阶段 8.1 仍缺本轮 APK 构建与模拟器回归、Android 15 及以上的重启恢复策略，
  以及真实服务器和物理设备验收。
- Live TV、投屏、多服务器和 Android TV 尚未实现。
- SyncPlay 尚未确认 Emby 对等协议，保持协议阻塞。

## 3. 实施原则

- 不整体复制 Moonfin-Core 的工程结构。
- 保留单平台、单服务器客户端的轻量边界。
- 播放协议、播放器生命周期和播放器 UI 分离。
- 所有播放回退必须有限次，禁止循环重试。
- 所有异步播放操作必须可被新会话或页面退出取消。
- 所有认证信息在日志、异常和导出文本中必须脱敏。
- 每个阶段必须通过静态检查、自动测试、APK 构建和真机验证。
- 参考 Moonfin 的行为和架构后独立实现，不直接复制 GPL v2 代码。

## 4. 交付里程碑

### 里程碑 A：播放可靠性

包含阶段 0 至阶段 3。

交付结果：

- 稳定的播放启动状态机。
- 可靠的断点续播。
- DirectPlay/DirectStream 失败后自动转码一次。
- 正确、幂等的播放停止和服务端资源清理。
- 能解释播放决策的诊断日志。

### 里程碑 B：完整播放器

包含阶段 4 至阶段 5。

交付结果：

- 媒体版本、清晰度、音轨和字幕切换。
- 外挂字幕支持。
- 完整移动端播放手势和画中画。
- 播放设置按服务器和用户持久化。

### 里程碑 C：连续观看与实时同步

包含阶段 6 至阶段 7。

交付结果：

- 播放队列和自动下一集。
- 片头片尾跳过和 Trickplay 预览。
- 收藏、观看状态和 WebSocket 实时刷新。
- 局域网 Emby 服务器自动发现。

### 里程碑 D：大型扩展

阶段 8，每项单独设计和交付。

## 5. 分阶段改动

### 阶段 0：测试基线

状态：完成（2026-07-30）

计划改动：

- [x] 为 PlaybackInfo 完整请求成功增加测试。
- [x] 为 HTTP 400、422、500 的分级回退增加测试。
- [x] 验证 HTTP 401、403 不执行 PlaybackInfo 回退。
- [x] 测试 DirectPlay、DirectStream、Transcode 媒体源选择顺序。
- [x] 测试指定媒体源 ID 和失效媒体源 ID 的处理。
- [x] 测试相对流 URL、绝对流 URL 和重复查询参数规范化。
- [x] 测试播放认证头始终传递给 libmpv。
- [x] 测试播放开始、进度、暂停、停止和转码清理请求。
- [x] 测试日志对 URL Token、请求头和异常文本的脱敏。

验收标准：

- 所有现有测试继续通过。
- 新增协议测试不依赖真实服务器。
- 测试日志和失败输出中不存在认证凭据。

### 阶段 1：轻量播放架构

状态：完成（2026-07-30）

计划新增：

```text
lib/playback/playback_controller.dart
lib/playback/playback_state.dart
lib/playback/emby_stream_resolver.dart
lib/playback/playback_session_reporter.dart
lib/playback/track_mapper.dart
```

职责划分：

- [x] `PlaybackController` 管理 Player、状态流、启动、seek、暂停和停止。
- [x] `EmbyStreamResolver` 负责 PlaybackInfo 和媒体流 URL 解析。
- [x] `PlaybackSessionReporter` 负责 Emby 播放会话上报和资源清理。
- [x] `PlaybackState` 描述解析、打开、等待、恢复、就绪和失败状态。
- [x] `PlayerScreen` 只保留视频表面、控制层和手势。
- [x] 保持现有 `AppController`，暂不引入 Riverpod 或 GetIt。

验收标准：

- 重构前后的登录、浏览和基础播放行为一致。
- 播放页面不直接构造 PlaybackInfo 请求。
- 播放停止逻辑只有一个所有者。

### 阶段 2：播放协商和 DeviceProfile

状态：代码完成，待真机验收

计划改动：

- [x] 增加类型化 `PlaybackInfoResult`。
- [x] `PlaySessionId` 改为可空，不再生成本地假 ID。
- [x] 记录服务器 `ErrorCode` 和 `TranscodingReasons`。
- [x] PlaybackInfo 采用完整请求、去 Profile、最小请求三级策略。
- [x] 只有 400、422、500 才进入兼容回退。
- [x] 401、403 直接触发会话失效。
- [x] 支持按 `MediaSourceId` 选择媒体版本。
- [x] 指定媒体源失效时回退服务器默认版本。
- [x] 规范化 AudioStreamIndex 和 SubtitleStreamIndex 参数大小写。
- [x] 避免重复的流索引参数被 Emby 合并成非法值。
- [x] 保留媒体请求认证头，不退回到仅 URL Token 的实现。
- [x] 建立适合 Android libmpv 的视频、音频和字幕能力 Profile。
- [x] 增加用户最大流媒体码率设置。

诊断日志需要记录：

- [x] 播放方式和媒体源 ID。
- [x] 容器、视频编码、Profile、Level、分辨率和 HDR 类型。
- [x] 音频编码、声道数和选中音轨。
- [x] 字幕编码、类型和选中字幕。
- [x] 最大流媒体码率、实际传输码率和转码原因。

验收标准：

- 相同媒体能够稳定得到可解释的播放决策。
- 不兼容编码不会因为宽泛 Profile 被错误声明为 DirectPlay。
- 认证失败不会触发无意义的 Profile 重试。

### 阶段 3：播放启动、恢复和清理

状态：代码完成，待真机验收

播放状态：

```text
idle
resolving
opening
waitingForReady
seekingResume
ready
retryingWithTranscode
failed
stopping
```

计划改动：

- [x] 每次播放生成递增会话令牌。
- [x] 页面退出或新播放开始后，旧异步任务不再更新状态。
- [x] 有断点时暂停打开媒体。
- [x] 等待 duration、position、buffer 或 playing 表明媒体已 ready。
- [x] 在线播放 ready 等待设置有限超时。
- [x] ready 后执行断点 seek。
- [x] 验证实际位置已接近目标位置后再恢复播放。
- [x] DirectPlay/DirectStream 未 ready 时自动强制 Transcode 一次。
- [x] Transcode 仍失败时终止回退并显示错误。
- [x] 播放真正 ready 后才上报 PlaybackStart。
- [x] 播放时定时上报进度。
- [x] 暂停、恢复、seek 和应用进入后台时补充上报。
- [x] 停止上报最多执行一次。
- [x] 停止时关闭 LiveStream。
- [x] 停止时按 PlaySessionId 清理 ActiveEncoding。
- [x] 退出失败不阻止 Player 本地释放。

验收标准：

- 断点续播不再出现首次 seek 失败。
- 快速进入和退出播放器不产生晚到的 setState 或 Player 异常。
- DirectPlay 故障只触发一次自动转码。
- 退出后服务器不残留转码任务。

### 阶段 4：媒体版本、清晰度、音轨和字幕

状态：代码完成，待真机验收

计划改动：

- [x] 在播放器中展示服务器返回的媒体版本。
- [x] 支持原始质量和指定最大码率。
- [x] 展示音轨语言、标题、编码、声道数和默认标记。
- [x] 展示字幕语言、标题、编码、强制、默认和外挂标记。
- [x] 支持关闭字幕。
- [x] 实现 Emby MediaStream Index 与 libmpv 轨道序号映射。
- [x] 等待播放器轨道列表 ready 后再应用选择。
- [x] 解析并加载外部字幕 `DeliveryUrl`。
- [x] 外部字幕请求携带安全认证。
- [x] DirectPlay 尽量在运行时切换轨道。
- [x] DirectStream/Transcode 切换轨道时重新协商流。
- [x] 切换码率时在当前位置重新协商流。
- [x] 串行化重新协商，避免快速切换产生竞争。
- [x] 重开流前停止旧播放器，再清理旧服务端会话。
- [x] 切换后恢复当前位置和播放/暂停状态。
- [x] 上报当前音轨和字幕索引。

验收标准：

- 音轨和字幕选择与实际播放内容一致。
- 多次快速切换不会创建多个并行转码会话。
- 切换后位置偏差控制在约 2 秒内。

### 阶段 5：播放器交互和设置

状态：代码完成，待真机验收

计划改动：

- [x] 保留整屏横向滑动定位。
- [x] 增加左半屏双击后退、右半屏双击快进。
- [x] 左半屏上下滑调节应用亮度。
- [x] 右半屏上下滑调节系统音量。
- [x] 顶部保留系统通知栏手势死区。
- [x] 增加播放器控制锁。
- [x] 增加缓冲进度显示。
- [x] 增加播放速度选择。
- [x] 增加画面适应、填充和裁剪模式。
- [x] 增加字幕延迟和音频延迟。
- [x] 增加字幕字号、颜色、描边和位置设置。
- [x] 增加 Android 画中画。
- [x] 画中画中支持播放、暂停和退出。
- [x] 设置按服务器 ID 和用户 ID 隔离保存。
- [x] 快进、后退时长可配置。

验收标准：

- 横滑、双击、垂直滑动和进度条之间无明显手势冲突。
- 锁定后不会误触控制按钮或手势。
- 进入和退出画中画不会重建播放会话。

### 阶段 6：连续观看

状态：代码和本地质量门槛完成，待真机验收

计划改动：

- [x] 从剧集列表构建播放队列。
- [x] 播放完成后自动进入下一集。
- [x] 手动上一集和下一集。
- [x] 跨季自动加载下一季。
- [x] 片尾阶段显示下一集倒计时和立即播放入口。
- [x] 支持取消自动下一集。
- [x] 解析 Emby Chapter Marker。
- [x] 支持 `IntroStart`、`IntroEnd` 和 `CreditsStart`。
- [x] 在片头范围显示跳过片头按钮。
- [x] 在片尾范围显示立即播放下一集入口。
- [x] 支持章节列表和章节跳转。
- [x] 服务器支持时显示 Trickplay 进度预览图。
- [x] 连续自动播放 3 集后显示“还在观看吗”。
- [x] 切集前停止并清理旧会话，再创建新的 Player 和播放会话。

验收标准：

- 自动下一集前正确停止并上报上一集。
- 片头片尾按钮只在有效时间范围内显示。
- 播放队列结束后播放器正常退出或停留，不重复播放。

### 阶段 7：服务端实时联动

状态：代码和本地质量门槛完成，待真实服务器和真机验收

计划改动：

- [x] 增加收藏和取消收藏。
- [x] 增加标记已观看和未观看。
- [x] 操作成功后重新读取服务端权威状态。
- [x] 从详情页或播放器返回后刷新首页、媒体库和搜索结果。
- [x] 接入 Emby WebSocket。
- [x] 处理 `ForceKeepAlive`。
- [x] 实现有上限的指数退避和随机抖动重连。
- [x] 处理 `LibraryChanged`。
- [x] 处理 `UserDataChanged`。
- [x] 播放时处理暂停、继续、停止、跳转、切集、快进和后退命令。
- [x] 校验远程命令携带的 Item ID 和 PlaySessionId。
- [x] 每次 WebSocket 连接成功后上报客户端远程控制能力。
- [x] 应用后台时断开 WebSocket，播放或画中画期间保持连接。
- [x] UDP 7359 广播发现 Emby 服务器。
- [x] 登录页展示发现的服务器并允许填入地址。
- [x] 规范化服务器地址，并按服务器 ID 或端点双重去重。

验收标准：

- 其他客户端修改观看状态后，本客户端能刷新。
- 网络切换后 WebSocket 能恢复且不会高频重连。
- 同一局域网服务器能够自动发现并直接选择。

### 阶段 8：大型扩展项目

状态：设计计划完成；阶段 8.0 完成；阶段 8.1 离线下载实施中

总索引：[阶段 8 设计索引](design/STAGE8_INDEX.md)

独立设计文档：

- [ ] [离线下载、转码下载和离线进度同步](design/OFFLINE_DOWNLOADS.md)
  （首版代码已完成本地测试，待平台构建和端到端验收）。
- [ ] [Live TV、节目单和录制管理](design/LIVE_TV.md)。
- [ ] [Emby Remote、Google Cast、DLNA 和 AirPlay](design/CASTING.md)。
- [ ] [多服务器账户和统一媒体库](design/MULTI_SERVER.md)。
- [ ] [SyncPlay 能力验证与实现](design/SYNCPLAY.md)。
- [ ] [Android TV 遥控器和焦点导航](design/ANDROID_TV.md)。

推荐实施顺序：

1. [x] 增加 `ServerScope`、服务器能力和本地数据库的最小共同基础。
2. 离线下载（实施中）。
3. Live TV。
4. Android TV。
5. 投屏。
6. 多服务器。
7. SyncPlay 只在确认 Emby 存在对等协议后实施。

这些功能不得直接堆入现有 `EmbyApi`、`AppController` 或 `PlayerScreen`。
每一项必须独立开关、独立验收，不同时实施两个大型项目。

阶段 8.0 已新增：

```text
lib/core/server_scope.dart
lib/core/server_capabilities.dart
lib/data/client_registry.dart
lib/data/local_database.dart
lib/data/server_capabilities_repository.dart
test/server_scope_test.dart
test/client_registry_test.dart
test/local_database_test.dart
```

已实现：

- 当前单服务器会话使用 `serverId + userId` Scope。
- 旧会话缺少 Server ID 时使用不含凭据的确定性端点后备 Scope。
- `AppController` 通过注册表统一创建和释放当前 `EmbyApi`。
- 服务器产品名和版本随会话保存，并保持旧会话数据兼容。
- WebSocket 远程控制能力上报成功后保存类型化能力证据。
- SQLite schema v2、事务边界和 v1 到 v2 迁移。
- 数据库故障只禁用本地能力，不阻断现有在线播放。
- Scope 日志标签不可直接还原用户 ID，数据库不保存 Token。

阶段 8.1 当前已新增：

```text
lib/downloads/download_models.dart
lib/downloads/download_repository.dart
lib/downloads/download_service.dart
lib/downloads/download_transport.dart
lib/downloads/download_executor.dart
lib/downloads/download_settings.dart
lib/downloads/download_preflight.dart
lib/downloads/foreground_download_executor.dart
lib/downloads/download_assets.dart
lib/downloads/download_cleanup.dart
lib/offline/offline_playback_resolver.dart
lib/offline/offline_playback_reporter.dart
lib/offline/offline_progress_sync.dart
lib/ui/downloads/downloads_screen.dart
test/download_service_test.dart
test/download_repository_test.dart
test/download_transport_test.dart
test/download_assets_test.dart
test/download_cleanup_test.dart
test/offline_playback_test.dart
test/offline_progress_sync_test.dart
test/downloads_ui_test.dart
```

当前实现：

- SQLite schema v3 和下载、离线项目、离线进度三张 Scope 隔离表。
- 原始文件队列、暂停、续传、取消、删除、有限重试和原子完成。
- Token 只放认证头，不进入下载 URL、SQLite 或诊断错误文本。
- 进程中断恢复、缺失完成文件失效和基本媒体内容/长度校验。
- 最小离线目录、本地播放和 pending 离线进度写入。
- 本地播放不请求 PlaybackInfo、不建立在线播放会话、不保持 WebSocket、
  不执行转码回退。
- 电影和剧集详情下载操作、下载管理入口和下载状态页面。
- Android `dataSync` 前台服务 isolate 从安全存储重新读取会话，命令只传任务 ID。
- 私密通知展示进度、暂停和取消，不展示服务器地址或媒体标题。
- “仅 Wi-Fi”策略、网络条件检查和包含安全余量的剩余空间预检。
- 下载同源海报和外挂字幕，跨域字幕拒绝，字幕地址改写为本地文件路径。
- 7 天无主文件保留期清理；附属资源失败不回滚已完成的视频文件。
- 离线进度同步采用服务端已观看优先，否则选择更远位置；失败后 5 分钟重试，
  且同步期间产生的新本地进度不会被旧结果覆盖。

仍未完成：

- 重新构建三 ABI APK，并在模拟器验证 Manifest 合并、AOT 回调入口和插件注册。
- Android 15 及以上禁止 `BOOT_COMPLETED` 直接启动 `dataSync` 前台服务；
  必须改用受约束的恢复入口，或关闭开机自启并明确为“再次打开应用后恢复”。
- 审计下载删除逻辑的绝对路径比较，覆盖数据库中存在相对路径的兼容场景。
- 物理设备、真实 Emby、大文件中断和断网播放验收。
- 通知按钮、锁屏、切后台、杀进程、设备重启和飞行模式字幕播放验收。
- 离线进度冲突策略在真实 Emby 上的端到端验收。
- 转码下载。

## 6. 测试矩阵

| 场景 | 预期 |
|---|---|
| H.264 + AAC MP4 | 优先 DirectPlay |
| HEVC 10-bit MKV | 根据 Profile 选择 DirectPlay 或 Transcode |
| 4K 高码率媒体 | 受用户最大码率设置控制 |
| 不支持的视频编码 | DirectPlay 失败后自动 Transcode 一次 |
| 多音轨文件 | 正确选择和切换音轨 |
| 内嵌文本字幕 | 正确显示和关闭 |
| PGS 等图形字幕 | 设备可渲染时直放，否则服务端烧录 |
| 外挂字幕 | 携带认证并正确加载 |
| 有断点的媒体 | ready 后恢复，位置接近目标 |
| 播放中横向滑动 | 只在松手时执行一次 seek |
| 播放中切换清晰度 | 重开流后保持当前位置 |
| 播放中断网 | 显示可诊断错误，不无限重试 |
| 快速进入并退出 | 无晚到状态更新或残留转码 |
| 应用进入后台 | 进度上报正确，播放器按策略暂停或进入画中画 |
| 连续播放下一集 | 上一集停止和下一集开始会话顺序正确 |

## 7. 每阶段质量门槛

每次交付必须执行：

```powershell
dart format lib test
flutter analyze
flutter test
flutter build apk --debug --split-per-abi
```

真机连接时至少验证：

- 启动播放。
- 断点续播。
- 暂停和恢复。
- 进度条和横向滑动 seek。
- 后台和前台切换。
- 返回播放器上一级。
- 查看诊断日志。
- 确认服务器没有残留转码任务。

## 8. 许可边界

Moonfin-Core 使用 GNU GPL v2。

本项目可以：

- 研究其公开协议交互和行为。
- 借鉴模块职责、状态机和异常处理思路。
- 根据 Emby API 独立重写实现。

在没有决定将本项目按 GPL 兼容方式分发前，不直接复制 Moonfin-Core
源文件或大段实现代码。若未来需要直接使用其代码，必须先确定项目许可证、
源码分发方式和对应义务。

## 9. 当前推荐执行顺序

### 批次 1：阶段 6 构建与回归（本地完成，待真机）

1. 执行格式化、静态检查和全部单元测试。
2. 重新构建三个 ABI 的 Debug APK。
3. 真机验证播放、横滑、轨道切换、Trickplay、自动下一集和画中画。
4. 在 Emby 服务端确认退出或切集后没有残留转码任务。
5. 记录不支持的媒体样本、转码原因和对应诊断日志。

完成定义：

- 自动化检查全部通过。
- APK 能安装并启动。
- 阶段 2 至阶段 6 的真机验收项全部有结果记录。
- 发现的问题先回收到对应阶段，不带已知播放阻断进入阶段 7。

### 批次 2：收藏和观看状态（代码完成，待真实服务器验收）

已新增：

```text
lib/data/emby_user_data_service.dart
test/emby_user_data_service_test.dart
```

计划修改：

- `emby_user_data_service.dart` 封装收藏和观看状态请求，避免继续扩大
  `EmbyApi` 的职责。
- `item_detail_screen.dart` 增加收藏、取消收藏、标记已观看和未观看操作。
- `media_widgets.dart` 统一更新收藏和观看状态图标。
- 操作成功后重新获取权威服务端数据；失败时恢复 UI 并显示可诊断错误。
- 对 401、403 复用现有会话失效处理。

完成定义：

- 电影、剧集和单集详情页均可修改状态。
- 返回列表后状态一致，不需要重启应用。
- 请求失败不会留下错误的乐观 UI 状态。

### 批次 3：WebSocket 实时联动（代码完成，待真实服务器验收）

已新增：

```text
lib/realtime/emby_event.dart
lib/realtime/emby_websocket_client.dart
test/emby_websocket_client_test.dart
```

计划修改：

- `emby_websocket_client.dart` 负责连接、鉴权、KeepAlive、关闭和重连。
- `emby_event.dart` 类型化解析 `LibraryChanged`、`UserDataChanged` 和
  `Playstate` 消息。
- 使用有上限的指数退避和随机抖动，网络恢复后只保留一个连接。
- `app_controller.dart` 根据前后台生命周期调整连接活跃度。
- 列表页和详情页只订阅领域事件，不直接管理 WebSocket。
- 播放控制命令转交给 `PlaybackController`，并校验目标会话和 Item ID。
- 事件日志不记录 Token、完整鉴权 URL 或用户隐私数据。

完成定义：

- 其他客户端修改收藏或观看状态后，当前页面能刷新。
- 网络断开和恢复不会产生连接风暴或重复事件。
- 后台、登出和切换服务器时连接能及时关闭。
- 远程播放命令不会控制错误的本地播放会话。

### 批次 4：UDP 服务器发现（代码完成，待真机局域网验收）

已新增：

```text
lib/discovery/emby_server_discovery.dart
lib/models/discovered_server.dart
test/emby_server_discovery_test.dart
```

计划修改：

- 使用 UDP 7359 广播发现局域网 Emby 服务器。
- 对响应做结构化解析、地址规范化、去重和超时收敛。
- `login_screen.dart` 展示发现结果，并允许一键填入服务器地址。
- 手动输入始终保留，不让发现失败阻塞登录。
- Android 清单只增加实际需要的网络权限。

完成定义：

- 同一局域网服务器可在有限时间内出现。
- 重复响应、IPv4 地址格式差异和服务器重启不会产生重复条目。
- 无局域网权限、无响应或超时时登录页仍可正常使用。

### 批次 5：阶段 8 独立立项

设计计划已完成，入口为
[阶段 8 设计索引](design/STAGE8_INDEX.md)。六个功能文档均已说明：

- 用户场景和非目标。
- Emby API、数据模型和状态所有者。
- Android 平台能力与权限。
- 存储、缓存、清理和错误恢复策略。
- 对现有播放会话的影响。
- 自动化测试和真机验收矩阵。
- Moonfin-Core GPL v2 参考边界。

阶段 8.0 最小共同基础已完成。阶段 8.1 首版代码已覆盖原始下载、Android
前台服务、下载策略、附属资源、清理、最小离线播放和进度同步。下一步按
[离线下载设计计划](design/OFFLINE_DOWNLOADS.md)完成平台构建回归、Android 15
恢复策略和真实设备验收。SyncPlay 继续保持协议阻塞，不把 Jellyfin
`/SyncPlay/*` 接口当作 Emby 接口。

## 10. 最新验证记录

验证日期：2026-07-30

已通过：

```text
dart format lib test
flutter analyze                         No issues found
flutter test                            78 tests passed
```

以下 APK 是较早源码状态的构建产物；加入 Android 前台下载服务和最新离线能力后，
必须重新执行 `flutter build apk --debug --split-per-abi`，不能作为本轮构建证据：

```text
build/app/outputs/flutter-apk/app-armeabi-v7a-debug.apk
build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
build/app/outputs/flutter-apk/app-x86_64-debug.apk
```

Android 模拟器验证：

- 已启动 Pixel 8 Android 17（API 37）x86_64 模拟器。
- 已重新安装最终源码构建的 `app-x86_64-debug.apk` 并成功启动。
- 应用进程无崩溃、未发现 Flutter Widget 异常或 RenderFlex 溢出。
- 登录页在 1080×2400 竖屏和 2400×1080 横屏均能正常绘制和滚动。
- UDP 扫描无响应时能在有限时间内显示“未发现局域网服务器”。
- 验证截图保存在 `build/qa/emby-login-portrait.png` 和
  `build/qa/emby-login-final.png`。
- 阶段 8.0 最终 x86_64 APK 已重新安装并启动。
- Android 应用私有目录已创建 20480 字节的 `emby_client.db`。
- 启动日志未发现 Flutter、AndroidRuntime 或 SQLite 异常。
- 阶段 8.0 登录页截图保存在 `build/qa/emby-stage8-foundation.png`。
- 阶段 8.1 x86_64 APK 已覆盖安装并冷启动，进程和 Activity 正常。
- 阶段 8.1 启动日志未发现 Flutter、AndroidRuntime 或 SQLite 异常。
- 阶段 8.1 启动画面保存在 `build/qa/emby-stage8-downloads.png`；因为模拟器
  没有 Emby 会话，该截图只能证明登录页冷启动，不能证明真实下载流程。
- 首次启动曾因模拟器最低内存水位被系统 `lowmemorykiller` 终止，不是应用异常；
  清理缓存进程后再次冷启动并保持运行。

当前仍未连接 Android 物理设备，也没有在模拟器中配置可登录的真实 Emby
服务器。因此以下证据仍缺失：

- Android 物理设备安装和启动。
- 真实媒体播放、轨道切换、横滑定位、Trickplay 和自动下一集。
- 画中画进入、控制和退出。
- 真实 Emby 服务器上的收藏、观看状态和页面实时刷新。
- WebSocket 断网恢复、`ForceKeepAlive` 和远程 `Playstate` 控制。
- 真实局域网 UDP 7359 服务器发现。
- 退出、切集和重协商后服务端不存在残留转码任务。
- 真实媒体原始下载、Range 大文件续传、取消、删除和重新下载。
- 切后台、锁屏、杀进程和设备重启后的下载恢复与通知操作。
- 飞行模式离线目录、播放、定位和外挂字幕。
- 离线进度重新联网后同步到 Emby。
