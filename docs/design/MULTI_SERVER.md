# 多服务器设计计划

更新日期：2026-07-30

## 1. 用户场景

- 保存多个 Emby 服务器及其账户，并快速切换。
- 在一个首页中查看多个服务器的继续观看、最新媒体和搜索结果。
- 每个媒体项清楚显示来源服务器。
- 播放、下载、收藏和观看状态始终发送到正确服务器。
- 单个服务器离线或登录失效时，其他服务器仍可使用。

## 2. 首版范围和非目标

首版：

- 多服务器账户保存、添加、删除和切换。
- 每个服务器独立客户端、WebSocket、能力和设置。
- 聚合首页、搜索和媒体卡片来源标识。
- 单服务器故障隔离。

非目标：

- 不合并不同服务器上的“同一电影”为一个权威对象。
- 不跨服务器同步观看状态、收藏或用户。
- 不将一个服务器的 Token 发给另一个服务器。
- 首版不同时连接所有服务器的实时 WebSocket。
- 不在聚合列表中承诺全局严格分页顺序。

## 3. 核心模型

```text
ServerEndpoint
  normalizedUrl, discoveredAddresses, lastSuccessfulUrl

ServerAccount
  accountId, serverId, userId, displayName, endpoint, status

ServerScope
  serverId, userId

ScopedItemId
  scope, itemId

ServerConnectionState
  unknown, online, offline, authenticationRequired
```

- `accountId` 是本地稳定 ID，处理服务器 ID 暂时缺失或端点变化。
- 任何 Item、图片、下载、设置和缓存键都必须包含 Scope。
- 地址规范化和去重复用发现模块规则：优先服务器 ID，其次规范化端点。
- 同一服务器的不同用户是不同 Scope，不共享用户数据缓存。

## 4. 拟新增和修改

```text
lib/accounts/server_account_repository.dart
lib/accounts/server_account_store.dart
lib/data/client_registry.dart
lib/data/scoped_emby_client.dart
lib/data/multi_server_repository.dart
lib/state/server_workspace_controller.dart
lib/ui/accounts/server_accounts_screen.dart
lib/ui/widgets/server_badge.dart
```

逐步替换：

- `AppController` 不再拥有唯一 `EmbyApi`，改为协调账户仓库和当前 Workspace。
- `ClientRegistry` 按账户延迟创建 API、UserData、Session 和 Realtime 服务。
- `MultiServerRepository` 执行有并发上限的聚合查询并返回带 Scope 的结果。
- `PlaybackController` 每次启动接收不可变 Scoped Client，不从全局当前服务器查找。
- 页面路由参数携带 `ScopedItemId`，切换当前服务器不会改变已打开详情页的目标。

## 5. 会话和凭据

- 每个账户的 Token 独立存入安全存储，数据库只存安全存储引用。
- 从现有单会话存储迁移时创建一个 `ServerAccount`，迁移必须幂等。
- 删除账户默认清除 Token、客户端、WebSocket 和在线缓存。
- 已下载内容的删除策略必须向用户明确选择；保留时内容保持锁定到原 Scope。
- 401/403 只将对应账户标记为需要登录，不触发全局登出。
- 更换服务器地址前先验证服务器 ID；ID 不一致视为新服务器。

## 6. 聚合查询

- 继续观看、最新媒体和搜索按服务器并发请求，并设置全局并发上限。
- 每个结果保留服务端排序信息和 Scope，再执行稳定的本地合并。
- 单服务器超时返回部分结果和该服务器状态，不让整页失败。
- 分页游标按服务器分别保存，不能用一个 StartIndex 假装全局游标。
- 搜索首版采用“每服务器取固定窗口再合并”，UI 明确还可继续加载。
- 图片组件通过 Scoped Image Provider 选择正确 base URL 和认证头。

## 7. 实时、离线和播放影响

- 前台当前服务器保持 WebSocket；其他服务器先轮询或在页面刷新时查询。
- 后续若并行连接多个服务器，必须有连接上限和统一生命周期管理。
- 离线下载和进度同步始终按 Scope 路由。
- 播放开始后绑定的客户端不可因用户切换 Workspace 而变化。
- 播放停止、ActiveEncoding 清理和远程命令只发往绑定服务器。
- 投屏目标会话和媒体来源 Scope 必须一致，除非明确执行跨服务器重新加载。

## 8. 测试与迁移

自动测试：

- 单会话数据迁移、重复迁移和迁移中断恢复。
- 同服务器不同地址去重、不同服务器相同 Item ID 隔离。
- 一个账户 401、超时或离线时的部分结果。
- 聚合排序、分服务器分页和取消旧搜索。
- 切换 Workspace 时详情页、下载和播放仍绑定原 Scope。
- 删除账户后的 Token、客户端和 WebSocket 清理。
- 日志带不可逆 Scope 标签，但不含用户 Token 和完整隐私信息。

真机验收：

- 至少两个真实 Emby 服务器，或两个隔离的测试实例。
- 各服务器登录、切换、搜索、详情、播放和观看状态。
- 播放中切换浏览服务器，当前播放不中断也不串服。
- 一个服务器断网、Token 失效和地址变化。
- 聚合列表能指出离线来源并保留其他结果。

## 9. 发布步骤

1. `ServerScope` 和 Scoped ID 贯穿模型，但 UI 仍为单服务器。
2. 账户仓库和现有会话幂等迁移。
3. 手动切换服务器。
4. Scoped 图片、详情、播放、实时和下载。
5. 聚合首页。
6. 聚合搜索和分服务器加载更多。

每一步都必须保持旧用户升级后可直接使用原服务器。

## 10. GPL 边界

借鉴 Moonfin 的服务器仓库、客户端工厂和聚合仓库职责划分，不复制其 Provider、
Repository、数据库迁移或聚合算法代码。
