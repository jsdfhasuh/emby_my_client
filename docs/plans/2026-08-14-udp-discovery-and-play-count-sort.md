# UDP 局域网服务器发现与播放次数排序实施计划（Luna 执行版）

## 0. 文档状态

- 仓库：`jsdfhasuh/emby_my_client`
- 权威计划分支：`agent/udp-discovery-play-count-goal`
- 权威代码基线分支：`agent/ios-core-real-device-remediation`
- 冻结代码基线：`9a08746bf9d7d0061d637614568015c65e152647`
- 计划日期：`2026-08-14`
- 当前状态：`PLAN_ONLY / NOT_IMPLEMENTED / NOT_MERGED`
- 执行者：Luna

本计划只定义下一轮实现边界、阶段、测试和停止门禁。本计划分支只允许承载计划文档，不允许在本分支直接实现生产功能。

---

## 1. 总体目标

本轮拆分为两个相互独立的实现工作流，按顺序执行：

1. 媒体库排序增加“播放次数”。
2. 强化 UDP 局域网 Emby 服务器发现，并为 iPadOS/TrollStore 路径补齐 multicast entitlement 与真实设备验收。

两个功能不得堆叠在同一个实现分支中，不得让 UDP/iPadOS 外部权限门禁阻塞播放次数排序的独立交付。

### 1.1 工作流 A：播放次数排序

用户可在媒体库排序菜单中选择“播放次数”，并使用现有升序/降序按钮控制方向。排序必须由 Emby 服务端分页执行，实时播放次数变化后列表顺序必须重新校正。

### 1.2 工作流 B：UDP 服务器发现

登录页在前台发现同一局域网中的 Emby 服务器。Android 保持现有能力；iPadOS 开启 UDP broadcast 发现。扫描必须支持明确结果状态、真正取消、资源释放、手动输入降级，以及 TrollStore/标准 Apple 签名状态分离。

---

## 2. 强制执行规则

### 2.1 分支规则

两个实现分支都必须直接从冻结代码基线创建，不得从本计划分支或另一个功能分支继续开发：

```text
agent/library-play-count-sort
agent/ipados-udp-server-discovery
```

创建前必须执行：

```bash
git fetch origin
git cat-file -e 9a08746bf9d7d0061d637614568015c65e152647^{commit}
git show --no-patch --oneline 9a08746bf9d7d0061d637614568015c65e152647
```

如果任一目标分支已经存在，立即停止，不得覆盖、重置或 force-push。

### 2.2 Pull Request 规则

每个功能分支推送后创建独立 Draft PR：

```text
base: agent/ios-core-real-device-remediation
head: 对应功能分支
state: Draft
```

禁止：

- 以 `main` 为 PR base；
- 合并 PR；
- 将 Draft 改为 Ready for review；
- force-push；
- 删除分支；
- rebase 当前长期开发线到 `main`；
- 顺手修复无关问题。

### 2.3 变更范围规则

除本计划明确列出的文件外，出现新增依赖或受保护文件修改需求时先停止并报告，不得自行扩展范围。

### 2.4 证据规则

不得用“代码看起来正确”替代测试。每个阶段必须记录：

- 起始 HEAD；
- 结束 HEAD；
- 修改文件；
- 执行命令；
- 测试结果；
- 工作树状态；
- Draft PR 状态；
- 尚未完成的 Owner Gate。

---

## 3. 当前代码审核摘要

### 3.1 UDP 发现已有基础

当前已有：

- `lib/discovery/emby_server_discovery.dart`
  - UDP 端口 `7359`；
  - 请求消息 `who is EmbyServer?`；
  - 周期性重复广播；
  - JSON 响应解析；
  - 服务器 ID 和地址去重；
  - loopback 地址替换为数据包来源 IP；
  - 扫描结束关闭 timer、subscription 和 socket。
- `lib/ui/login_screen.dart`
  - Android 登录页自动扫描；
  - 手动重新扫描；
  - 点击服务器回填地址；
  - `_discoveryGeneration` 防止旧结果覆盖新页面。
- `test/emby_server_discovery_test.dart`
  - 端口、协议、地址标准化、重复结果等基础覆盖。

当前缺口：

- `discover()` 把所有异常压缩为空列表，UI 无法区分“未发现”和“扫描不可用”；
- `_discoveryGeneration` 只能阻止旧结果写 UI，不能提前停止旧 socket/timer；
- iPadOS 的 `supportsLanUdpDiscovery` 仍为 `false`；
- Runner/TrollStore entitlement 没有 `com.apple.developer.networking.multicast`；
- CI 的历史冻结门禁会拒绝 entitlement 改动；
- iPadOS 本地网络权限与真实 UDP 行为尚未做真机闭环。

### 3.2 媒体库排序已有统一状态

当前已有：

- `lib/library/library_browse_state.dart`
  - `LibrarySortBy` 和 `LibrarySortOrder`；
  - 非名称升序时自动清除并禁用字母筛选；
  - reducer 和状态归一化。
- `lib/data/emby_api.dart`
  - 媒体、facet、目录及本地扫描查询均透传 `SortBy`/`SortOrder`；
  - 服务端分页；
  - `EnableUserData=true`。
- `lib/ui/library_screen.dart`
  - 排序菜单；
  - 独立升降序按钮；
  - generation 防止旧分页写入；
  - 排序切换清空结果并回到顶部；
  - 实时 UserData 局部更新和保留位置刷新。

当前缺口：

- `LibrarySortBy` 没有 `PlayCount`；
- `EmbyUserData` 没有解析 `UserData.PlayCount`；
- 当前实时逻辑把普通进度变化视为无需重新排序，但 `PlayCount` 变化会影响整个分页顺序；
- STRM/普通媒体扫描缓存不会自动知道同一查询 key 的服务端播放次数顺序已经改变。

---

# 工作流 A：播放次数排序

## A0. 基线冻结与分支建立

创建：

```bash
git switch --detach 9a08746bf9d7d0061d637614568015c65e152647
git switch -c agent/library-play-count-sort
```

验证：

```bash
git rev-parse HEAD
git status --short
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
```

任何基线测试失败都必须停止，不得把既有失败归入本功能。

### Stop Gate A0

```text
BASE_SHA=9a08746bf9d7d0061d637614568015c65e152647
WORKTREE=CLEAN
FORMAT=PASSED
ANALYZE=PASSED
FULL_TEST=PASSED
```

---

## A1. 增加播放次数模型和排序字段

### 允许修改

```text
lib/models/emby_models.dart
lib/library/library_browse_state.dart
lib/ui/library_screen.dart

test/emby_models_test.dart
test/library_browse_state_test.dart
test/library_browse_state_integration_test.dart
```

### 生产实现

在 `EmbyUserData` 增加：

```dart
final int playCount;
```

要求：

```dart
playCount: _asInt(json['PlayCount']) ?? 0
```

并补齐构造函数、`copyWith`、相等性相关使用场景所需逻辑。

在 `LibrarySortBy` 增加：

```dart
playCount('PlayCount')
```

在排序文案中增加：

```dart
LibrarySortBy.playCount => '播放次数'
```

### 固定约束

本阶段禁止：

- 新增 `allowedSortBy` 或重新设计媒体库 capability；
- 新增另一套排序事件；
- 选择“播放次数”时自动切换为降序；
- 在客户端拉取完整媒体后排序；
- 在卡片或详情页展示播放次数；
- 修改 `_listItemFields` 添加 `PlayCount`；
- 修改媒体卡片布局；
- 为照片或目录增加特殊禁用逻辑。

选择“播放次数”时必须保持当前 `sortOrder`，方向仍由现有按钮控制。

`PlayCount` 属于 `UserData`，查询继续依赖：

```text
EnableUserData=true
SortBy=PlayCount
```

不得伪造：

```text
Fields=...,PlayCount
```

### 测试

至少覆盖：

- 缺失 `PlayCount` 时默认为 `0`；
- 整数、数值字符串等现有 `_asInt` 支持输入；
- `copyWith` 保留和更新 `playCount`；
- `LibrarySortBy.playCount.apiValue == 'PlayCount'`；
- 非名称排序自动清除字母筛选；
- 切回名称升序后字母导航能力恢复；
- 状态笛卡尔积归一化仍幂等。

### 建议提交

```text
feat: add play-count library sort model
```

### Stop Gate A1

定向模型和状态测试通过后才进入 API/UI 阶段。

---

## A2. API 与 UI 查询契约

### 允许修改

```text
lib/data/emby_api.dart
lib/ui/library_screen.dart

test/library_query_test.dart
test/library_browse_test.dart
test/library_position_integration_test.dart
```

如现有 API 已可通过枚举透传 `PlayCount`，不要增加多余生产分支，只补齐契约测试。

### 必须验证的请求

```text
SortBy=PlayCount
SortOrder=Ascending
```

以及：

```text
SortBy=PlayCount
SortOrder=Descending
```

至少覆盖：

- 普通媒体列表；
- 收藏范围；
- genre facet；
- tag facet；
- 第二页及后续分页；
- STRM/普通媒体候选扫描查询；
- `EnableUserData=true`；
- 现有过滤条件不丢失。

### UI 行为

- 排序菜单出现“播放次数”；
- 选择时保持当前方向；
- 点击现有方向按钮切换升序/降序；
- 切换排序后清空旧分页；
- 滚动位置回到顶部；
- 旧 generation 不能覆盖新结果；
- 播放次数排序时字母导航不可见；
- 切回名称升序后字母导航恢复；
- “重置筛选和排序”恢复名称升序。

### 建议提交

```text
feat: add server-side play-count sorting
```

### Stop Gate A2

API 契约、排序菜单、方向切换、字母导航和分页 generation 测试必须全部通过。

---

## A3. 实时 UserData 与顺序修复

### 允许修改

```text
lib/ui/library_screen.dart

test/library_user_data_membership_test.dart
test/library_reload_generation_test.dart
test/library_local_media_scan_service_test.dart
```

仅在测试证明缓存层必须增加最小辅助 API 时，才允许修改：

```text
lib/library/library_local_media_scan_cache.dart
lib/library/library_local_media_scan_service.dart
```

### 增加 refresh-all 状态

在当前 pending realtime 状态旁增加：

```dart
bool _pendingRealtimeUserDataRefreshAll = false;
```

接收 `EmbyUserDataChanged` 时：

- `itemIds` 为空：设置 `refreshAll=true`；
- `itemIds` 非空：继续合并到 pending ID 集合；
- debounce/batch 行为继续复用现有 `RealtimeRefreshBinding`；
- 一个批次最多触发一次重载。

### 决策规则

#### 当前不是 `PlayCount` 排序

保持现有行为，不得扩大刷新范围。

#### 当前是 `PlayCount` 排序，且 `refreshAll=true`

- 普通服务器分页：执行保留位置刷新；
- 本地 STRM/普通媒体筛选：重新启动当前扫描。

#### 事件包含未知或尚未加载的 item ID

执行完整刷新，因为该项目可能因播放次数变化进入当前分页范围。

#### 全部 item ID 已加载

先调用 `getUserDataForItems()`，逐项比较：

```dart
old.userData.playCount != updated.playCount
```

- 任一 `playCount` 改变：完整刷新；
- `playCount` 未改变：继续原地更新播放进度、收藏和已播放状态；
- 播放状态或收藏成员资格变化仍按现有 membership 逻辑处理。

### 本地扫描规则

当前处于：

```text
LibraryLocalMediaFilter.strm
LibraryLocalMediaFilter.regular
```

且播放次数发生变化时：

- 不得只在缓存中更新部分项目；
- 不得客户端重排部分列表；
- 必须 restart 当前扫描；
- 保留当前 scope、mediaType、playedFilter、localFilter、facet、sortBy 和 sortOrder；
- 允许重新扫描时滚动回顶部。

### 普通服务器分页规则

播放次数变化时：

- 使用现有保留位置刷新；
- 失败时恢复旧列表、旧统计和旧滚动位置；
- 旧 UserData 请求不得写入更新后的 generation。

### 必须测试

- 仅播放进度变化不触发排序重载；
- `playCount` 变化触发一次重载；
- 一个 realtime batch 只重载一次；
- 未加载项目变化触发重载；
- 空 item ID 事件触发重载；
- 旧 UserData 请求不能写入新 generation；
- 重载失败恢复旧列表和固定错误提示；
- STRM 扫描重新执行；
- 当前排序、方向和筛选不丢失；
- 非播放次数排序的现有 realtime 行为无回归。

### 建议提交

```text
fix: refresh play-count ordering after user data changes
```

### Stop Gate A3

实时重排和本地扫描测试通过后才允许运行全量门禁。

---

## A4. 播放次数排序最终门禁

执行：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze

flutter test test/emby_models_test.dart
flutter test test/library_query_test.dart
flutter test test/library_browse_state_test.dart
flutter test test/library_browse_state_integration_test.dart
flutter test test/library_browse_test.dart
flutter test test/library_reload_generation_test.dart
flutter test test/library_user_data_membership_test.dart
flutter test test/library_local_media_scan_service_test.dart
flutter test test/library_position_integration_test.dart

flutter test
git diff --check
flutter build apk --debug
flutter build apk --debug --split-per-abi
```

推送并创建 Draft PR，base 必须为：

```text
agent/ios-core-real-device-remediation
```

### Owner 验收

使用真实 Emby 服务器验证：

1. 播放次数升序；
2. 播放次数降序；
3. 分页连续性；
4. 收藏范围；
5. STRM/普通媒体筛选；
6. 播放一个媒体并确认服务端增加播放次数；
7. 返回媒体库后确认顺序重新校正。

### 最终状态

```text
PLAY_COUNT_MODEL=PASSED
PLAY_COUNT_QUERY=PASSED
PLAY_COUNT_ASCENDING=PASSED
PLAY_COUNT_DESCENDING=PASSED
PLAY_COUNT_REALTIME_REORDER=PASSED
PLAY_COUNT_LOCAL_SCAN_RESTART=PASSED
FULL_TEST=PASSED
ANDROID_BUILD=PASSED
READY_FOR_OWNER_ACCEPTANCE
NOT_MERGED
```

---

# 工作流 B：iPadOS UDP 服务器发现

## B0. 重新从冻结代码基线创建独立分支

不得从播放次数功能分支创建：

```bash
git switch --detach 9a08746bf9d7d0061d637614568015c65e152647
git switch -c agent/ipados-udp-server-discovery
```

运行与 A0 相同的基线门禁。

### Stop Gate B0

```text
BASE_SHA=9a08746bf9d7d0061d637614568015c65e152647
BRANCH_INDEPENDENT_FROM_PLAY_COUNT=true
WORKTREE=CLEAN
FORMAT=PASSED
ANALYZE=PASSED
FULL_TEST=PASSED
```

---

## B1. 建立明确的发现结果契约

### 允许修改

```text
lib/discovery/emby_server_discovery.dart

test/emby_server_discovery_test.dart
```

### 固定结果模型

采用以下概念，不另行设计完全不同的架构：

```dart
enum EmbyDiscoveryStatus {
  found,
  notFound,
  unavailable,
  cancelled,
}

enum EmbyDiscoveryFailureKind {
  transport,
  broadcast,
  receive,
  unknown,
}

class EmbyDiscoveryResult {
  const EmbyDiscoveryResult({
    required this.status,
    this.servers = const [],
    this.failureKind,
  });

  final EmbyDiscoveryStatus status;
  final List<DiscoveredServer> servers;
  final EmbyDiscoveryFailureKind? failureKind;
}
```

增加可取消对象：

```dart
class EmbyDiscoveryCancellation {
  bool get isCancelled;
  Future<void> get whenCancelled;
  void cancel();
}
```

发现接口调整为：

```dart
Future<EmbyDiscoveryResult> discover({
  EmbyDiscoveryCancellation? cancellation,
})
```

允许根据 Dart 语法需要微调构造方式，但不得退回“所有失败都返回空列表”的契约。

### 状态规则

```text
至少一次广播发送成功，超时无合法响应：notFound
socket/transport 创建失败：unavailable / transport
所有广播地址均发送失败：unavailable / broadcast
接收流失败且没有有效服务器：unavailable / receive
已经发现至少一个服务器，之后发生非致命错误：found
主动取消：cancelled
```

非法 JSON 包只忽略并记录安全诊断，不使整次扫描失败。

### 必须保留

- UDP 端口 `7359`；
- 请求消息 `who is EmbyServer?`；
- limited broadcast `255.255.255.255`；
- 现有定向 `/24` 广播尝试作为兼容补充；
- 单个地址失败不影响其他地址；
- 服务器 ID 去重；
- 标准化地址去重；
- loopback/`0.0.0.0` 地址替换；
- 最终按名称稳定排序。

### 本轮不做

- 基于真实 netmask 计算 broadcast；
- IPv6 发现；
- Bonjour/NSBonjourServices；
- Network.framework 重写；
- 后台持续扫描；
- 登录后的在线状态监控。

### 测试

- 正常发现一个和多个服务器；
- 无服务器正常超时；
- socket bind/transport 创建失败；
- 一个广播地址失败、另一个成功；
- 所有广播地址失败；
- receive stream error；
- malformed JSON；
- 重复 ID；
- 重复地址；
- loopback 地址；
- 排序稳定；
- transport 最终只关闭一次。

### 建议提交

```text
refactor: add typed cancellable server discovery
```

---

## B2. 真正取消 UDP 扫描资源

取消后必须尽快：

- 停止 rebroadcast timer；
- 取消 packet subscription；
- 关闭 `RawDatagramSocket`；
- 停止等待完整 `listenDuration`；
- 拒绝晚到数据进入最终结果；
- `cancel()` 幂等；
- 页面销毁不再留下 2.5 秒后台扫描。

必须覆盖：

- transport bind 完成前取消；
- bind 完成后取消；
- 连续取消；
- 取消后晚到包；
- 取消与扫描自然完成竞态；
- timer 不再继续发送；
- close 只执行一次。

如果为了可靠取消必须增加内部 operation/helper，只允许放在 discovery 模块内，不新增第三方依赖。

### 建议提交

```text
fix: cancel UDP discovery resources promptly
```

### Stop Gate B2

取消和资源释放测试全部通过，且没有 pending timer 测试警告。

---

## B3. 登录页状态和生命周期

### 允许修改

```text
lib/ui/login_screen.dart

test/login_screen_test.dart
test/login_keyboard_layout_test.dart
```

保留现有 `_discoveryGeneration`，同时维护当前 cancellation。

### 生命周期

页面销毁：

```dart
_discoveryCancellation?.cancel();
_discoveryGeneration++;
```

开始新扫描前：

1. 取消旧扫描；
2. 创建新 cancellation；
3. 递增 generation；
4. 开始新扫描；
5. 旧 operation 完成后不能更新新状态。

### UI 状态

扫描中：

```text
正在搜索局域网中的 Emby 服务器…
```

正常无结果：

```text
未发现局域网服务器。请确认设备与服务器位于同一网络；若首次使用或曾拒绝权限，请检查系统的“本地网络”设置。
```

扫描不可用：

```text
无法启动局域网扫描，仍可手动输入服务器地址。
```

禁止直接显示：

```text
本地网络权限已被拒绝
```

单纯 UDP 无响应不能可靠证明权限状态。

### 列表与手动输入规则

- 首次进入自动扫描一次；
- 支持手动重新扫描；
- 扫描失败不影响手动输入和登录；
- 自动扫描结果不得自动覆盖地址输入框；
- 只有用户点击服务器项才回填；
- 手动重新扫描期间保留旧服务器列表；
- 新扫描成功后替换旧列表；
- `notFound` 时清空旧列表；
- `unavailable` 时保留旧列表并显示警告；
- 页面退出后无活跃 socket、subscription 或 timer；
- 不破坏现有 iPad 键盘避让、安全诊断入口和登录错误分类。

### Widget 测试

- scanning；
- found；
- notFound；
- unavailable；
- cancelled 不显示伪错误；
- 点击服务器回填；
- 重试成功；
- 新扫描取消旧扫描；
- dispose 取消扫描；
- 晚到结果不更新页面；
- 手动输入在扫描失败后保留；
- iPad 与 Android 均显示发现入口；
- 现有键盘布局测试继续通过。

### 建议提交

```text
feat: surface cancellable LAN discovery on login
```

---

## B4. iPadOS multicast entitlement 与 CI 门禁

### 允许修改

```text
lib/platform/platform_capabilities.dart

test/platform_capabilities_test.dart

scripts/ios/runner-entitlements.plist
scripts/ios/trollstore-entitlements.plist
ios/Runner/DebugProfile.entitlements
ios/Runner/Release.entitlements
scripts/ios/sync_entitlements.sh
scripts/ios/validate_entitlements.sh
scripts/ios/test_entitlement_policy_negative_gates.sh
.github/workflows/ios-core.yml
```

只有测试确实引用时，才允许同步调整相关 entitlement 测试辅助文件。

### 明确禁止修改

```text
ios/Runner/Info.plist
ios/Runner/AppDelegate.swift
ios/Podfile
ios/Podfile.lock
pubspec.yaml
pubspec.lock
Gemfile
Gemfile.lock
```

当前 `Info.plist` 已有本地网络使用说明和本地网络 ATS 配置，本轮不增加 Bonjour service，也不需要原生 MethodChannel。

### entitlement 单一来源

Runner 和 TrollStore 两个单一来源均增加：

```xml
<key>com.apple.developer.networking.multicast</key>
<true/>
```

Runner Debug/Release 文件必须继续由同步脚本生成，不得手工形成不同内容。

### 精确允许的 key 集合

Xcode Runner：

```text
com.apple.developer.networking.multicast
keychain-access-groups
```

TrollStore Runner：

```text
application-identifier
com.apple.developer.networking.multicast
com.apple.developer.team-identifier
keychain-access-groups
```

并验证：

```text
com.apple.developer.networking.multicast == true
```

framework/dylib 仍必须保持空 application entitlement。

### 负面门禁

至少覆盖：

- multicast key 缺失；
- 值为 `false`；
- 值不是 Boolean；
- 出现未知 entitlement；
- Runner 镜像与单一来源不一致；
- TrollStore 最终 Runner 未携带 multicast entitlement；
- framework/dylib 错误携带应用 entitlement。

### CI 历史冻结门禁

不得整体删除受保护文件检查。

只允许从历史 `git diff --exit-code` 冻结列表中移除本轮明确受语义校验控制的 entitlement 文件：

```text
:(glob)ios/**/*.entitlements
scripts/ios/runner-entitlements.plist
scripts/ios/trollstore-entitlements.plist
```

其余受保护文件继续冻结。随后必须通过：

- `sync_entitlements.sh` 镜像一致性；
- `validate_entitlements.sh` exact key/value；
- negative gates；
- 构建后 Runner entitlement dump；
- framework/dylib 空 entitlement；
- TrollStore 最终 IPA entitlement 再验证。

### 平台能力

完成 entitlement 模板、验证脚本和 CI 后，才修改：

```dart
PlatformCapabilities.ipad.supportsLanUdpDiscovery = true;
```

并删除过期限制：

```text
不支持局域网 UDP 自动发现，必须手动输入服务器地址
```

Android capability 保持不变。

### TrollStore 与标准 Apple 签名分开报告

必须分别记录：

```text
TROLLSTORE_MULTICAST_ENTITLEMENT
APPLE_SIGNED_MULTICAST_ENTITLEMENT
```

TrollStore 使用 `ldid` 注入并通过最终 IPA dump 验证；标准 Apple 签名仍依赖 Apple entitlement 授权和包含该 entitlement 的 provisioning profile。

允许最终状态：

```text
TROLLSTORE_MULTICAST_ENTITLEMENT=PASSED
APPLE_SIGNED_MULTICAST_ENTITLEMENT=WAITING_FOR_OWNER
```

不得因为 TrollStore 可用就声称标准 Apple 签名已完成，也不得因为标准 Apple profile 尚未准备就否定 TrollStore 真机结果。

### 建议提交

```text
feat: enable multicast entitlement for iPad discovery
ci: validate multicast entitlement semantically
```

### Stop Gate B4

所有 entitlement 正向/负向门禁、镜像同步、最终 Runner dump 和 embedded Mach-O 检查通过后，才允许进入真机 Owner Gate。

---

## B5. UDP 自动化最终门禁

执行：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze

flutter test test/emby_server_discovery_test.dart
flutter test test/login_screen_test.dart
flutter test test/login_keyboard_layout_test.dart
flutter test test/platform_capabilities_test.dart

bash -n scripts/ios/*.sh
shellcheck scripts/ios/*.sh

bash scripts/ios/sync_entitlements.sh --runner-files
bash scripts/ios/validate_entitlements.sh --xcode
bash scripts/ios/test_entitlement_policy_negative_gates.sh

flutter test
git diff --check

flutter build apk --debug
flutter build apk --debug --split-per-abi
flutter build ios --debug --no-codesign
```

推送并创建 Draft PR，base：

```text
agent/ios-core-real-device-remediation
```

Draft PR CI 至少应完成：

- Quality and Android；
- iPadOS device build；
- TrollStore IPA；
- entitlement preflight；
- final Runner entitlement dump；
- embedded framework/dylib entitlement check；
- IPA checksum。

---

## B6. 真实 iPad Owner Gate

iOS Simulator 不能代替本地网络隐私与真实 UDP broadcast 验收。

### 真机步骤

1. iPad 与 Emby 服务器连接同一 Wi-Fi；
2. 安装包含 multicast entitlement 的新 IPA；
3. 首次进入登录页；
4. 确认系统本地网络权限提示；
5. 选择允许；
6. 必要时点击重新扫描；
7. 确认发现 Emby；
8. 点击服务器并确认地址正确回填；
9. 扫描中离开页面，确认无崩溃或残留任务；
10. 重新安装并选择拒绝；
11. 确认仍可手动输入并登录；
12. 在系统设置重新允许本地网络；
13. 返回应用重新扫描并确认恢复；
14. 验证 Emby 返回 `127.0.0.1`/`0.0.0.0` 时使用 UDP 来源地址修正；
15. 导出最终 IPA Runner entitlement dump。

### 至少验证的场景

| 场景 | Android | iPad |
|---|---:|---:|
| 一个 Emby 服务器 | 必测 | 必测 |
| 两个 Emby 服务器 | 必测 | 必测 |
| 无服务器 | 必测 | 必测 |
| 重复响应 | 自动化 | 自动化 |
| loopback 返回地址 | 自动化 | 真机复核 |
| 首次允许权限 | 不适用 | 必测 |
| 首次拒绝权限 | 不适用 | 必测 |
| 设置中重新允许 | 不适用 | 必测 |
| 扫描中退出页面 | 必测 | 必测 |
| 手动输入降级 | 必测 | 必测 |

### 最终状态

```text
UDP_DISCOVERY_ANDROID=PASSED
UDP_DISCOVERY_CANCELLATION=PASSED
UDP_DISCOVERY_MANUAL_FALLBACK=PASSED
TROLLSTORE_MULTICAST_ENTITLEMENT=PASSED
UDP_DISCOVERY_IPAD_TROLLSTORE=PASSED
APPLE_SIGNED_MULTICAST_ENTITLEMENT=PASSED | WAITING_FOR_OWNER
UDP_DISCOVERY_IPAD_APPLE_SIGNED=PASSED | WAITING_FOR_OWNER
FULL_TEST=PASSED
ANDROID_BUILD=PASSED
IOS_NO_CODESIGN_BUILD=PASSED
READY_FOR_OWNER_ACCEPTANCE | WAITING_FOR_DEVICE_OWNER
NOT_MERGED
```

---

## 4. 建议提交序列

### 播放次数排序分支

```text
feat: add play-count library sort model
feat: add server-side play-count sorting
fix: refresh play-count ordering after user data changes
test: cover paged and filtered play-count sorting
docs: record play-count sorting evidence
```

### UDP 发现分支

```text
refactor: add typed cancellable server discovery
fix: cancel UDP discovery resources promptly
feat: surface cancellable LAN discovery on login
test: cover discovery failures and lifecycle
feat: enable multicast entitlement for iPad discovery
ci: validate multicast entitlement semantically
docs: record iPad UDP discovery evidence
```

提交可在不破坏阶段边界的前提下合并，但禁止形成一个包含两个工作流的单一功能提交。

---

## 5. 停止规则

发生以下任一情况立即停止当前工作流：

- 冻结基线不存在或不一致；
- 工作树在开始前不干净；
- 基线 format/analyze/full test 失败；
- 目标分支已经存在；
- 需要修改计划未允许的受保护文件；
- 需要新增第三方依赖；
- Emby 真实服务端不接受 `SortBy=PlayCount`；
- entitlement 正向或负向门禁无法保持 exact key/value；
- Apple 标准签名需要 Owner 提供 capability/profile；
- 真实 iPad 才能继续；
- CI 出现与本功能无关的首个失败。

停止报告必须包含：

```text
IMPLEMENTATION_BLOCKED

Repository:
Branch:
Base SHA:
Current HEAD:
Working tree:

Failed command:
First actual error:

Changed files:
Commits created:
Pushed:
Draft PR:

Required owner action:
```

不得隐瞒失败，不得把未运行写成通过。

---

## 6. Luna 最终报告格式

每个实现分支最后严格输出：

```text
IMPLEMENTATION_COMPLETE | IMPLEMENTATION_BLOCKED
READY_FOR_OWNER_ACCEPTANCE | WAITING_FOR_DEVICE_OWNER
NOT_MERGED

Repository:
Branch:
Base SHA:
Final HEAD:
Remote HEAD:
Working tree:

Commits:
- <sha> <message>

Changed production files:
- ...

Changed test files:
- ...

Changed build/CI/docs files:
- ...

Validation:
- format:
- analyze:
- focused tests:
- full tests:
- Android builds:
- iOS build:
- entitlement checks:
- Draft PR CI:

Owner gates:
- ...

Known limitations:
- ...

Pull request:
- number:
- base:
- head:
- state: Draft
```

---

## 7. 完成定义

本计划本身提交完成不等于功能完成。

只有两个实现分支分别满足其自动化门禁、Draft PR 状态和 Owner Gate 后，才可进入后续合并决策。任何分支在 Owner 验收前都必须保持：

```text
NOT_MERGED
```
