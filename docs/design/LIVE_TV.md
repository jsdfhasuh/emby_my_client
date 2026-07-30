# Live TV 设计计划

更新日期：2026-07-30

## 1. 用户场景

- 浏览频道及当前/下一节目。
- 使用按时间排列的节目单查看和播放直播。
- 查看录制内容、预约一次录制和系列录制。
- 播放直播时切换频道，并回到当前直播点。
- Android TV 上使用遥控器浏览节目单作为后续适配。

## 2. 首版范围和非目标

首版：

- 频道列表、当前节目和基础节目单。
- 直播频道播放。
- 录制列表和播放录制内容。
- 服务器支持时创建、查看和取消定时录制。

非目标：

- 不实现服务器端调谐器、节目源和管理员配置。
- 不承诺所有服务器都支持时移、追赶播放或多路并发。
- 不自行推断节目时间、频道号或录制冲突规则。
- 首版不实现复杂 EPG 网格虚拟化以外的电视首页重做。

## 3. 已确认的 Emby API 面

参考 Moonfin 的 Emby 适配层可确认以下 API 族，但实现时仍以真实服务器响应为准：

```text
GET      /LiveTv/Channels
GET/POST /LiveTv/Programs
GET      /LiveTv/Programs/Recommended
GET      /LiveTv/Recordings
GET      /LiveTv/Timers
GET      /LiveTv/SeriesTimers
GET      /LiveTv/Timers/Defaults
POST     /LiveTv/Timers
DELETE   /LiveTv/Timers/{id}
DELETE   /LiveTv/SeriesTimers/{id}
```

请求方法、查询参数和响应字段必须通过 Emby 版本测试锁定，不能因为 Jellyfin
路径相同就假设行为完全一致。

## 4. 拟新增模块

```text
lib/live_tv/live_tv_api.dart
lib/live_tv/live_tv_models.dart
lib/live_tv/live_tv_repository.dart
lib/live_tv/live_tv_guide_controller.dart
lib/live_tv/live_tv_playback_source.dart
lib/ui/live_tv/live_tv_screen.dart
lib/ui/live_tv/live_tv_guide_screen.dart
lib/ui/live_tv/live_tv_recordings_screen.dart
lib/ui/live_tv/live_tv_schedule_screen.dart
```

- `LiveTvApi` 只封装 Emby Live TV 传输。
- `LiveTvRepository` 合并频道、节目、录制和定时器，并按 `ServerScope` 缓存。
- `LiveTvGuideController` 管理时间窗口、筛选、分页和刷新。
- `LiveTvPlaybackSource` 把频道或录制转换为现有播放 resolver 能接受的请求。
- 页面不直接拼 API 参数，也不持有直播会话清理逻辑。

## 5. 数据和状态

类型化模型至少包括：

- `LiveChannel`：ID、名称、频道号、图片和当前节目。
- `LiveProgram`：ID、频道 ID、标题、开始/结束、是否直播、是否可录制。
- `LiveRecording`：ID、状态、路径无关的播放信息和用户数据。
- `LiveTimer`、`LiveSeriesTimer`：服务端 ID、录制选项和冲突状态。
- `GuideWindow`：UTC 起止时间、频道筛选和加载状态。

所有时间内部使用 UTC，显示时转为本地时区。节目单合并必须按服务端 ID 和时间窗口
去重，不能用标题作为主键。

## 6. 播放影响

- 频道播放仍通过类型化 PlaybackInfo 和现有 `PlaybackController`。
- 直播状态不依赖固定 duration，进度条需要支持无总时长和动态时移窗口。
- “回到直播”必须基于播放器或服务端返回的 live edge，不使用本地墙钟猜测。
- 换台先停止和清理旧 LiveStream，再打开新频道。
- 后台、画中画和远程控制沿用当前播放生命周期。
- 录制内容按普通媒体播放，但保留录制中内容长度可能增长的处理。
- Trickplay、章节和自动下一集默认不应用于直播。

## 7. Android 平台与权限

- 基础 Live TV 不需要新增 Android 危险权限。
- 画中画继续复用现有配置。
- Android TV 导航、焦点和横向节目单性能在 `ANDROID_TV.md` 中处理。
- 如果后续增加系统频道或 Watch Next 集成，再单独评估 TV Provider 权限和原生代码。

## 8. 缓存和恢复

- 节目单只做有时效的数据库或内存缓存，缓存键包含 Scope、时间窗口和频道集合。
- 当前节目采用短 TTL；历史和远期节目不无限保留。
- 录制定时器修改后重新读取服务端权威状态。
- 网络恢复后保留用户当前时间位置并刷新对应窗口。
- 时区改变、夏令时变化和服务器时间偏差必须触发重新计算显示坐标。
- 直播停止始终执行 LiveStream 和 ActiveEncoding 清理。

## 9. 测试与验收

自动测试：

- 频道、节目、录制和定时器 JSON 的缺失字段兼容。
- GET/POST 兼容策略、UTC 转换、分页、去重和缓存过期。
- 定时器创建、取消、401/403 和录制冲突错误。
- 无 duration、动态时移窗口、换台和清理顺序。
- 页面快速切换时间窗口时旧请求不能覆盖新结果。

真实服务器验收：

- 不同频道号、节目图片和跨午夜节目。
- 直播启动、换台、暂停/恢复和回到直播。
- 服务器不支持时移时 UI 不显示无效控制。
- 创建和取消一次录制、系列录制，验证服务端状态。
- 退出、断网和切台后没有残留转码或调谐会话。

## 10. 发布步骤

1. 频道列表和当前节目。
2. 单频道播放与清理。
3. 分页节目单。
4. 录制列表和录制播放。
5. 定时器和系列录制。
6. Android TV 节目单适配。

每一步使用服务器能力和响应内容决定是否显示入口。

## 11. GPL 边界

可借鉴 Moonfin 将 Live TV API、Guide ViewModel 和播放器入口分离的职责设计，
以及公开的 Emby API 路径。模型、解析、页面和测试需独立实现。
