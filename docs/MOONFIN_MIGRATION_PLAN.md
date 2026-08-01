# Moonfin-Core 借鉴迁移计划

更新日期：2026-07-31

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
- 媒体库总数、分类快捷入口、服务端排序和组合筛选。
- 搜索防抖、相关性结果、媒体类型筛选、分页、文件夹结果和分用户最近搜索。
- 响应式首页媒体架、分媒体库最新内容、继续观看横版卡片和未观看数量角标。
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
- 阶段 8.1 已完成本轮三 ABI 构建、Android 15 及以上恢复策略、文件边界审计，
  以及真实服务器和物理设备上的原始下载、暂停、续传、取消、删除和最小离线播放。
- 阶段 8.1 仍缺下载中的 Wi-Fi/移动网络切换、空间不足、设备重启、飞行模式
  外挂字幕样本和真实离线进度冲突验收；飞行模式本地目录、海报、播放、定位和
  重新联网自动同步已通过真机验收。
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

### 阶段 7.1：媒体库浏览和筛选

状态：完成；代码、本地质量门槛、主界面和筛选面板均已通过真机验收

参考 Emby 原版媒体库工具栏和 Moonfin 的集中式浏览状态后独立实现：

- [x] 显示服务端返回的媒体总数。
- [x] 增加节目、电影、剧集、视频、收藏和文件夹快捷入口。
- [x] 文件夹模式只读取当前目录层级，点击目录后继续按 `ParentId` 下钻。
- [x] 设置页可分别显示或隐藏电影、剧集、视频、收藏和文件夹快捷入口。
- [x] 分类偏好按服务器和用户隔离保存；默认仅显示节目、收藏和文件夹。
- [x] 增加名称、加入日期、首映日期、年份、评分和时长排序。
- [x] 支持升序和降序切换。
- [x] 支持已播放、未播放、项目类型和收藏组合筛选。
- [x] 筛选条件提交前保留在面板草稿中，取消面板不会发起新请求。
- [x] 排序和筛选通过 Emby `/Users/<userId>/Items` 服务端参数执行。
- [x] 分页使用 `TotalRecordCount` 判断结束，不再只依赖页面长度。
- [x] 切换条件时忽略旧请求的晚到结果，避免混入上一组数据。
- [x] 增加 API 参数和筛选交互 Widget 测试。

验收标准：

- 真实媒体库切换排序或筛选后，总数和项目列表同步变化。
- 快速切换多个条件时不会短暂显示上一组结果。
- 空结果、加载失败和继续分页均有明确界面状态。
- 1080×2400 竖屏不出现控件重叠或 RenderFlex 溢出。

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
lib/downloads/download_integrity.dart
lib/downloads/download_settings.dart
lib/downloads/download_preflight.dart
lib/downloads/foreground_download_executor.dart
lib/downloads/download_assets.dart
lib/downloads/download_cleanup.dart
lib/data/account_data_cleanup.dart
lib/offline/offline_playback_resolver.dart
lib/offline/offline_playback_reporter.dart
lib/offline/offline_progress_sync.dart
lib/ui/downloads/downloads_screen.dart
test/download_service_test.dart
test/download_integrity_test.dart
test/download_repository_test.dart
test/download_transport_test.dart
test/download_assets_test.dart
test/download_cleanup_test.dart
test/account_data_cleanup_test.dart
test/offline_playback_test.dart
test/offline_progress_sync_test.dart
test/downloads_ui_test.dart
```

当前实现：

- SQLite schema v4 和下载、离线项目、离线进度三张 Scope 隔离表；v4 只增加
  下载摘要字段，不移动既有媒体。
- 原始文件队列、暂停、续传、取消、删除、有限重试和原子完成。
- Token 只放认证头，不进入下载 URL 或 SQLite；诊断日志统一移除网络 URL 和
  鉴权值，并在启动时清洗旧日志。
- 进程中断恢复，以及启动恢复和播放前的完成文件存在性、可读性与长度检查。
  本地成品丢失或损坏时撤销可播放记录并显示“重新下载”；只有用户明确点击后才
  清理坏文件、断点、ETag 和摘要，并从安全目录的 0 字节重新排队，不回退在线流。
- 支持 `Repr-Digest`、`Digest`、完整响应的 `Content-Digest` 和
  `Content-MD5`，优先 SHA-256、其次 MD5；摘要持久化并用于 Range 续传后的
  整文件流式校验，不把 ETag 当摘要。
- Range 固定请求 `Accept-Encoding: identity`；ETag 或摘要变化时关闭当前响应并
  从零下载。摘要失败会删除坏载荷、清空断点并明确报错，不回退其他下载端点。
- 自动化测试覆盖 401/403、429/5xx 有界退避、ETag 变化、长度不符、HTTP 416、
  非媒体响应释放、重复投递幂等和非空间文件系统失败。
- 最小离线目录、本地播放和 pending 离线进度写入。
- 本地播放不请求 PlaybackInfo、不建立在线播放会话、不保持 WebSocket、
  不执行转码回退。
- 电影和剧集详情下载操作、下载管理入口和下载状态页面。
- 下载页汇总当前 Scope 的媒体文件和断点占用，并区分可离线播放与未完成项目。
- Android `dataSync` 前台服务 isolate 从安全存储重新读取会话，命令只传任务 ID。
- Android worker 串行执行暂停、继续、删除、设置刷新和唤醒命令；单个命令失败
  不阻塞后续命令，服务销毁前会封闭并等待命令队列，避免刷新与删除交错恢复
  陈旧任务或关闭数据库时仍有命令写入。
- 私密通知展示进度、暂停和取消，不展示服务器地址或媒体标题。
- “仅 Wi-Fi”策略、网络条件检查和包含安全余量的剩余空间预检。
- 下载 worker 监听网络变化；不符合当前策略时把任务持久化为
  `waitingForNetwork`、立即中止传输且保留 `.part`，网络恢复后使用 Range/ETag
  自动续传。手动暂停不会被网络恢复覆盖，主 isolate 的策略修改会通知 worker
  重新加载。
- 下载前空间预检失败仍阻止创建任务；传输中系统明确返回 ENOSPC 时，任务持久化为
  `waitingForStorage` 并保留 `.part`。worker 每 15 秒重新检查一次剩余空间，条件
  恢复后自动使用 Range/If-Range 续传；等待期间可以暂停或取消。
- 网络异常收尾会在写入等待状态前重新读取最新用户命令，避免旧异常异步覆盖稍后
  发出的暂停或取消。
- 下载同源海报和外挂字幕，跨域字幕拒绝，字幕地址改写为本地文件路径。
- 新任务将成品、断点和附属资源分别写入 Scope 下的 `media/`、`parts/` 和
  `assets/`；附属资源的 `.part` 也只进入 `parts/assets/`。已有根目录或相对路径
  记录继续按原位置使用，不复制或迁移大文件。
- 启动恢复会校正数据库记录有断点字节数但 `.part` 已丢失的任务，清零陈旧字节数
  和 ETag，避免后续发送错误 Range。
- 所有删除先持久化 `cancelling`，再删除任务文件，最后在事务中移除下载、离线项目
  和无剩余离线版本的进度记录；进程中断后下一次启动继续完成删除。
- 普通退出继续保留离线数据；设置页提供带二次确认的“删除此账户数据”，先等待
  Android worker 停止，再删除该 Scope 的媒体目录、SQLite 记录、搜索历史和下载、
  分类、播放设置。目录名不匹配 Scope 时拒绝执行，其他账户数据保持不变。
- 7 天无主文件保留期清理；附属资源失败不回滚已完成的视频文件。
- 附属图片或字幕因状态码、类型、大小、空响应或文件错误提前失败时会取消响应并
  删除无续传价值的 `.part`，避免后台连接继续占用网络。
- 离线进度同步采用服务端已观看优先，否则选择更远位置；失败后 5 分钟重试，
  `pending`、`syncing` 和最终状态通过 SQLite 原子条件更新提交；同步期间或提交
  瞬间产生的新本地进度会使旧结果更新 0 行，不会被覆盖。
- WebSocket 每次连接成功都会触发离线进度同步；明确恢复联网时允许绕过旧失败
  记录的重试时间，持续断网时仍保留 5 分钟退避。
- SQLite 使用 WAL；前台服务运行期间由 worker isolate 独占任务状态写入，
  主 isolate 合并并串行刷新，避免跨 isolate 写竞争。
- worker 使用独立的非单实例数据库句柄，关闭 worker 不会关闭主数据库；
  暂停只在传输操作真正收尾后停止前台服务。
- 通知“暂停”和“取消”均已通过 Android PendingIntent 真机点击；强制终止应用后，
  用户重新打开应用会从持久化断点恢复下载。
- 账户清理版本已覆盖安装；真机确认设置入口、危险色和二次确认弹窗可达，取消后
  登录态和原有 3.4 GB 离线文件保持不变，冷启动无 Flutter、SQLite 或原生崩溃。
- 下载占用汇总版本已覆盖安装；真实下载页显示“媒体文件占用 3.43 GB”和
  “1 个可离线播放”，与应用私有目录约 3.4 GB 一致。1080×2400 布局无重叠，
  截图保存在 `build/qa/download-storage-summary.png`。
- 标准摘要和 schema v4 版本已完成三 ABI 构建并覆盖安装到同一真机。安装前数据库
  为 v3、1 条已完成任务、`3,679,942,140` 下载字节；冷启动后数据库为 v4，
  `PRAGMA integrity_check` 为 `ok`，任务数量、完成状态和字节数完全不变。
- 既有 3.43 GB 媒体和海报的大小、时间戳未变化，无活动任务时 `dataSync` 服务
  未启动；日志无 AndroidRuntime、Flutter 或 SQLite 异常，原始和编码 URL 均为
  0。下载页截图保存在 `build/qa/download-integrity-migration.png`。
- 自动化测试覆盖完成文件在启动时和播放前被截断、离线记录失效、UI 明确显示
  “重新下载”，以及重新下载清空旧 ETag/摘要并从 0 字节开始；运行期只读取文件
  长度，不重新哈希既有 3.43 GB 媒体。

仍未完成：

- 下载中的 Wi-Fi/移动网络切换、空间不足和设备重启验收。
- 飞行模式外挂字幕验收；当前真实离线样本不含外挂字幕。
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

验证日期：2026-07-31

已通过：

```text
dart format lib test
flutter analyze                         No issues found
flutter test                            165 tests passed
flutter build apk --debug --split-per-abi
```

以下 APK 已从本轮最终源码重新构建：

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

Android 物理设备和真实 Emby 验证：

- 目标设备为 `9798ef47`，Xiaomi 22021211RC、Android 14、arm64-v8a。
- `app-arm64-v8a-debug.apk` 已使用 `adb install -r` 覆盖安装，登录数据保留。
- 覆盖安装后的冷启动成功，未发现 Flutter 异常或 Android 崩溃。
- 网络等待状态版本已重新完成三 ABI 构建并覆盖安装 arm64 APK；应用进程和前台
  Activity 正常，未发现 `AndroidRuntime`、`E/flutter`、插件或 SQLite 异常。
- 关闭 Wi-Fi 后 WebSocket 按约 2.2 秒、4.1 秒和 10 秒逐步退避；恢复 Wi-Fi 后
  自动重连并重新上报远程控制能力，未出现高频重连。
- 媒体库筛选版本已覆盖安装；真实 1080×2400 媒体库显示 `共 448 项`，
  快捷入口、排序、升降序和筛选入口均正常绘制。
- 分类设置版本已覆盖安装；账号菜单可进入设置，电影、剧集、视频默认关闭，
  收藏和文件夹默认开启；重新进入真实媒体库后仅显示节目、收藏和文件夹。
- 媒体库主界面截图保存在 `build/qa/library-filter-home.png` 和
  `build/qa/library-filter-browse.png`。
- 真机筛选面板提交“未播放 + 视频”后，总数从 448 变为 442，筛选徽标显示 2；
  重置后恢复 448。1080×2400 下未出现控件重叠、RenderFlex 溢出或旧结果混入，
  截图保存在 `build/qa/library-filter-combination.png`。
- 用户已确认真实媒体正常播放、断点续播、横滑定位、暂停、进度条、字幕和音轨。
- `.strm` 媒体会优先选中 `DirectPlay`，但不再把 Emby `PlaybackInfo` 的外部
  `Path` 直接交给播放器，而是请求同源
  `/Videos/<id>/stream?MediaSourceId=<sourceId>&Static=true`，由 Emby 后端解析
  或代理 `.strm` 上游；该请求携带正常的 Emby 鉴权头。
- 更新后的真机日志已确认 item `161992` 实际命中上述 `/Videos/161992/stream`
  接口，不再访问外部 `Path`。当前服务端响应仍不可播放：mpv 尝试定位到约
  3.34 GB 处读取 MP4 尾部元数据时返回 `Seek failed`，随后出现
  `moov atom not found` 和读取超时。服务端代理必须透传请求 `Range`，并返回
  正确的 `206`、`Content-Range`、`Content-Length`、`Accept-Ranges: bytes`
  和 `Content-Type`，不能只返回 URL 文本、截断内容或不可定位的单向流。
- 本轮真实 `.strm` 上游为 `alist.jsdfhasuh.top`。手机、Windows、1.1.1.1 和
  8.8.8.8 均确认该主机名不存在，因此直连失败属于上游 DNS 问题。
- 直连失败后客户端确实请求了 Emby HLS 转码；当前服务端或反向代理返回的 HLS
  响应触发 `inflate return value: -3, incorrect header check`，需检查
  `Content-Encoding` 和重复压缩。
- 播放器现会把 DNS、HTTP 打开失败和错误压缩头识别为启动失败：直连立即回退，
  转码也失败时立即显示错误并停止 mpv，不再保持无限加载或继续输出高频日志。
- 自动化测试覆盖“DNS 失败立即回退”和“转码解压失败立即报错并停止播放器”；
  更新后的失败提示仍需一次人工实体机确认。
- 阶段 8.1 最终三 ABI APK 已重新构建；合并 Manifest 包含 `dataSync` 前台服务、
  SQLite WAL 开关，不包含 `RECEIVE_BOOT_COMPLETED` 或重启 Receiver。
- 前台任务配置确认
  `autoRunOnBoot=false`、`autoRunOnMyPackageReplaced=false` 和
  `allowAutoRestart=false`；设备重启后由用户再次打开应用恢复持久化任务。
- 真机数据库已实际生成 `emby_client.db-wal` 和 `emby_client.db-shm`。
- `waitingForStorage` 版本已重新生成三个 ABI APK，并覆盖安装到同一 Android 14
  实体机；登录和约 3.4 GB 既有离线文件保留。冷启动后进程与 Activity 正常，
  无活动任务时 `dataSync` 服务没有误启动，日志未发现 Flutter、AndroidRuntime、
  插件或 SQLite 异常。
- 存储分区和可恢复删除版本已再次覆盖安装；旧完成文件仍保留在原目录，总量约
  3.4 GB，启动没有创建 `media/` 或 `parts/` 迁移目录，也没有出现大文件复制。
- item `100970` 从已暂停的 3.4 MB 任务继续到 40.0 MB 完成，前台服务和私密
  通知随后自动退出；不重启应用直接离线播放成功，日志记录
  `Playback ready item=100970 method=DirectPlay`。
- 上述本地播放没有请求 PlaybackInfo、没有在线播放会话上报，也没有再次出现
  `database_closed`、`SQLITE_BUSY` 或数据库锁等待。
- 3.43 GB 完成项在飞行模式下可进入离线目录，本地海报正常显示；离线播放进入
  `Playback ready`，本地解码器持续输出音视频，定位后退出写入约 69 秒的
  `pending` 进度。该样本字幕页只有“关闭字幕”，因此外挂字幕仍需另一个真实样本。
- 审查发现恢复网络后 WebSocket 虽会重连，但旧实现不会触发离线进度同步；现已
  将连接成功事件接入同步，并为恢复联网增加一次可绕过旧重试时间的强制查询。
- 新 arm64 包已在真机制造 `failed` 且重试时间仍在未来的记录；不切后台、不重启
  应用恢复 Wi-Fi 后，WebSocket 在长退避结束时重连，约 0.4 秒后日志记录
  `Synced 1 offline progress record(s)`，数据库状态变为 `synced` 且重试时间清空。
- 3.43 GB 的真实媒体在下载至 1.35 GB 时主动暂停；4 秒内页面变为“继续下载”，
  `dumpsys` 确认 `dataSync` 前台服务退出，通知移除。
- 取消该大文件任务后 1.35 GB `.part` 被删除，下载列表为空，应用私有下载目录
  只保留空的 Scope 目录。
- 真机测试过程中通知标题始终为通用“Emby 离线下载”，可见性为
  `VISIBILITY_PRIVATE`，未展示媒体标题、服务器地址或 Token。
- 实际展开系统通知并点击“暂停”后，`.part` 停在 `1,852,681,320` 字节，3 秒内
  不再增长；前台服务和通知退出，详情页变为“继续下载”。
- 从全新任务实际点击通知“取消”时通知仍处于活动状态；5 秒内任务、`.part`、
  附属文件、前台服务和通知全部清理，详情页恢复为“下载”。
- 下载中执行 `am force-stop` 后服务和通知立即退出；重新打开应用后自动从断点
  恢复，`.part` 在 3 秒内从 `2,124,221,720` 增长到 `2,278,158,600` 字节。
- 下载中返回桌面后，当前焦点确认为 MIUI Launcher，应用 PID 保持不变；
  `.part` 在 3 秒内增长 `176,372,192` 字节，前台服务和通知持续活动。
- 设备进入 `mWakefulness=Dozing` 后，`.part` 在 3 秒内增长
  `277,375,536` 字节，前台服务和私密通知持续活动。
- 隐私审计最初发现诊断日志保留 185 个网络 URL；统一日志脱敏器现会替换
  HTTP(S)、WebSocket 和编码 URL，并在启动时清洗历史日志。更新版覆盖安装后，
  原始/编码 URL 和未脱敏鉴权值均为 0，历史 URL 转为 185 个
  `<redacted-url>`；SQLite 完整性为 `ok`，其中 URL、鉴权字段、下载任务、
  离线项目和待同步进度均为 0。
- 日志隐私回归继续覆盖旧版 `Authenticated user <name>` 和播放决策中的媒体源
  `name=<title>`；新日志不再写入用户名或媒体标题，启动清洗会处理既有记录。
- 快速退出播放器后晚到的 PlaybackInfo 失败会先校验当前会话所有权，不再调用
  已释放的 Player；对应异步竞态已加入自动化回归。
- 本轮最终 arm64 APK（SHA-256
  `F703FBADC360083676D13B0D2EA36177AD9EAE3C4BE85CDC57CA17316DFE828D`）已再次
  覆盖安装并冷启动。安装前后的数据库逻辑内容一致：schema v4、完整性 `ok`、
  1 条 `completed` 任务、1 个离线项目、1 条 `synced` 进度，下载和预期字节均为
  `3,679,942,140`；快照保存在 `build/qa/device-db-progress-cas-after/`。
- 最终冷启动进程中的 AndroidRuntime、`E/flutter`、SQLite 和
  `Failed to stop player after startup failure` 均为 0；持久化诊断日志中的未脱敏
  用户名、媒体标题、原始/编码 URL 和鉴权值均为 0。既有媒体
  `3,679,942,140` 字节、海报 `108,188` 字节及二者时间戳 `1785484898` 均未变化。
- worker 命令串行化版本覆盖安装后，无活动任务时 `dataSync` 服务数为 0，启动
  日志中的下载命令、AndroidRuntime、Flutter 和 SQLite 错误均为 0。
- 原子进度提交版本覆盖安装后，schema 保持 v4 且数据库逻辑内容不变；启动日志中
  SQLite 参数、离线同步、AndroidRuntime 和 Flutter 错误均为 0。

以下证据仍缺失：

- Trickplay 和自动下一集的真实媒体验收。
- 画中画进入、控制和退出。
- 真实 Emby 服务器上的收藏、观看状态和页面实时刷新。
- `ForceKeepAlive` 和远程 `Playstate` 控制。
- 真实局域网 UDP 7359 服务器发现。
- 退出、切集和重协商后服务端不存在残留转码任务。
- Wi-Fi/移动网络切换、空间不足和设备重启后的下载恢复。
- 真实 Emby 上服务端已观看或更远位置的离线进度冲突合并。
- 飞行模式外挂字幕；当前完成项没有外挂字幕轨道。
