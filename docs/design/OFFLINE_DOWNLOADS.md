# 离线下载设计计划

更新日期：2026-07-31

状态：阶段 8.1 实施中；首版功能、Android 构建、恢复策略、文件边界、网络和存储
等待状态机及核心真实服务器/物理设备流程已通过本地门槛，当前继续网络、存储、
重启、飞行模式和进度冲突的真机验收。

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
- 登出默认保留下载但锁定访问；设置页“删除此账户数据”经过二次确认后，等待
  Android worker 完全停止，再清理当前 Scope 的媒体、断点、数据库记录和偏好。
- Scope 目录名必须和 `ServerScope.databaseKey` 一致；不符合时拒绝递归删除。
- 卸载后的数据遵循 Android 应用私有目录行为。

## 8. 对播放的影响

- 新增 `OfflinePlaybackResolver`，在线 resolver 和离线 resolver 实现同一输入契约。
- 本地播放不执行 PlaybackInfo、PlaybackStart 或转码清理。
- 离线播放进度写入 `offline_progress`，联网后由同步器提交。
- 外挂字幕需要一同下载并改写为本地路径；缺失字幕不阻止视频播放。
- 启动恢复和离线播放前按完成任务记录检查成品存在性与长度；文件丢失、为空、
  截断或不可读时撤销离线可播放记录并给出“重新下载”入口，不自动回退在线流。
  用户明确点击后才删除坏成品、清空断点、ETag 和摘要，并从安全目录的 0 字节
  重新排队。运行期不为大文件重复计算摘要。

## 9. 测试与验收

自动测试：

- Range 续传、服务器忽略 Range、ETag 变化和长度不符。
- 暂停、取消、应用重启、任务重复投递和幂等完成。
- 401/403、429、5xx、磁盘不足和文件写入失败。
- 数据库迁移、Scope 隔离、孤立文件清理和账户级完整清理。
- 离线目录查询、本地字幕解析和播放进度待同步。
- 完成文件在启动时或播放前损坏、明确重新下载和禁止在线回退。
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

- SQLite schema v4 包含 `download_tasks`、`offline_items` 和
  `offline_progress`，并测试 v1 到 v4 迁移；v4 只为下载任务增加标准摘要算法和值，
  不移动或重写既有媒体文件。
- 原始下载最多两个并发任务，使用 `.part` 文件和原子改名。
- 支持暂停、继续、取消、删除、HTTP Range/If-Range、ETag 和长度校验；Range
  请求固定使用 `Accept-Encoding: identity`，避免压缩破坏断点字节位置。
- 解析标准 `Repr-Digest`、`Digest`、完整响应的 `Content-Digest` 和
  `Content-MD5`，优先 SHA-256、其次 MD5，不把 ETag 猜成摘要。摘要按任务持久化，
  跨进程续传后仍校验完整文件；摘要变化时关闭旧响应并从零开始。
- 摘要不匹配时删除损坏载荷，清空断点、ETag 和摘要并进入明确失败状态，不继续
  尝试兼容下载端点或重复校验同一坏文件。放弃 Range 响应时会主动取消响应流，
  避免大文件连接继续占用网络。
- 协议异常矩阵覆盖 401/403 不重试、429/5xx 最多三次尝试及 1/2 秒退避、ETag
  变化从零开始、长度不符保留断点、完整 `.part` 的 416 收尾、非媒体响应释放、
  重复投递幂等和非空间文件系统失败。
- 完成任务在启动恢复和离线播放前执行轻量文件健康检查；丢失、为空、长度不符或
  不可读时移除 `offline_items` 可播放记录并进入 `missingFile` 或
  `localMediaCorrupt`。坏成品保留到用户点击“重新下载”，随后清空旧断点、ETag、
  摘要和不安全旧路径，并从 0 字节重新下载，不自动转为在线播放。
- 401/403 立即停止；429/5xx 只做有上限重试；服务器忽略 Range 时从头开始。
- 无 Android executor 时把中断任务恢复为暂停；Android 用户重新打开应用后，
  将中断任务重新排队并从 `.part` 断点继续，同时使缺失的完成文件失效。
- 下载 URL 和 SQLite 不保存 Token，认证只放在请求头。
- 诊断日志统一把 HTTP(S)、WebSocket 和编码 URL 替换为
  `<redacted-url>`，并在启动时清洗历史日志中的完整 URL。
- Android 网络传输由 `dataSync` 前台服务 isolate 执行，通知内容不包含服务器
  地址或媒体标题。
- 默认仅 Wi-Fi 下载，可显式允许移动网络；下载前检查剩余空间并保留安全余量。
- worker 持续监听连接类型；Wi-Fi 消失或完全断网时进入持久化
  `waitingForNetwork` 状态、关闭当前传输并保留 `.part`，条件恢复后自动使用
  Range/If-Range 续传。等待期间仍可手动暂停或取消。
- 传输中 ENOSPC 会进入持久化 `waitingForStorage` 状态并保留 `.part`；worker
  每 15 秒复检剩余空间，释放足够空间后自动使用 Range/If-Range 续传。权限错误等
  非空间 I/O 故障仍进入普通失败状态，避免无意义无限重试。
- 等待网络或存储的异常收尾在提交状态前会重新检查暂停/取消命令，防止旧异步结果
  覆盖更晚的用户操作。
- 主 isolate 修改“仅 Wi-Fi”后通过前台服务命令通知 worker 重新读取持久化设置，
  避免两个 isolate 使用不同策略。
- 新任务使用 `media/` 保存完成媒体、`parts/` 保存主媒体断点、`assets/` 保存最终
  图片和字幕，附属资源临时文件只写入 `parts/assets/`。旧任务路径保持兼容，启动
  不搬移既有大文件。
- 恢复时若 `.part` 已不存在但数据库仍记录非零断点或 ETag，会将二者重置后再允许
  继续；数据库有记录但完成文件丢失时仍使离线项目失效，无记录文件按 7 天保留期
  清理。
- 下载同源海报和外挂字幕，拒绝跨域字幕，并将离线字幕地址改写为本地路径。
- 无主文件保留 7 天后清理，图片或字幕失败不回滚已完成的视频。
- 本地播放复用现有播放器状态机和手势，不请求 PlaybackInfo、不创建在线播放会话、
  不保持 WebSocket，也不尝试转码回退。
- 离线进度先写入 `offline_progress` 的 pending 记录。
- 同步时服务端已观看状态优先；双方都未完成时取更远位置；同步失败设置 5 分钟
  `retry_after`。`pending`、`syncing` 和最终状态使用 SQLite 原子 compare-and-set，
  提交瞬间出现的新本地进度会让旧结果更新失败，不会被覆盖。
- 下载管理页支持查看状态、离线播放、暂停、继续和删除确认。
- 下载管理页显示当前 Scope 的媒体文件和断点总占用，并分别统计已完成和未完成项。
- SQLite 使用 WAL，worker isolate 使用独立数据库句柄；worker 运行期间由其独占
  下载任务写入，主 isolate 串行合并状态刷新。
- 暂停或取消时先等待传输操作收尾，再停止前台服务；所有删除先持久化
  `cancelling`，文件和数据库清理中断后可在下次启动继续。worker 运行时主 isolate
  对已完成项目也只发送命令，不竞争写数据库。
- worker 命令通过串行队列执行，异常不会阻塞后续命令；销毁会等待活动命令收尾，
  防止删除与刷新交错恢复陈旧任务或数据库关闭后仍有命令写入。
- 附属资源在读取响应体前或读取期间失败时会取消请求并删除临时片段；图片或字幕
  失败仍不回滚已完成媒体。

本地门槛：

```text
dart format lib test                   通过
flutter analyze                        No issues found
flutter test                           165 tests passed
flutter build apk --debug --split-per-abi
```

最终源码已生成 armeabi-v7a、arm64-v8a 和 x86_64 三个 APK。合并 Manifest
包含 `dataSync` 服务和 WAL 开关，不包含开机广播权限或 Receiver。用户指定使用
实体机验收，因此最终 arm64 APK 已覆盖安装到 Xiaomi 22021211RC（Android 14）
并完成冷启动、真实下载和本地播放；x86_64 APK 本轮未重复安装模拟器。

真机已验证：

- item `100970` 从 3.4 MB 暂停点继续到 40.0 MB 完成，服务与通知自动退出。
- 不重启应用直接离线播放成功，随后删除媒体、任务和临时文件。
- 3.43 GB 媒体下载至 1.35 GB 后主动暂停，4 秒内前台服务退出且 UI 显示继续；
  取消后 `.part` 被删除。
- 数据库实际运行在 WAL 模式；全程没有 `database_closed`、`SQLITE_BUSY`
  或数据库锁等待。
- 通知为私密通用内容，不包含媒体标题、服务器地址或 Token。
- 实际点击通知“暂停”后，`.part` 在 3 秒内保持 `1,852,681,320` 字节，
  服务和通知退出，UI 显示继续下载。
- 实际点击通知“取消”后，任务、`.part`、附属文件、服务和通知均被清理，
  UI 恢复为下载。
- 下载中强制终止应用后服务和通知退出；重新打开应用会从持久化断点自动恢复，
  实测 `.part` 在 3 秒内从 `2,124,221,720` 增长到 `2,278,158,600` 字节。
- 返回桌面后应用 PID 保持不变，`.part` 在 3 秒内增长 `176,372,192` 字节，
  前台服务和通知持续活动。
- 设备进入 `mWakefulness=Dozing` 后，`.part` 在 3 秒内增长
  `277,375,536` 字节，前台服务和通知持续活动。
- 新版覆盖安装并冷启动后，日志中的原始/编码网络 URL 和未脱敏鉴权值均为 0；
  SQLite 完整性为 `ok`，URL、鉴权字段及下载残留均为 0。
- 下载占用汇总版本覆盖安装后，真实下载页显示 3.43 GB 和 1 个可离线播放项目，
  与 Scope 私有目录实际占用一致；无 RenderFlex、Flutter、SQLite 或原生异常。
- schema v4 arm64 包覆盖安装前，真机数据库为 v3，包含 1 条已完成任务和
  `3,679,942,140` 下载字节；覆盖安装并冷启动后数据库为 v4，完整性检查为 `ok`，
  任务数量、状态和字节数完全不变，既有媒体和海报的大小、时间戳也未变化。
- schema v4 真机冷启动没有误启动 `dataSync` 服务，日志无 AndroidRuntime、
  Flutter 或 SQLite 异常；诊断日志中的原始和编码 URL 均为 0。下载页 1080×2400
  截图保存在 `build/qa/download-integrity-migration.png`。
- 最终 165 项回归源码构建的 arm64 APK 已再次覆盖安装。冷启动后 schema v4
  完整性为 `ok`，完成任务、离线项目和同步进度均各 1 条，下载和预期字节均为
  `3,679,942,140`；与安装前快照一致，数据库证据保存在
  `build/qa/device-db-progress-cas-after/`。
- 最终进程未出现 AndroidRuntime、Flutter、SQLite 或晚到播放器停止错误；历史
  用户名和媒体标题清洗后，持久化日志中的未脱敏用户名、媒体标题、网络 URL 和
  鉴权值均为 0。3.43 GB 媒体及海报的大小和时间戳未变化。
- worker 命令串行化版本冷启动后，无活动任务时 `dataSync` 服务没有误启动，
  下载命令、AndroidRuntime、Flutter 和 SQLite 错误均为 0。
- 原子进度提交版本覆盖安装后 schema 和既有记录不变，启动日志中的 SQLite 参数、
  离线同步、AndroidRuntime 和 Flutter 错误均为 0；最终 APK SHA-256 为
  `F703FBADC360083676D13B0D2EA36177AD9EAE3C4BE85CDC57CA17316DFE828D`。

## 12. 下一轮改动计划

按以下顺序执行，前一批未过门槛时不进入后一批：

### 批次 A：构建与 Android 冒烟（完成）

- [x] 执行 `flutter build apk --debug --split-per-abi`。
- [x] 确认 Android Manifest 合并后的 `dataSync` 服务和权限正确。
- [x] 确认 `startDownloadForegroundService` 在 AOT 构建中可达，原生插件注册
  没有缺失。
- [x] 确认三个 ABI APK 均生成；按用户要求将 arm64 APK 安装到物理设备。
- [x] 冷启动后检查 `AndroidRuntime`、`E/flutter`、SQLite 和前台服务异常。

完成定义：三 ABI 构建成功，物理设备冷启动和实际 worker 回调无崩溃、
Manifest 或插件错误。

### 批次 B：Android 15 及以上恢复策略（完成）

- [x] 关闭 `autoRunOnBoot`、包更新自动运行和自动重启行为。
- [x] 首版不引入 WorkManager，明确采用“用户重新打开应用后恢复”。
- [x] 为进程终止、包更新和设备重启后的任务状态转换增加测试。
- [x] 不把 `BOOT_COMPLETED` 直接启动 `dataSync` 前台服务作为 API 35+ 方案。

完成定义：实现与文档一致，且不会在受限系统版本触发非法前台服务启动。

### 批次 C：文件边界、网络/存储状态机与回归（完成）

- [x] 统一 `_removeTaskAndFiles` 中临时路径、最终路径和附属资源路径的绝对化、
  规范化方式。
- [x] 增加数据库遗留相对路径、目录逃逸路径和合法任务文件删除测试。
- [x] 增加 `waitingForNetwork` 持久化状态、连接变化监听和自动 Range 续传。
- [x] 验证传输中 Wi-Fi 消失、网络恢复、手动暂停、设置同步和服务重建。
- [x] 增加 `waitingForStorage` 持久化状态、ENOSPC 识别、空间复检和自动 Range 续传。
- [x] 验证网络异常收尾不会覆盖稍后发出的暂停或取消。
- [x] 新任务按 `media/`、`parts/`、`assets/` 分区，且保留旧绝对/相对路径兼容。
- [x] 修复 `.part` 丢失后的陈旧字节数和 ETag，并验证不会发出错误 Range。
- [x] 删除前持久化 `cancelling`，验证已完成文件删除中断后可继续收尾。
- [x] 增加 Scope 级账户数据清理、错误目录拒绝和设置页二次确认测试。
- [x] 增加标准摘要解析、持久化、Range 变化和最终文件流式校验。
- [x] 摘要失败时清理坏载荷，放弃响应时关闭旧流，并验证不会回退其他端点。
- [x] 升级 schema v4，并验证 v3 大文件任务记录无损迁移。
- [x] 增加启动恢复、损坏状态重启保持、播放前检查、本地成品损坏和明确重新下载测试。
- [x] 重新执行格式化、静态检查和 165 项测试。
- [x] 重新执行分 ABI APK 构建。

完成定义：只能删除任务目录内或明确登记的任务文件，不漏删合法相对路径文件，
也不能删除目录外文件。

### 批次 D：真实 Emby 与物理设备验收

- [x] 验证原始下载、暂停点续传、主动暂停、取消、删除和重新下载。
- [x] 验证完成后不重启应用直接离线播放，并在删除后确认无媒体或 `.part` 残留。
- [x] 验证前台服务在完成和暂停收尾后退出，通知内容保持私密。
- [x] 验证强制终止应用后服务与通知退出，重新打开应用自动从断点恢复。
- [x] 验证通知暂停/取消按钮和隐私内容。
- [x] 验证锁屏和切后台期间下载、服务与通知持续运行。
- [ ] 验证 Wi-Fi/移动网络切换、空间不足和设备重启。
- [x] 飞行模式验证离线目录、播放、定位和海报。
- [ ] 使用包含外挂字幕的真实下载完成飞行模式字幕验收。
- [x] 联网后验证失败记录绕过旧退避并自动同步。
- [ ] 验证服务端已观看优先和较远位置优先的真实冲突合并。
- [x] 检查日志、SQLite 和通知中不存在 Token 或敏感 URL。
- [x] 覆盖安装后验证账户清理入口和二次确认弹窗；未执行最终删除，原有 3.4 GB
  离线媒体保持不变。

完成定义：保存 Android 版本、设备型号、Emby 版本、用例结果和失败日志；全部通过
前，阶段 8.1 仍保持“实施中”。

### 批次 E：后续能力

- [ ] 真实服务器和物理设备验收通过后，再独立设计转码下载。
- [ ] 转码下载不复用原始文件 Range 承诺，必须有明确的服务器能力证据和转码清理。

## 13. GPL 边界

借鉴 Moonfin 将下载服务、数据库、离线目录和播放 resolver 分开的架构思想。
不复制其数据库 schema、下载实现、通知代码或测试夹具。
