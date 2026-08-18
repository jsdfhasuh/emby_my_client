# 媒体详情分类直达实施计划

## 0. 文档元数据

- 文档状态：`FROZEN_FOR_IMPLEMENTATION`
- 计划日期：2026-08-18
- 仓库：`jsdfhasuh/emby_my_client`
- 实施分支：`agent/media-detail-genre-navigation`
- 基线分支：`main`
- 基线 HEAD：`69128cf3c8100a51741c187d28cbb622e008ccb0`
- 计划文件：`docs/plans/2026-08-18-media-detail-genre-navigation-plan.md`
- 当前阶段：`PLAN_ONLY`
- 合并策略：实施、测试、审查完成前不得合并 `main`

本文件是“媒体详情分类直达”功能的唯一实施依据。实施者不得以只给 `Chip` 增加点击事件的局部补丁替代本计划中的媒体库来源解析、分类 ID 解析、分页返回保持和完整入口覆盖。

---

## 1. 目标

在电影、电视剧、单集和普通视频详情页中，将服务端返回的分类标签（例如“剧情”“Sci‑Fi & Fantasy”）改为可点击入口。用户点击分类后，直接进入该媒体所属媒体库下对应的分类分页页。

最终交互：

```text
媒体库分页页
  → 媒体详情页
    → 点击分类标签
      → 对应分类分页页
        → 另一媒体详情页
          → 播放器
```

返回路径必须保持普通路由栈：

```text
播放器
  → 分类中的媒体详情页
    → 分类分页页
      → 原媒体详情页
        → 原媒体库分页页及原滚动位置
```

从分类分页页直接执行“播放全部”或“随机播放”时，播放器退出后直接返回分类分页页。

---

## 2. 冻结的业务语义

### 2.1 分类范围限定当前媒体库

分类结果必须限定媒体所属的媒体库根节点：

```text
ParentId = 媒体所属媒体库根 ID
GenreIds = 点击分类对应的分类 ID
```

例如，从电视剧媒体库打开某部剧集并点击 `Sci‑Fi & Fantasy`，结果页只能展示该电视剧媒体库中的匹配项目，不得混入电影媒体库或其他媒体库中的同名分类。

### 2.2 必须使用分类 ID

详情接口当前提供的是分类名称列表 `Genres`，而现有分类媒体查询使用 `GenreIds`。因此点击后必须先在目标媒体库的 `/Genres` 索引中解析分类 ID，再复用 `LibraryBrowseScreen.facet`。

禁止新增以下旁路：

- 按分类名称直接查询媒体；
- 全服务器同名分类聚合；
- 新建第二套分类列表页面；
- 以搜索结果代替 facet 页面；
- 仅从媒体库入口有效、搜索和人物入口失效的半成品。

### 2.3 支持的详情类型

| 项目类型 | 规则 |
| --- | --- |
| `Movie` | 有 `Genres` 时支持 |
| `Series` | 有 `Genres` 时支持 |
| `Episode` | 服务端返回 `Genres` 时支持 |
| `Video` | 服务端返回 `Genres` 时支持 |
| `Photo` | 有分类时可以支持，通常无入口 |
| 文件夹、媒体库根 | 不属于媒体详情分类入口 |

### 2.4 本轮不做

- `Tags` 详情直达；
- 分类页面视觉重做；
- 电视剧分类页“播放全部”的新语义；
- 播放器和播放队列重构；
- 分类深链接、应用重启后的路由恢复；
- 跨服务器或跨账号缓存。

---

## 3. 当前实现与缺口

当前实现已经具备：

1. `ItemDetailScreen` 统一展示 `item.genres`；
2. `LibraryFacetKind.genre`、`LibraryFacet` 和 `LibraryBrowseState.facet`；
3. `LibraryBrowseScreen.facet(...)`；
4. `/Genres` 分类索引查询；
5. `getLibraryMediaItems(... genreId: ...)`；
6. facet 页的分页、排序、筛选、字母导航、图片查看和播放返回逻辑；
7. 媒体库页面从详情返回后刷新 UserData，并在播放次数排序或成员条件变化时保留位置刷新。

当前缺口：

1. 详情页分类只是普通 `Chip`，没有点击行为；
2. `EmbyItem` 未保存已经请求回来的 `ParentId`；
3. 详情页只有分类名称，没有分类 ID；
4. 搜索、人物作品、继续观看等入口没有明确媒体库根上下文；
5. 嵌套目录页面当前只持有当前目录 `view`，没有持续保留原媒体库根；
6. 详情页不能直接引用 `library_screen.dart`，否则会形成 UI 文件循环依赖。

---

## 4. 总体设计

采用“已知来源优先、父级链解析兜底”的统一流程：

```text
详情页点击分类
  → 已知 LibraryBrowseOrigin？
      → 是：直接使用
      → 否：LibraryRootResolver 根据 ParentId 向上解析媒体库根
  → LibraryGenreResolver 分页读取目标媒体库 /Genres
  → 严格匹配分类名称并得到 LibraryFacet
  → 由 HomeShell 导航协调器 push LibraryBrowseScreen.facet
```

页面职责必须分离：

- `ItemDetailScreen`：展示分类、发送导航请求、处理点击加载态；
- library resolver：解析媒体库根和分类 ID；
- `HomeShell`：组装依赖并打开 facet 路由；
- `LibraryBrowseScreen.facet`：继续承担现有分类分页能力。

---

## 5. 数据模型调整

### 5.1 保存 ParentId

修改：

```text
lib/models/emby_models.dart
```

为 `EmbyItem` 增加：

```dart
final String? parentId;
```

同步更新：

- 构造函数；
- `EmbyItem.fromJson`；
- `copyWith`；
- 测试 fixtures 和常量实例。

解析空字符串时应规范化为 `null`。现有 UserData `copyWith` 不得丢失 `parentId`。

### 5.2 媒体库来源对象

新增：

```text
lib/library/library_navigation_context.dart
```

定义不可变对象：

```dart
@immutable
class LibraryBrowseOrigin {
  const LibraryBrowseOrigin({
    required this.rootView,
    required this.profile,
  });

  final EmbyItem rootView;
  final LibraryContentProfile profile;
}
```

要求：

- `rootView.id` 必须非空；
- `rootView` 表示媒体库根，不是当前子目录；
- `profile` 必须由媒体库根 `collectionType` 得到；
- 不持久化到本地数据库。

### 5.3 导航请求

导航请求可以定义在 `home_shell_navigation.dart` 或单独的 UI 导航模型文件中，但不得让 library domain 层依赖 Widget。

请求至少包含：

```text
sourceContext
item
genreName
knownOrigin（可空）
platformCapabilities（可空，仅用于保持测试/平台覆盖）
```

---

## 6. 媒体库根解析器

新增：

```text
lib/library/library_root_resolver.dart
```

### 6.1 接口职责

输入：

```text
EmbyItem
可选已知 LibraryBrowseOrigin
```

输出：

```text
LibraryBrowseOrigin
```

已知来源有效时必须直接返回，不发额外网络请求。

### 6.2 解析流程

1. 获取并缓存当前会话的 `api.getViews()`；
2. 建立媒体库根 ID 映射；
3. 从 `item.parentId` 开始；
4. 若父 ID 命中根 ID，返回对应 root 和 profile；
5. 否则调用 `api.getItem(parentId)` 获取父节点；
6. 继续沿父节点的 `parentId` 向上查找；
7. 命中根节点后，将本次遍历链中的 ID 全部缓存到该 origin；
8. 无法命中时失败关闭，不根据 `Movie`、`Series` 等类型猜测媒体库。

如果传入 item 的 `parentId` 缺失，允许先刷新一次 `api.getItem(item.id)` 再决定失败。

### 6.3 安全边界

- 最大祖先深度：32；
- 使用 `visitedIds` 防止循环；
- 空 ID 立即停止；
- 父级请求失败写入脱敏 `DiagnosticLog`；
- 不把原异常直接展示给用户；
- 缓存仅存在于当前 HomeShell/会话生命周期。

### 6.4 失败类型

至少区分：

```text
rootUnavailable
ancestorLoop
ancestorDepthExceeded
requestFailed
```

UI 固定文案：

```text
无法确定该媒体所属的媒体库
```

网络或服务端异常可以统一为：

```text
分类加载失败，请重试
```

---

## 7. 分类 ID 解析器

新增：

```text
lib/library/library_genre_resolver.dart
```

### 7.1 查询

使用现有：

```dart
api.getLibraryGenres(
  parentId: origin.rootView.id,
  profile: origin.profile,
  startIndex: ...,
  limit: 60,
)
```

不得新增按名称查询媒体的 API。

### 7.2 分页

必须处理超过一页的分类索引，并按服务端原始数量推进：

```text
nextStartIndex += page.rawItemCount
```

应复用现有 `library_raw_page_cursor.dart` 或实现等价且经过测试的停滞保护。无效项、重复项不得导致无限请求。

### 7.3 匹配规则

匹配优先级：

1. 原始字符串完全一致；
2. trim 后完全一致；
3. 大小写不敏感，并将连续空白规范化后完全一致。

禁止模糊包含匹配。

下列情况必须失败关闭：

- 分类不存在；
- 规范化后存在多个不同 ID 的同名分类；
- 分页停滞；
- profile 不支持 genres。

成功结果：

```dart
LibraryFacet(
  id: matched.id,
  name: matched.name,
  kind: LibraryFacetKind.genre,
)
```

### 7.4 缓存

缓存范围为当前会话和媒体库：

```text
libraryId + normalizedGenreName → LibraryFacet
```

不缓存永久 negative result。首次未找到时应强制刷新分类索引一次，再返回“未找到”。

固定 UI 文案：

```text
当前媒体库没有找到该分类
分类加载失败，请重试
```

---

## 8. 持续传递媒体库根上下文

### 8.1 LibraryBrowseScreen

修改：

```text
lib/ui/library_screen.dart
```

新增可选或构造器内部确定的媒体库根字段，例如：

```dart
final EmbyItem? libraryRoot;
```

构造规则：

```text
LibraryBrowseScreen.root
  libraryRoot = view

LibraryBrowseScreen.facet
  libraryRoot = view

LibraryBrowseScreen.directory
  libraryRoot = 父页面传入的原始媒体库根；未知时允许为 null
```

从 root/facet 进入目录、从目录进入下一层目录时，必须继续传递同一个 `libraryRoot`，不能把当前文件夹误认为媒体库根。

打开详情时，如果 `libraryRoot` 有效，应传递：

```dart
LibraryBrowseOrigin(
  rootView: libraryRoot,
  profile: widget.profile,
)
```

### 8.2 首页

修改：

```text
lib/ui/home_screen.dart
```

首页“最新媒体”已经持有 `section.library`，应直接构造已知 origin 并传入详情。

“继续观看”可能没有明确媒体库来源，可以传 `null`，由 root resolver 兜底。

### 8.3 搜索和人物作品

检查：

```text
lib/ui/search_screen.dart
lib/ui/person_detail_screen.dart
```

只要它们继续向详情传递统一 `navigationActions`，通常不需要独立实现分类解析。来源未知时由统一 resolver 处理。

---

## 9. 导航协调器

### 9.1 HomeShellNavigationActions

修改：

```text
lib/ui/home_shell_navigation.dart
```

增加可选分类导航回调。建议使用 source `BuildContext`，确保在当前 Navigator 上执行普通 `push`：

```dart
Future<void> Function(
  BuildContext sourceContext,
  EmbyItem item,
  String genreName,
  LibraryBrowseOrigin? knownOrigin,
  PlatformCapabilities? platformCapabilities,
)? openGenre;
```

字段保持可选，避免破坏独立 Widget 测试和现有构造代码。

### 9.2 HomeShell 实现

修改：

```text
lib/ui/home_shell.dart
```

HomeShell 为当前会话创建：

```text
LibraryRootResolver
LibraryGenreResolver
```

分类点击处理：

1. trim 分类名称；
2. 使用已知 origin 或 root resolver；
3. 使用 genre resolver 得到 facet；
4. 在 `sourceContext` 对应 Navigator 上 `push`：

```dart
LibraryBrowseScreen.facet(
  api: api,
  view: origin.rootView,
  profile: origin.profile,
  facet: facet,
  downloads: downloads,
  categorySettings: categorySettings,
  libraryScanService: libraryScanService,
  navigationActions: navigationActions,
  platformCapabilities: platformCapabilities,
)
```

禁止：

- `pushReplacement`；
- `popUntil`；
- 切换 HomeShell 页签；
- 先返回媒体库再打开分类；
- 清空原详情或分页路由。

### 9.3 并发保护

相同的：

```text
itemId + libraryId/unknown + normalizedGenreName
```

请求未完成时必须忽略重复点击，防止创建多个相同 facet 路由。

---

## 10. 详情页 UI

修改：

```text
lib/ui/item_detail_screen.dart
```

### 10.1 分类控件

将普通：

```dart
Chip(label: Text(genre))
```

改为可点击 `ActionChip`。手机紧凑布局和 iPad 大屏布局继续复用同一个 `_buildGenres`。

要求：

- 保留 `Wrap`、`spacing` 和 `runSpacing`；
- 使用稳定的 `ValueKey`，不要直接把未经处理的特殊字符作为唯一测试依赖；
- tooltip/语义标签为“查看‘分类名’分类”；
- 当前点击项显示小型加载状态；
- 加载状态不得导致明显尺寸跳动；
- 其他分类可继续显示；
- 同一分类加载中不可重复点击。

### 10.2 无导航能力

当 `navigationActions.openGenre == null` 时，保持普通展示 `Chip`，不得显示一个永久禁用且无解释的 ActionChip。

### 10.3 错误处理

详情页不得显示原始异常、URL、token 或服务端响应。所有真实异常写入现有脱敏 `DiagnosticLog`，UI 只展示固定 SnackBar 文案。

---

## 11. 分页、返回和播放不变量

### 11.1 原媒体库分页页

分类跳转使用普通 `push`，因此原媒体库页面实例必须保留：

```text
_items
_seenItemIds
_nextStartIndex
_state
ScrollController offset
```

从 facet 返回原详情，再从原详情返回媒体库时，不得无条件重载第一页或跳回顶部。

### 11.2 分类分页页

从分类页进入详情再播放：

```text
facet page → detail → player
```

播放器退出后先回详情；详情返回后回 facet 页。facet 页已经加载的分页和滚动位置必须保留。

### 11.3 UserData 更新

保持现有规则：

- 普通排序和无成员筛选时，只刷新相关 item UserData；
- 按播放次数排序时，可执行保留位置刷新；
- `played/unplayed/favorites` 成员变化时，可执行保留位置刷新；
- 不得因本功能对所有返回路径无条件全量刷新。

---

## 12. 测试计划

### 12.1 新增测试

建议新增：

```text
test/library_root_resolver_test.dart
test/library_genre_resolver_test.dart
test/item_detail_genre_navigation_test.dart
test/library_genre_navigation_integration_test.dart
```

### 12.2 Root resolver 覆盖

至少验证：

1. 已知 origin 时零网络请求；
2. 直接父级命中媒体库根；
3. 多层目录；
4. Episode → Season → Series → 电视剧库；
5. item 首次无 ParentId，刷新后成功；
6. 父级循环；
7. 超过最大深度；
8. 父级请求失败；
9. 无法命中 `getViews()`；
10. 缓存后第二次不重复请求；
11. 不按项目类型猜测媒体库。

### 12.3 Genre resolver 覆盖

至少验证：

1. 第一页命中；
2. 第二页及之后命中；
3. 中文分类；
4. `Sci‑Fi & Fantasy` 特殊字符；
5. trim 和连续空白；
6. 英文大小写不敏感；
7. 分类不存在；
8. 同名不同 ID 歧义；
9. 重复条目；
10. 原始分页停滞；
11. 成功缓存；
12. 首次未命中后强制刷新一次。

### 12.4 详情 UI 覆盖

至少验证：

1. 有导航回调时显示 ActionChip；
2. 无导航回调时保持普通 Chip；
3. 点击传递正确 item、genre 和 origin；
4. 重复快速点击只产生一个请求；
5. 加载结束后恢复可点击；
6. 固定错误文案；
7. 手机、iPad 横竖屏和 2.0x 文字缩放无 overflow；
8. 多个长分类名能够换行。

### 12.5 路由和分页集成覆盖

至少验证：

```text
媒体库加载两页
  → 打开详情
    → 点击分类
      → facet 请求包含正确 ParentId 和 GenreIds
        → 打开 facet 项目详情
          → 播放并返回
            → 返回 facet 原分页位置
              → 返回原详情
                → 返回原媒体库原分页位置
```

直接断言：

```text
ParentId
GenreIds
StartIndex
路由类型
分页请求次数
滚动位置
```

不能只断言页面标题。

### 12.6 回归测试

扩展或确认以下测试：

```text
test/item_detail_layout_matrix_test.dart
test/item_detail_ambient_layout_test.dart
test/library_browse_state_integration_test.dart
test/library_pagination_integrity_test.dart
test/library_position_integration_test.dart
test/home_shell_navigation_test.dart
test/person_ui_test.dart
```

---

## 13. 实施阶段与提交建议

### Phase 0：计划与基线

```text
docs: plan media detail genre navigation
```

### Phase 1：模型和来源上下文

```text
refactor: model library genre navigation context
```

内容：

- `EmbyItem.parentId`；
- `LibraryBrowseOrigin`；
- 模型测试。

### Phase 2：媒体库根解析

```text
feat: resolve media library roots for genre navigation
```

### Phase 3：分类 ID 解析

```text
feat: resolve library genre facets by media metadata
```

### Phase 4：持续传递 root origin

```text
refactor: preserve library roots through media routes
```

### Phase 5：统一导航协调

```text
feat: coordinate genre navigation from media details
```

### Phase 6：详情分类可点击化

```text
feat: make media detail genres navigable
```

### Phase 7：分页、播放和布局回归

```text
test: preserve paged routes across genre navigation
```

### Phase 8：最终证据

```text
docs: freeze media detail genre navigation delivery
```

实施者可在保证审查清晰的前提下合并相邻提交，但不得把全部生产代码、测试和文档压成一个难以审查的提交。

---

## 14. 门禁

每个阶段至少执行相关定向测试。最终必须执行：

```bash
dart format --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
flutter build apk --debug --split-per-abi
```

具备 macOS 环境时追加：

```bash
flutter build ios --debug --no-codesign
```

任何测试失败、分页停滞、导航重复、原页面位置丢失或固定错误文案泄露原始异常，均不得标记完成。

---

## 15. 最终验收标准

只有同时满足以下条件才可标记 `IMPLEMENTATION_COMPLETE`：

1. 电影和电视剧详情分类均可点击；
2. `Episode`/`Video` 有分类时行为一致；
3. 手机和 iPad 两套详情布局共用统一实现；
4. 点击后直接打开现有 facet 分类分页页；
5. 请求携带正确媒体库根 `ParentId`；
6. 请求携带正确分类 `GenreIds`；
7. 不混合其他媒体库中的同名分类；
8. 嵌套目录中的媒体仍使用原媒体库根；
9. 首页最新媒体无需祖先查询即可跳转；
10. 搜索、继续观看和人物作品可通过 resolver 跳转；
11. 分类索引超过一页时仍能正确解析；
12. 同名歧义时不自动选错；
13. 连续点击不会创建重复路由；
14. 返回后原媒体库分页、筛选、排序和滚动位置保留；
15. 分类页播放后仍返回原 facet 分页位置；
16. 播放次数排序或成员筛选变化继续采用保留位置刷新；
17. 失败 UI 只显示固定文案；
18. 诊断日志保持脱敏；
19. 2.0x 文字缩放和长分类名无 overflow；
20. 全量测试、分析和 Android Debug 构建通过；
21. `main` 未被直接修改；
22. 工作树 clean，分支已推送。

---

## 16. 最终报告格式

实施完成后必须报告：

```text
STATUS=IMPLEMENTATION_COMPLETE | BLOCKED
BASE_MAIN_HEAD=<sha>
BRANCH=agent/media-detail-genre-navigation
FINAL_BRANCH_HEAD=<sha>
ORIGIN_BRANCH_HEAD=<sha>
MAIN_UNCHANGED=true|false
WORKTREE=CLEAN|DIRTY
FORMAT=PASS|FAIL
ANALYZE=PASS|FAIL
TESTS=<passed/failed summary>
ANDROID_DEBUG_APKS=PASS|FAIL|NOT_RUN
IOS_DEBUG=PASS|FAIL|NOT_RUN
PUSHED=true|false
```

并列出：

- 关键实现文件；
- 新增和修改的测试；
- 实际请求证据（正确 `ParentId` 与 `GenreIds`）；
- 分页和滚动位置回归证据；
- 已知限制；
- 所有提交 SHA。
