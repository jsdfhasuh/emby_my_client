# 阶段 8 设计索引

更新日期：2026-07-30

参考基线：Moonfin-Core `1b203f43efb3bd0e9d2589340c00b6c443d3ee8c`

## 1. 目标

阶段 8 包含六个大型扩展项目。每项独立设计、独立开关、独立测试和独立验收，
不得继续扩大现有 `EmbyApi`、`AppController` 或 `PlayerScreen` 的职责。

设计文档：

- [离线下载](OFFLINE_DOWNLOADS.md)
- [Live TV](LIVE_TV.md)
- [投屏](CASTING.md)
- [多服务器](MULTI_SERVER.md)
- [SyncPlay](SYNCPLAY.md)
- [Android TV](ANDROID_TV.md)

当前状态：

- [x] 阶段 8.0 共同基础代码与本地质量门槛完成。
- [ ] 阶段 8.1 离线下载实施中：首版代码已覆盖 Android 前台下载、策略、
  附属资源、清理、离线播放和进度同步，并通过 78 项本地测试；平台构建、
  Android 15 重启恢复策略和真实服务器/物理设备验收待完成。
- [ ] 阶段 8.2 Live TV 待实施。
- [ ] 阶段 8.3 Android TV 待实施。
- [ ] 阶段 8.4 投屏待实施。
- [ ] 阶段 8.5 多服务器待实施。
- [ ] 阶段 8.6 SyncPlay 保持协议阻塞。

## 2. 共同基础

状态：代码和本地质量门槛完成（2026-07-30）

已落地以下最小基础：

```text
lib/core/server_scope.dart
lib/core/server_capabilities.dart
lib/data/client_registry.dart
lib/data/local_database.dart
lib/data/server_capabilities_repository.dart
```

- [x] `ServerScope` 使用 `serverId + userId` 隔离设置、下载和缓存。
- [x] `ServerCapabilities` 只保存服务器明确返回或经过安全探测确认的能力。
- [x] `ClientRegistry` 为后续多服务器保留按 Scope 获取客户端的接口；当前仍只注册
  当前服务器。
- [x] `LocalDatabase` 使用 SQLite 统一 schema 版本、迁移和事务边界。
- [x] 已实现并测试 v1 到 v2 数据库迁移。
- [x] `AppController` 已改为通过 Scope 和注册表拥有当前客户端。
- [x] WebSocket 能力上报成功后持久化远程控制能力证据。
- [x] Token 继续只保存在安全存储，数据库不保存明文 Token。
- [x] 数据库不可用时保留在线模式，并写入脱敏诊断日志。

基础层不是一次性大重构。只在第一个使用者出现时增加对应接口，并为当前单服务器
行为保留兼容适配器。

阶段 8.1 已在共同数据库上升级到 schema v3，并增加下载任务、离线项目和
离线进度表；v1 到 v3 迁移已测试。当前阶段仍未达到本节第 5 条的统一完成定义。

## 3. 推荐顺序

| 顺序 | 项目 | 理由 | 前置条件 |
|---|---|---|---|
| 8.0 | 共同基础 | 统一身份、能力和持久化边界 | 阶段 0 至 7 |
| 8.1 | 离线下载 | 用户价值高，可独立交付 | 8.0 |
| 8.2 | Live TV | Emby API 路径已有明确证据，可复用播放核心 | 8.0 |
| 8.3 | Android TV | 重点是输入和焦点体系，可先覆盖现有浏览与播放 | 8.0 |
| 8.4 | 投屏 | 涉及原生 SDK、设备发现、Token 暴露和会话交接 | 8.0 |
| 8.5 | 多服务器 | 会改变全局会话所有权和所有缓存键，改动面最大 | 8.0，建议在离线模型稳定后 |
| 8.6 | SyncPlay | 尚未确认 Emby 对等协议，保持能力门控 | 经过真实 Emby 能力验证 |

不同时实施两个大型项目。每一项先完成最小纵向功能，再增加高级能力。

## 4. 依赖关系

```text
ServerScope + Capabilities + LocalDatabase
  ├─ Offline Downloads ──> Multi-server offline aggregation
  ├─ Live TV ────────────> Android TV guide navigation
  ├─ Android TV
  ├─ Casting
  └─ Multi-server

Verified Emby group-play capability
  └─ SyncPlay
```

关键约束：

- 多服务器不能要求重写已经稳定的播放协议层；播放始终绑定一个明确 Scope。
- 离线播放不能伪造在线播放会话，也不能在离线时发送失败重试风暴。
- Live TV 和投屏必须复用现有播放决策、会话上报和停止清理语义。
- Android TV 是输入、布局和清单变体，不复制一套业务数据层。
- SyncPlay 不得直接调用只在 Jellyfin 中确认存在的接口。

## 5. 每项统一完成定义

- 设计中的非目标没有被顺带实现。
- 新状态有单一所有者，页面仅订阅状态和发送用户意图。
- 所有数据库表、文件和偏好均按 `ServerScope` 隔离。
- 新增 Android 权限有对应用户场景，没有预防性申请权限。
- 网络、数据库、生命周期和恢复路径有自动化测试。
- `dart format lib test`、`flutter analyze`、`flutter test` 和分 ABI APK 构建通过。
- 真实 Emby 服务器和 Android 设备验收完成并记录。
- 功能可通过能力判断或开关隐藏，不影响阶段 0 至 7 的现有功能。

## 6. 许可边界

Moonfin-Core 使用 GPL v2。本阶段只借鉴公开 API 行为、模块职责、状态机思想和
失败恢复策略。代码、测试夹具、原生桥接和 UI 均在本项目中独立实现。

若未来直接使用 Moonfin 源文件或衍生实现，必须先单独决定本项目许可证和源码
分发义务，不能在普通功能提交中隐式引入。
