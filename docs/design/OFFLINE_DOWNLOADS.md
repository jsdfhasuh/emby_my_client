# 离线下载设计计划

更新日期：2026-07-30

状态：阶段 8.1 实施中；首版功能已完成代码和本地测试，当前进入 Android 平台
构建、恢复策略和真实服务器/物理设备验收阶段。

## 1. 用户场景

- 用户把电影或剧集下载到 Android 设备，断网后仍能浏览和播放。
- 原始文件下载中断后可继续，应用重启后任务状态不丢失。
- 用户查看下载进度、失败原因、占用空间并删除内容。
- 在线恢复后，将离线播放位置和完成状态同步到原 Emby 用户。
- 自动下载连续剧下一集作为后续增量，不进入首个版本。

## 2. 首版范围和非目标

首版：

- 原始媒体版本下载。
- 后台任务、暂停、继续、取消和删除。
- 离线目录、海报、最小元数据和本地播放。
- 离线进度待同步队列。
- 存储空间检查和孤立文件清理。

非目标：

- DRM 内容破解或绕过服务器权限。
- 跨设备共享下载文件。
- 首版不做自动追剧、下载配额策略和 SD 卡任意目录选择。
- 服务器未明确提供可下载转码流时，不自行拼接私有转码接口。
- 转码下载即使后续加入，也默认不承诺 Range 续传。

## 3. 拟新增模块

```text
lib/downloads/download_models.dart
lib/downloads/download_repository.dart
lib/downloads/download_service.dart
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
```

当前已经落地：

- [x] `download_models.dart`、`download_repository.dart` 和
  `download_service.dart`。
- [x] `offline_playback_resolver.dart` 和 `offline_playback_reporter.dart`。
- [x] `downloads_screen.dart`，以及电影、剧集详情中的下载操作。
- [x] Android `dataSync` 前台服务、私密下载通知和网络策略。
- [x] 图片、外挂字幕、空间预检、孤立文件保留期清理和离线进度同步器。

状态所有权：

- `DownloadRepository` 是任务、文件和离线元数据的权威数据源。
- `DownloadService` 接受开始、暂停、继续、取消和删除命令。
- `ForegroundDownloadExecutor` 负责 Android 前台服务生命周期和主/后台 isolate
  命令桥接，不持有页面引用。
- `DownloadService` 从 SQLite 恢复持久化任务，页面不是任务状态所有者。
- `OfflineProgressSync` 串行提交未同步进度并处理冲突。
- `PlaybackController` 只接收解析后的本地媒体，不管理下载任务。

## 4. 数据模型

建议表：

```text
download_tasks
  id, server_id, user_id, item_id, media_source_id
  source_kind, source_url_fingerprint, etag, expected_bytes
  downloaded_bytes, status, retry_count, last_error_code
  temp_path, final_path, created_at, updated_at

offline_items
  server_id, user_id, item_id, media_source_id
  item_type, name, parent_ids, runtime_ticks
  metadata_json, image_paths_json, local_media_path, completed_at

offline_progress
  server_id, user_id, item_id
  position_ticks, played, updated_at, sync_status, retry_after
```

要求：

- 主键包含 `ServerScope`，不同服务器相同 Item ID 不冲突。
- URL、Token 和认证头不得落库；只保存不可逆指纹用于识别源变化。
- 状态转换通过事务完成，文件改名和数据库提交需要可恢复。
- 下载状态至少包括 queued、running、paused、completed、failed、cancelling。

## 5. API 和下载协议

- 先通过 PlaybackInfo/媒体源数据选择明确的原始媒体版本。
- 只使用服务器实际返回或 Emby 文档确认的下载地址。
- 原始文件使用临时 `.part` 文件，服务端支持 Range 且 ETag/长度未变化时续传。
- 服务端忽略 Range、ETag 变化或长度不一致时丢弃临时片段并重新开始。
- HTTP 401/403 标记需要重新认证，不做指数重试。
- 429 和临时 5xx 使用有上限退避；校验失败不无限重试。
- 完成前校验实际字节数；若服务器提供校验信息则同时验证。
- 下载成功后再抓取必要图片和最小元数据，图片失败不破坏媒体文件。

转码下载作为第二阶段：

- 只有 Emby 明确返回稳定、可结束的转码下载流时开放。
- 记录原始请求条件和最终容器，不把未完成流标记为成功。
- 默认从头重试，不假设 HLS 分片或动态转码可续传。
- 完成或取消后调用现有转码清理逻辑。

## 6. Android 平台工作

- 默认写入应用私有目录，不申请宽泛存储权限。
- 使用 Android 后台任务机制承接长任务，避免仅依赖 Dart isolate 生命周期。
- Android 13 及以上只有显示下载通知时才请求通知权限。
- 前台下载通知显示进度、暂停和取消，并隐藏服务器地址和媒体隐私信息。
- 处理省电、进程终止、网络切换和设备重启后的任务恢复。
- 首版默认仅 Wi-Fi 下载，提供显式允许移动网络的设置。

当前实现使用 `flutter_foreground_task` 的 `dataSync` 前台服务。后台 isolate 从
安全存储重新读取会话，主 isolate 只传任务 ID，不传 Token。Android 15 及以上
禁止从 `BOOT_COMPLETED` 直接启动 `dataSync` 前台服务，因此现有
`autoRunOnBoot` 不能视为可靠的设备重启恢复方案；发布前必须完成第 12 节的
恢复策略决策。

引入插件前先验证其 Android 版本、前台服务类型和 Flutter 生命周期兼容性，
并把原生任务标识与数据库任务 ID 一一对应。

## 7. 存储和清理

- 下载前预留媒体预计大小加安全余量。
- 临时文件只位于明确的下载临时目录。
- 应用启动和任务恢复时扫描“数据库有任务但文件不存在”以及“文件存在但无记录”。
- 孤立临时文件经过保留期后清理，不能删除数据库未确认归属的文件。
- 删除离线项目采用先标记 deleting、再删除文件、最后删记录的可恢复流程。
- 登出默认保留下载但锁定访问；用户选择“删除此账户数据”时再清理。
- 卸载后的数据遵循 Android 应用私有目录行为。

## 8. 对播放的影响

- 新增 `OfflinePlaybackResolver`，在线 resolver 和离线 resolver 实现同一输入契约。
- 本地播放不执行 PlaybackInfo、PlaybackStart 或转码清理。
- 离线播放进度写入 `offline_progress`，联网后由同步器提交。
- 外挂字幕需要一同下载并改写为本地路径；缺失字幕不阻止视频播放。
- 本地媒体损坏时给出重新下载入口，不回退到在线流，除非用户明确选择。

## 9. 测试与验收

自动测试：

- Range 续传、服务器忽略 Range、ETag 变化和长度不符。
- 暂停、取消、应用重启、任务重复投递和幂等完成。
- 401/403、429、5xx、磁盘不足和文件写入失败。
- 数据库迁移、Scope 隔离和孤立文件清理。
- 离线目录查询、本地字幕解析和播放进度待同步。
- 同一进度重复同步不会重复修改服务端状态。

真机验收：

- 下载中锁屏、切后台、杀进程和重启设备。
- Wi-Fi/移动网络切换和完全断网。
- 至少一个大文件中断续传。
- 磁盘空间不足、取消、删除和重新下载。
- 飞行模式浏览、播放、定位和字幕。
- 联网后 Emby 端观看位置与本地一致。

## 10. 发布步骤

1. [x] 数据库、任务模型和应用私有文件目录。
2. [x] 原始文件前台下载。
3. [x] Android 前台服务、通知、Wi-Fi/移动网络策略和空间预检。
4. [x] 最小离线目录与本地播放。
5. [x] 图片、外挂字幕、孤立文件清理和离线进度冲突同步。
6. [ ] 物理设备和真实 Emby 验证后再评估转码下载。

功能默认通过内部开关灰度，数据库完成向前迁移后才对现有用户开放。

## 11. 当前实现与验证记录

已实现：

- SQLite schema v3 包含 `download_tasks`、`offline_items` 和
  `offline_progress`，并测试 v1 到 v3 迁移。
- 原始下载最多两个并发任务，使用 `.part` 文件和原子改名。
- 支持暂停、继续、取消、删除、HTTP Range/If-Range、ETag 和长度校验。
- 401/403 立即停止；429/5xx 只做有上限重试；服务器忽略 Range 时从头开始。
- 应用重启后把运行中任务恢复为暂停，并使缺失的完成文件失效。
- 下载 URL 和 SQLite 不保存 Token，认证只放在请求头。
- Android 网络传输由 `dataSync` 前台服务 isolate 执行，通知内容不包含服务器
  地址或媒体标题。
- 默认仅 Wi-Fi 下载，可显式允许移动网络；下载前检查剩余空间并保留安全余量。
- 下载同源海报和外挂字幕，拒绝跨域字幕，并将离线字幕地址改写为本地路径。
- 无主文件保留 7 天后清理，图片或字幕失败不回滚已完成的视频。
- 本地播放复用现有播放器状态机和手势，不请求 PlaybackInfo、不创建在线播放会话、
  不保持 WebSocket，也不尝试转码回退。
- 离线进度先写入 `offline_progress` 的 pending 记录。
- 同步时服务端已观看状态优先；双方都未完成时取更远位置；同步失败设置 5 分钟
  `retry_after`，旧同步结果不会覆盖同步期间新增的本地进度。
- 下载管理页支持查看状态、离线播放、暂停、继续和删除确认。

本地门槛：

```text
dart format lib test                   通过
flutter analyze                        No issues found
flutter test                           78 tests passed
```

较早版本的 x86_64 APK 已在模拟器冷启动，未发现 Flutter、AndroidRuntime 或
SQLite 异常。加入前台服务和最新离线能力后尚未重新完成分 ABI 构建，因此旧 APK
不作为本轮平台验收证据。模拟器没有真实 Emby 会话，也尚未完成真实媒体下载、
断网播放、后台恢复、通知和进度回传验收。

## 12. 下一轮改动计划

按以下顺序执行，前一批未过门槛时不进入后一批：

### 批次 A：构建与模拟器冒烟

- [ ] 执行 `flutter build apk --debug --split-per-abi`。
- [ ] 确认 Android Manifest 合并后的 `dataSync` 服务和权限正确。
- [ ] 确认 `startDownloadForegroundService` 在 AOT 构建中可达，原生插件注册
  没有缺失。
- [ ] 确认三个 ABI APK 均生成，并安装 x86_64 APK 到 `emulator-5554`。
- [ ] 冷启动后检查 `AndroidRuntime`、`E/flutter`、SQLite 和前台服务异常。

完成定义：三 ABI 构建成功，模拟器冷启动无崩溃和 Manifest/插件错误。

### 批次 B：Android 15 及以上恢复策略

- [ ] 关闭当前未经证明的 `autoRunOnBoot` 行为。
- [ ] 评估 WorkManager 作为重启后的受约束恢复触发器；若本阶段不引入
  WorkManager，则明确采用“用户重新打开应用后恢复”并更新 UI 文案。
- [ ] 为选定策略增加进程终止、包更新和设备重启状态转换测试。
- [ ] 不把 `BOOT_COMPLETED` 直接启动 `dataSync` 前台服务作为 API 35+ 方案。

完成定义：实现与文档一致，且不会在受限系统版本触发非法前台服务启动。

### 批次 C：文件边界与回归

- [ ] 统一 `_removeTaskAndFiles` 中临时路径、最终路径和附属资源路径的绝对化、
  规范化方式。
- [ ] 增加数据库遗留相对路径、目录逃逸路径和合法任务文件删除测试。
- [ ] 重新执行格式化、静态检查、78 项及新增测试和分 ABI 构建。

完成定义：只能删除任务目录内或明确登记的任务文件，不漏删合法相对路径文件，
也不能删除目录外文件。

### 批次 D：真实 Emby 与物理设备验收

- [ ] 验证原始大文件下载、Range/If-Range 续传、取消、删除和重新下载。
- [ ] 验证 Wi-Fi/移动网络切换、空间不足、锁屏、切后台、杀进程和设备重启。
- [ ] 验证通知暂停/取消按钮和隐私内容。
- [ ] 飞行模式验证离线目录、播放、横滑定位、海报和外挂字幕。
- [ ] 联网后验证服务端已观看优先、较远位置优先和失败重试。
- [ ] 检查日志、SQLite 和通知中不存在 Token 或敏感 URL。

完成定义：保存 Android 版本、设备型号、Emby 版本、用例结果和失败日志；全部通过
前，阶段 8.1 仍保持“实施中”。

### 批次 E：后续能力

- [ ] 真实服务器和物理设备验收通过后，再独立设计转码下载。
- [ ] 转码下载不复用原始文件 Range 承诺，必须有明确的服务器能力证据和转码清理。

## 13. GPL 边界

借鉴 Moonfin 将下载服务、数据库、离线目录和播放 resolver 分开的架构思想。
不复制其数据库 schema、下载实现、通知代码或测试夹具。
