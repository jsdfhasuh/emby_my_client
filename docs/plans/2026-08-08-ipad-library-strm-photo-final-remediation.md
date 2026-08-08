# iPad 媒体库、STRM、混合图片库与详情页最终整改计划（修订冻结版）

更新日期：2026-08-08

状态：`FROZEN_FOR_IMPLEMENTATION`

实施仓库：`jsdfhasuh/emby_my_client`

实施分支：`agent/ios-core-real-device-remediation`

## 0. 权威基线与门禁

```text
code_baseline =
d7288cb078be8be6b7d6138447585bbce820409c

withdrawn_plan_commit =
f45a849b57b73f765d2b4f6b89cdf815210dcd73

plan_withdrawal_commit =
298fe9e479d9649b3f7752154402bee596f02c15

implementation_start_head =
本修订计划所在的远端分支 HEAD；Codex 启动提示词必须锁定提交完成后的精确 SHA。
禁止回退到 code_baseline 或 withdrawn_plan_commit。
```

本文件取代已经撤回的 `f45a849b...` 版本，是本轮媒体库列表、混合图片库、STRM/普通媒体扫描、位置统计、图片查看器和 iPad 横屏详情页的唯一权威实施依据。

当前门禁：

```text
STOP_GATE_B = BLOCKED_BY_IMPLEMENTATION
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

计划阶段命名约定：

```text
M0–M8：本文件的实施阶段
T：本文件的跨阶段测试与收口阶段
LEGACY_IOS_PHASE_8：旧 iOS 整改流程的最终证据阶段
```

本轮必须完成 `M0–M8` 与 `T`，但不得进入 `LEGACY_IOS_PHASE_8`。

---

## 1. 真机事实与问题边界

设备所有者在 iPadOS/TrollStore 真机中确认：

1. 媒体库列表页顶部同时存在浏览方式、媒体类型、媒体筛选和分散操作栏，媒体内容出现过晚。
2. “媒体类型”不应永久占据一整栏，但能力需要保留，并且未来需要支持“图片”。
3. 播放、随机播放、排序、筛选和更多操作过于分散，存在多个视觉相似的筛选入口。
4. iPad 横屏六列海报偏密，封面和标题偏小。
5. STRM 筛选显示“已匹配 N 项、继续统计中”，但用户无法确认应用是否会自动扫描全部分页。
6. STRM/普通媒体统计不能依赖用户滚动；选择后必须自动扫描完整服务端结果。
7. STRM 筛选时，右侧位置浮层不得继续使用原媒体库总数。
8. iPad 横屏详情页仍像移动端纵向布局放大版；Backdrop 应改为整页氛围图，前景海报完整显示。
9. 用户的媒体库类型是“家庭视频和照片”，即 `homevideos` 混合库。
10. 当前仅将 `CollectionType=photos` 识别为图片库，`homevideos` 中图片可能不查询、不展示或路由错误。
11. 现有图片查看器具备左右翻页和缩放能力，但目录分页、混合库路由和筛选图片序列不足。
12. 所有真机截图和真实媒体名称均为私人内容，不得提交到仓库、Issue、PR、测试 fixture 或 Artifact。

这些问题均为必须关闭的功能缺口，不得登记为平台预期限制。

---

## 2. 已冻结的产品决策

### 2.1 根浏览范围

根媒体库最多显示：

```text
媒体 / 目录 / 分类 / 标签 / 收藏
```

实际可见范围必须由：

```text
LibraryContentProfile.allowedScopes
∩
用户 LibraryCategorySettings
```

共同决定。

固定语义：

- 媒体：当前媒体库的递归媒体结果。
- 目录：按服务器目录层级浏览直接子项。
- 分类：Genre 等分类索引。
- 标签：Emby 标签索引。
- 收藏：当前媒体库中的收藏结果。

嵌套目录和具体分类/标签结果页不得重复显示根范围栏。

### 2.2 媒体类型移入统一筛选

页面不再永久显示“媒体类型”一栏。

多条件筛选面板可显示：

```text
媒体类型：全部 / 电影 / 剧集 / 视频 / 图片
媒体来源：全部 / STRM / 普通媒体
播放状态：全部 / 未播放 / 已播放
```

每个维度内部单选；不同维度之间使用 AND。

媒体库只剩一个有效媒体类型时，整个媒体类型分组隐藏，不得显示“媒体类型：全部”。

### 2.3 筛选草稿与原子应用

打开筛选面板时，从当前已应用状态复制草稿。

```text
取消 / 返回 / 点击遮罩 / 手势关闭
→ 丢弃草稿，不改变当前页面

重置
→ 只重置草稿

查看结果
→ 一次 reducer 事件
→ 一次查询或一次扫描订阅切换
```

禁止每点击一个筛选项就启动一轮查询或全库扫描。

### 2.4 内容优先列表页

iPad 横屏最终结构：

```text
精简大屏导航
媒体 / 目录 / 分类 / 标签 / 收藏
结果总数 / 播放 / 随机播放 / 排序 / 筛选 / 更多
仅扫描期间出现的细进度
五列媒体网格
```

要求：

- 第一排媒体必须在 1024×768 首屏可见。
- 页面只能存在一个筛选入口。
- 操作采用图标＋文字。
- 不存在永久媒体类型栏或永久媒体来源栏。
- 排序区与媒体网格之间不得出现大块空白。

### 2.5 STRM/普通媒体体验

- 选择 STRM 或普通媒体后，自动扫描完整服务端候选集合。
- 扫描不依赖滚动。
- 边扫描边展示。
- 在应用内部进入详情、设置、搜索或图片查看器后继续。
- iPadOS 系统后台不保证持续网络执行；恢复前台后从 raw cursor 继续。
- 同一登录会话内缓存；不跨进程持久化。
- STRM 与普通媒体共享同一轮候选扫描。
- 扫描未完成前不得虚构最终总数、剩余数或百分比。
- 扫描完成且 unknown=0 后，位置统计必须基于当前筛选结果。

### 2.6 iPad 横屏详情页

- iPad 横屏采用整页氛围背景的双栏布局。
- Backdrop 使用 cover、暗化、轻微模糊和渐变；允许适度裁切。
- 前景 Primary 海报使用 contain，完整显示。
- 左侧是海报；右侧是标题、观看信息、操作和演员。
- 标签、简介和其他信息后置。
- iPad 竖屏与 Android 手机继续响应式纵向布局。

### 2.7 精简导航

大屏页面语义：

```text
左侧：返回 / 主页 / 当前页面名称
右侧：搜索 / 账号 / 设置
```

不增加无功能投屏按钮；投屏协议不在本轮范围。

导航只能有一个所有者，禁止 HomeShell AppBar 与路由页面再叠加一套重复 AppBar。

---

## 3. 范围与非目标

### 3.1 本轮范围

1. `LibraryContentProfile` 内容能力模型。
2. Profile 与用户可见设置的交集规则。
3. 图片媒体类型和 `showPhotos` 兼容迁移。
4. `photos`、`homevideos`、movies、tvshows、mixed、unknown/null 的安全识别。
5. 混合视频/图片/目录/相册查询和卡片。
6. 所有入口的类型驱动导航。
7. 目录图片序列和筛选图片序列。
8. 图片分页 raw cursor 修复。
9. 页面外生命周期的 STRM/普通媒体扫描服务。
10. 扫描缓存、暂停、恢复、取消、重试和资源上限。
11. 当前结果空间中的统一统计和位置浮层。
12. 完整服务端结果的播放全部/随机播放语义。
13. 内容优先列表 UI 和原子多条件筛选。
14. iPad 横屏氛围双栏详情页。
15. 首页、搜索、收藏、目录、分类和标签中的图片路由。
16. 既有 iPadOS、Android、登录、键盘、方向和诊断功能回归。

### 3.2 明确非目标

```text
UDP 服务器发现
投屏协议与设备控制
图片上传、删除、重命名、旋转或编辑
图片幻灯片和背景音乐
Live Photo、RAW、GIF 专用支持
跨重启持久化 STRM 缓存
iPhone 正式适配
桌面端正式适配
依赖或工具链升级
修改或合并 main
LEGACY_IOS_PHASE_8
```

---

## 4. 受保护边界

本轮禁止修改：

```text
pubspec.yaml
pubspec.lock
ios/Podfile.lock
ios/Runner/Info.plist
所有 entitlement
Bundle ID
MinimumOSVersion
UIDeviceFamily
TrollStore 三键身份
Android UDP 发现行为
安全登录诊断 schema
完整调试日志安全边界
```

必须保留用户未跟踪目录：

```text
docs/test/
```

禁止：

```text
git add -A
git clean
git reset --hard
git rebase
git push --force
提交用户原始截图
提交真实媒体名称
记录服务器地址、用户名、Token、设备 ID、完整 Item ID 或请求 URL
```

Flutter 自动测试基线：

```text
497 tests passed
```

最终测试数不得低于 497，且不得删除、skip 或弱化现有测试。

Swift XCTest 基线必须在 M0 从计划起始 HEAD 对应的最新成功 Actions 日志中记录；最终执行数量不得减少。

---

## 5. 媒体库内容能力模型

新增：

```text
lib/library/library_content_profile.dart
```

建议模型：

```dart
enum LibraryContentProfileKind {
  movies,
  tvShows,
  homeVideosAndPhotos,
  photos,
  mixed,
  unknown,
}

class LibraryContentProfile {
  final LibraryContentProfileKind kind;
  final Set<LibraryBrowseScope> allowedScopes;
  final Set<LibraryMediaType> allowedMediaTypes;
  final bool supportsGenres;
  final bool supportsTags;
  final bool supportsFavorites;
  final bool supportsDirectories;
  final bool supportsPlayedFilter;
  final bool supportsLocalSourceFilter;
  final bool supportsPlayAll;
}
```

### 5.1 确定性识别算法

Profile 不得根据第一页缺少某种条目而缩小能力。

第一层，按结构化 `CollectionType` 静态映射：

```text
movies      → movies
tvshows     → tvShows
homevideos  → homeVideosAndPhotos
photos      → photos
mixed       → mixed
```

第二层：

```text
null / unknown
→ 使用保守 mixed 能力
→ 不得默认当成纯影视库
```

第三层：

- 真实返回条目只允许扩大已知兼容能力或记录诊断证据。
- 不得因为不完整分页中没有 Photo 就关闭图片能力。
- 如需探测，必须使用有界、只读、可测试的明确探测请求；不得依赖普通列表第一页。

### 5.2 媒体类型

```dart
enum LibraryMediaType {
  all,
  movie,
  series,
  video,
  photo,
}
```

`all` 不再保存固定 API 字符串，由 `Profile + MediaType` 解析 `IncludeItemTypes`。

建议基础映射：

```text
movies:
  all/movie → Movie

tvShows:
  all/series → Series
  具体季/集继续使用现有详情流程

homeVideosAndPhotos:
  all → Movie,Video,Photo
  movie → Movie
  video → Video
  photo → Photo

photos:
  all/photo → Photo

mixed/unknown:
  all → Movie,Series,Video,Photo
```

真实服务器需要 `Episode` 等类型时，必须通过明确兼容映射和测试加入，不得把未知非文件夹自动视为可播放。

### 5.3 Profile 与用户设置

根入口与媒体类型可见性由：

```text
Profile 能力 ∩ LibraryCategorySettings
```

决定。

现有设置 key 保持不变：

```text
movies
series
videos
favorites
folders
```

新增：

```text
photos
```

迁移规则：

```text
旧账号没有 photos key
→ showPhotos = true

账号数据清理
→ 同时删除 photos key

不得重命名或丢弃旧 key
```

设置页文案统一使用“目录”，但底层 `folders` key 保持不变。

若设置变更后当前 scope 或 mediaType 被隐藏：

- 在 build 之外触发规范化。
- 回到 `media`。
- mediaType 回到 `all` 或首个允许类型。
- 清除不兼容筛选。
- generation-safe 重新查询。

### 5.4 状态归一化

所有规则必须进入纯 reducer/normalizer。

固定规则：

- `photo` 自动清除 STRM/普通媒体和播放状态。
- 纯图片库隐藏无效筛选分组。
- 在混合 `all` 中应用来源或播放筛选时，仅保留适用的可播放候选。
- 收藏可与图片组合；播放状态不适用于图片。
- directory 清除来源、播放和字母筛选。
- genres/tags 索引清除媒体筛选。
- 点击已选单选项不产生状态变化或请求。

---

## 6. 统一查询层

保留或新增职责明确的方法：

```dart
getLibraryMediaItems(...)
getDirectoryChildren(...)
getPhotoItems(...)
getLibraryGenres(...)
getLibraryTags(...)
getSearchItems(...)
```

### 6.1 媒体查询

根据 Profile、scope、mediaType 和服务端筛选生成：

```text
Recursive
IncludeItemTypes
Filters
GenreIds / TagIds
SortBy
SortOrder
字母条件
分页
```

收藏与播放条件必须正确合并。

### 6.2 混合目录查询

家庭视频和照片目录允许：

```text
Folder
CollectionFolder
PhotoAlbum
Movie
Series
Episode
Video
Photo
```

要求：

```text
Recursive=false
```

目录请求不得携带不兼容的播放、收藏、字母或来源筛选。

### 6.3 raw cursor

所有分页 API 返回：

```dart
EmbyItemPage(
  items: parsedItems,
  rawItemCount: rawItems.length,
  totalRecordCount: total,
)
```

分页规则：

```text
nextStartIndex += rawItemCount
显示层按 ID 去重
rawItemCount == 0 时按第 10 节的完成/停滞规则处理
```

不得用解析后 `items.length` 推进游标。

### 6.4 总数异常

```text
total == null
→ 显示“已加载 N 项”
→ 不显示剩余和百分比

total < loadedCount
→ effectiveTotal = loadedCount
→ 记录安全诊断
→ 百分比不得超过 100%

分页中 total 改变
→ 标记统计 dirty
→ 重新确认或刷新
```

---

## 7. 类型驱动导航覆盖所有入口

新增或统一纯 resolver：

```dart
resolveLibraryEntryAction(profile, scope, item)
```

规则：

```text
Folder / CollectionFolder / PhotoAlbum
→ 打开下一级目录

Photo
→ 打开全屏图片查看器

Movie / Series / Episode / Video
→ 进入详情或现有播放流程

Genre / Tag
→ 打开 facet 结果
```

必须覆盖：

```text
HomeScreen 最新内容
LibraryBrowseScreen
SearchScreen
目录结果
收藏结果
分类结果
标签结果
```

搜索必须增加：

```text
SearchItemType.photo
SearchItemType.all 包含 Photo
```

Photo 不得进入普通 `ItemDetailScreen`。

返回详情或图片查看器后：

- 保持浏览状态。
- 保持滚动位置。
- 只刷新必要 UserData 或受影响项目。
- 不无条件重载整个目录。

---

## 8. 图片卡片、查询与查看序列

### 8.1 卡片

新增或完善：

```text
library_directory_entry_card.dart
library_photo_card.dart
library_mixed_entry_card.dart
```

显示规则：

- 文件夹：目录图标和“目录”。
- 相册：相册图标。
- 图片：图片图标，不显示播放状态。
- 视频：播放图标、时长或年份。
- 电影、剧集、单集保留准确类型语义。
- 混合结果使用统一 4:3 卡片或经过测试的等价方案。
- 图片专用结果使用正方形或自适应网格。

### 8.2 图片序列抽象

```dart
sealed class PhotoSequenceSource {}

class DirectoryPhotoSource extends PhotoSequenceSource {}
class FilteredLibraryPhotoSource extends PhotoSequenceSource {}
```

统一分页加载器：

```dart
Future<EmbyItemPage> Function({
  required int startIndex,
  required int limit,
}) loadPage;
```

来源必须携带：

```text
queryFingerprint
initialRawCursor
initialTotalCount
initialItemId
```

### 8.3 目录图片

- `Recursive=false`。
- 左右翻页只包含同目录图片。
- 文件夹、相册和视频不进入 PageView。

### 8.4 筛选图片

- 继承当前媒体库、收藏/facet 和排序状态。
- 使用递归图片查询。
- 左右翻页只包含当前图片结果。
- 视频不混入图片序列。

### 8.5 迁移现有控制器

`PhotoBrowserController` 和 `PhotoViewerController` 必须迁移到 `EmbyItemPage`：

```text
nextStartIndex += rawItemCount
hasMore 按 raw cursor 与 total 判断
显示层按 ID 去重
```

不得继续使用解析后的 `page.length` 推进。

---

## 9. AppController 中的扫描服务所有权

新增：

```text
library_local_media_scan_service.dart
library_local_media_scan_cache.dart
```

工厂：

```dart
typedef LibraryScanServiceFactory =
    LibraryLocalMediaScanService Function(
      EmbyApi api,
      ServerScope scope,
    );
```

`AppController` 暴露只读：

```dart
LibraryLocalMediaScanService? get libraryScanService;
```

生命周期：

```text
Session 成功激活
→ 创建扫描服务

signOut
session expiry
delete account data
AppController.dispose
→ 禁止创建新扫描
→ cancelAll 并等待请求结束
→ dispose 扫描服务
→ 再 unregister API client
→ 再清除 Session / 数据
```

测试必须验证 API 不会在扫描请求仍运行时提前释放。

缓存作用域使用现有：

```dart
ServerScope.cacheNamespace
```

不得重复维护可不一致的 serverScopeHash 与 userScopeHash。

---

## 10. STRM/普通媒体候选与分类

### 10.1 候选集合

来源筛选只扫描可进行 STRM/普通媒体判断的可播放候选：

```text
Movie
Episode
Video
```

经过明确兼容测试后可增加其他类型。

禁止进入候选：

```text
Photo
Folder
CollectionFolder
PhotoAlbum
Series 聚合项
Genre
Tag
```

因此图片不会被误计入 unknown 或 regular。

### 10.2 分类

```dart
enum LibraryLocalMediaKind {
  strm,
  regular,
  unknown,
}
```

优先级：

```text
任意 Path / Container / MediaSource 明确为 STRM
→ strm

分类字段完整，且所有适用来源明确非 STRM
→ regular

字段缺失、格式异常或来源互相冲突
→ unknown
```

不得用“不是 STRM”直接推断 regular。

扫描字段至少包含：

```text
Path
Container
MediaSources
```

---

## 11. 扫描键、快照和内存结构

### 11.1 Scan key

```dart
class LibraryScanKey {
  final String scopeNamespace;
  final String libraryId;
  final LibraryBrowseScope scope;
  final LibraryMediaType mediaType;
  final LibraryPlayedFilter playedFilter;
  final LibraryFacet? facet;
  final LibrarySortBy sortBy;
  final LibrarySortOrder sortOrder;
  final LibraryAlphabetFilter alphabetFilter;
}
```

`localFilter` 不进入 key，因为一轮扫描同时产生 STRM 和 regular。

### 11.2 单一共享存储

禁止在每个 snapshot 中复制两份完整 `List<EmbyItem>`。

建议：

```text
itemsById / orderedSourceIds：共享候选对象
strmIds：ID/索引集合
regularIds：ID/索引集合
unknownIds 或 unknownCount
```

快照只暴露不可变视图和计数。

### 11.3 快照

```dart
class LibraryLocalScanSnapshot {
  final LibraryScanStatus status;
  final int rawCursor;
  final int scannedRawCount;
  final int? sourceTotalCount;
  final int strmCount;
  final int regularCount;
  final int unknownCount;
  final bool complete;
  final bool dirty;
  final LibraryScanErrorKind? safeError;
}
```

### 11.4 资源边界

冻结：

```text
同一 ServerScope 同时最多 1 个运行扫描
全局最多 2 个运行扫描，其余排队
最多保留 3 个已完成 session
最多保留 20,000 个唯一候选项目
每页最多发布 1 次进度快照
```

达到候选硬上限：

- 安全暂停。
- 不静默截断。
- 不声明 complete。
- UI 显示固定安全提示。

LRU 只淘汰最久未使用的已完成 session，不截断活跃扫描。

---

## 12. 自动扫描、暂停和重试

选择 STRM 或 regular：

1. 订阅或创建 scan session。
2. 自动请求所有后续分页。
3. 不依赖滚动。
4. 默认串行请求。
5. 每页完成后最多发布一次快照。
6. raw cursor 推进。
7. 切页面继续。
8. 页面重建后订阅既有 session。

重试规则：

```text
最多 3 次
退避：1s / 2s / 4s
401/403 不重试，交给 Session 过期流程
取消、退出登录或 scan key 改变后不得继续重试
```

超过上限：

```text
扫描已暂停
[继续扫描]
```

继续必须从 raw cursor 恢复。

### 12.1 空页与分页停滞

```text
total 已知
且 rawCursor < total
但 rawItemCount == 0
→ status = paginationStalled
→ complete = false
→ safeError = paginationStalled
→ 不显示最终总数、剩余或百分比
→ 允许从当前 cursor 重试

total 未知
且返回短页或空页
→ 按明确分页契约完成
```

TotalRecordCount 在扫描中变化：

- 标记 dirty。
- 不立即声明精确。
- 通过重新确认或完整刷新后才能恢复精确状态。

---

## 13. 统一统计和位置浮层

统一模型：

```dart
class LibraryResultStatistics {
  final int visibleLoadedCount;
  final int rawScannedCount;
  final int? exactResultTotal;
  final int? sourceTotal;
  final bool scanComplete;
  final bool dirty;
  final int unknownClassificationCount;
  final String contextLabel;
}
```

以下必须使用同一统计对象：

- 顶部结果数量。
- 扫描进度。
- 位置浮层。
- 播放全部/随机播放可用性。
- 空状态。
- 分页判断。

显示规则：

### 全部媒体

```text
85–102
共 3,768 项
还剩 3,666 项
2%
```

### 未播放

```text
未播放 85–102
共 326 项
还剩 224 项
31%
```

### 目录

```text
85–102
目录共 300 项
还剩 198 项
34%
```

### 图片

```text
85–102
图片共 240 项
还剩 138 项
43%
```

### STRM 扫描中

```text
85–102
STRM 统计中
已扫描 1,200 / 3,768
```

不得显示最终总数、剩余和百分比。

### STRM 完成且 unknown=0、dirty=false

```text
85–102
STRM 共 116 项
还剩 14 项
88%
```

### unknown > 0

显示固定提示：

```text
有 N 项无法判断
```

不得把 regular 总数声明为完全精确。

计算：

```dart
remaining = max(0, exactTotal - lastVisible);
percentage = exactTotal <= 0
    ? null
    : min(1.0, lastVisible / exactTotal);
```

---

## 14. 播放全部和随机播放的完整结果语义

当前 UI 已加载的 60 项不得冒充完整结果。

### 14.1 普通服务端结果

```text
播放全部 / 随机播放
→ 当前完整服务端筛选结果
```

实现必须使用：

```text
LazyLibraryPlaybackQueue
```

或服务器明确支持的完整队列接口。

分页队列必须继承：

```text
libraryId
scope
mediaType
played/favorite/facet
sort
queryFingerprint
raw cursor
```

### 14.2 STRM/普通媒体

- 扫描完成前禁用。
- 提示“统计完成后可用”。
- 扫描完成后使用完整精确匹配集合。
- unknown>0 时不得宣称完整 regular 队列。

### 14.3 混合图片库

```text
播放视频 / 随机视频
```

只作用于可播放条目，图片不得进入播放器。

队列准备过程必须支持：

- 进度。
- 取消。
- 固定错误文案。
- 不重复请求。
- 超大结果按懒加载分页。

---

## 15. HomeShell 与大屏导航所有权

新增可复用大屏 Chrome，例如：

```dart
class LargeScreenPageChrome extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onHome;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final VoidCallback onAccount;
}
```

必须选择并冻结单一导航所有者：

### 15.1 推荐架构

`HomeShell` 继续拥有根级 AppBar 与底部 NavigationBar。

push 出的媒体库和详情页：

- 不再叠加第二套全功能 AppBar。
- 通过注入的 `HomeShellNavigationActions` 请求：
  - 切到首页 tab；
  - 切到搜索 tab；
  - 打开账号菜单；
  - 打开设置。
- 页面自身只保留返回和当前标题所需的局部 Chrome。

### 15.2 路由行为

```text
主页
→ popUntil 回到 HomeShell
→ 将 _index 设为 0

搜索
→ popUntil 回到 HomeShell
→ 将 _index 设为搜索 tab

设置/账号
→ 由 HomeShell 持有 AppController 并执行
```

禁止：

- 双 AppBar。
- 重复搜索入口。
- 路由页自行创建第二个不共享状态的 HomeShell。
- 页面直接拿不到 AppController 却放置无功能按钮。

手机端可继续现有简洁 AppBar，但不得与大屏 Chrome 重叠。

---

## 16. 内容优先列表 UI

iPad 横屏：

```text
媒体 / 目录 / 分类 / 标签 / 收藏
共 N 项 / 播放 / 随机播放 / 排序 / 筛选 / 更多
可选扫描进度
五列网格
```

筛选摘要：

```text
筛选
筛选 · STRM
筛选 · 视频 · STRM · 未播放
筛选 3
```

动态分组：

- 只显示 Profile 支持并且有选择价值的组。
- 纯图片库无有效筛选时隐藏筛选按钮。
- 图片类型选中后，来源和播放状态草稿被归一化为全部。

“更多”仅包含：

```text
刷新
重置浏览状态
清理当前运行期扫描缓存
```

---

## 17. iPad 横屏氛围详情页

大屏模式条件：

```text
PlatformCapabilities = iPad
width > height
shortestSide >= 600
```

### 17.1 背景

优先级：

```text
Backdrop
Primary fallback
纯色渐变 fallback
```

使用有界 `ImageFiltered` 或等价方案，避免昂贵的全屏实时 BackdropFilter。

### 17.2 前景海报

- Primary contain。
- 无 Primary 时显示明确占位。
- 不把横向 Backdrop 强行裁成竖版海报。

### 17.3 信息来源

预计结束时间：

```text
now + max(0, runtime - resumePosition)
```

技术信息选择：

```text
优先当前默认或首个可播放 MediaSource
Video：首个 Type=Video
Audio：默认音轨，否则首个 Type=Audio
字段缺失则隐藏
```

不得制造服务器未返回的信息。

### 17.4 响应式

- 1024×768：双栏，标题和主操作首屏可见。
- 768×1024：纵向。
- 390×844：手机纵向。
- 文字缩放 2.0：允许滚动，无 overflow。
- 演员尽量进入首屏，标签和简介后置。

---

## 18. 结构化诊断

允许新增固定事件：

```text
library_profile_resolved
library_query_started
library_query_completed
library_query_empty
local_media_scan_started
local_media_scan_progress
local_media_scan_paused
local_media_scan_resumed
local_media_scan_completed
local_media_scan_stalled
photo_item_opened
photo_viewer_page_failed
detail_layout_mode_selected
```

允许字段：

```text
归一化 collection type
profile kind
item type
扫描数量
总数
安全错误类型
布局模式
```

禁止记录：

```text
媒体名称
图片名称
服务器地址
用户名
Token
设备 ID
完整 Item ID
请求 URL
Authorization
```

---

## 19. 实施阶段

### M0：基线记录（本计划提交后由 Codex执行）

记录：

```text
branch
implementation_start_head
upstream
status
main / origin/main
受保护文件 blob/SHA
Flutter test baseline = 497
Swift XCTest 实际基线
工作区仅允许 ?? docs/test/
```

### M1：Profile、设置迁移和状态模型

完成：

- `LibraryContentProfile`。
- `allowedScopes` 与 `allowedMediaTypes`。
- CollectionType 确定性映射。
- `showPhotos` 兼容迁移。
- Profile ∩ Settings。
- 图片筛选归一化。
- 原子筛选草稿。

提交建议：

```text
refactor: model mixed video and photo libraries
```

### M2：统一查询与所有入口路由

完成：

- profile-aware IncludeItemTypes。
- 混合目录查询。
- raw cursor。
- Home、Library、Search、收藏、分类和标签统一 resolver。
- Photo 搜索类型。
- 安全空状态和错误状态。

提交建议：

```text
refactor: unify mixed library queries and routing
```

### M3：图片序列与控制器迁移

完成：

- `PhotoSequenceSource`。
- Directory/Filtered sources。
- `EmbyItemPage` 分页。
- initialRawCursor/total/fingerprint。
- iPad 图片查看和返回位置。

提交建议：

```text
fix: support photos inside mixed Emby libraries
```

### M4：AppController 扫描服务生命周期

完成：

- 服务工厂与注入。
- activate/signOut/expiry/delete/dispose 顺序。
- 候选集合和分类。
- 单一共享内存结构。
- 资源上限。
- 扫描缓存。

提交建议：

```text
feat: scan local media sources independently of scrolling
```

### M5：自动扫描、停滞和统计

完成：

- 自动分页。
- 页面外继续。
- pause/resume/retry。
- paginationStalled。
- dirty total。
- 统一统计与位置浮层。

提交建议：

```text
fix: calculate position from the active result set
```

### M6：完整结果播放队列

完成：

- LazyLibraryPlaybackQueue 或等价服务端队列。
- 完整筛选结果。
- 扫描完成门禁。
- 混合库只播放视频。

提交建议：

```text
feat: play complete filtered library results
```

### M7：内容优先列表与导航

完成：

- HomeShell 导航动作。
- 唯一 Chrome。
- 五列网格。
- 单行操作栏。
- 原子多条件筛选。
- 动态卡片。

提交建议：

```text
feat: add content-first iPad library layout
```

### M8：氛围详情页

完成：

- iPad 横屏双栏。
- 氛围背景。
- 前景海报。
- 精确技术信息。
- 竖屏和 Android 回归。

提交建议：

```text
feat: add ambient iPad media detail layout
```

### T：跨阶段测试与收口

只修复跨阶段集成缺口，不新增范围外功能。

提交建议：

```text
test: complete library STRM photo and iPad UX matrix
```

完成 T 后仍不得进入 `LEGACY_IOS_PHASE_8`。

---

## 20. 自动测试矩阵

### 20.1 Profile 和设置

覆盖：

```text
photos
homevideos
movies
tvshows
mixed
unknown
null
showPhotos 旧 key 缺失迁移
目录/收藏/图片设置隐藏
当前 scope 被隐藏后规范化
```

### 20.2 状态与筛选草稿

- 图片清除来源和播放状态。
- 收藏＋图片保持收藏。
- 取消/返回/遮罩关闭丢弃草稿。
- 重置只改草稿。
- Apply 只提交一次。
- 点击已选项不请求。

### 20.3 API 和 raw cursor

- 纯图片库。
- homevideos 全部/视频/图片。
- 混合目录。
- 收藏＋图片。
- 分类/标签＋图片。
- 原始 60 条、解析 50 条时下一页从 60 开始。
- 重复 ID、无效 ID、空页和 total 改变。

### 20.4 所有入口图片路由

- Home 最新图片。
- Library 图片。
- Search 图片。
- 收藏图片。
- 分类/标签图片。
- 目录图片。
- Photo 不进入 ItemDetailScreen。

### 20.5 图片查看器

- 目录 source。
- 筛选 source。
- initialRawCursor。
- 左右翻页。
- 双击、双指缩放和平移。
- 相邻预取。
- 末尾分页。
- 失败重试。
- 返回位置。
- 系统 UI 恢复。

### 20.6 扫描服务

至少模拟 3,768 个候选、60 项分页：

- 不滚动自动扫完。
- Photo 不进入候选。
- STRM/regular 共享。
- unknown 不冒充 regular。
- 页面销毁后继续。
- App pause/resume。
- logout/expiry/delete/dispose 先停扫描再释放 API。
- 1s/2s/4s 重试。
- 401/403 不重试。
- paginationStalled。
- dirty total。
- LRU 和 20,000 上限。
- 每页最多一次快照。
- 无持续网络请求泄漏。

### 20.7 完整播放队列

- 普通结果加载后续分页。
- 随机不是只打乱首 60 项。
- 扫描中禁用。
- STRM 完成后使用完整集合。
- 混合库排除图片。
- 队列准备取消和错误。

### 20.8 统计与位置

覆盖：

```text
total=null
total<loaded
普通媒体
未播放
目录
图片
STRM 扫描中
STRM 完成
unknown>0
dirty
一屏可见
旋转后列数变化
```

### 20.9 UI 和导航

尺寸：

```text
1024×768
768×1024
1366×1024
390×844
text scale 1.0 / 1.3 / 2.0
```

验证：

- iPad 横屏 5 列。
- 第一排媒体首屏可见。
- 只有一个筛选入口。
- 无永久媒体类型栏。
- 无双 AppBar。
- 首页/搜索切换到正确 HomeShell tab。
- 设置/账号由同一 AppController 执行。
- Android 手机不回归。

### 20.10 详情页

覆盖：

- Backdrop。
- Primary fallback。
- 无图片。
- 多版本媒体源。
- 默认/首个音轨。
- resume 后预计结束时间。
- 长标题、多人演员、无演员。
- 双栏/纵向。
- text scale 2.0。

### 20.11 既有回归

必须继续通过：

```text
登录与 Keychain
iPad 键盘
播放退出方向恢复
下载降级
安全诊断
完整调试日志
Android UDP 发现
Android 普通和分 ABI APK
Swift XCTest
```

---

## 21. 性能与异步门禁

- 3,768 项扫描不得导致 3,768 次页面重建。
- 每页最多发布一次扫描快照。
- 快速切换筛选后无遗留 Timer、retry 或 Future。
- 扫描完成后无持续网络请求。
- 页面退出不取消 AppController 所有的活跃扫描。
- logout/expiry/delete/dispose 后无扫描请求。
- 图片预取保持既有有界并发。
- 全屏氛围模糊不得使用无界实时 BackdropFilter。

---

## 22. 本地验证门禁

每个生产阶段：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
```

涉及脚本：

```bash
for file in scripts/ios/*.sh; do
  bash -n "$file"
done

shellcheck scripts/ios/*.sh
```

最终：

```bash
flutter build apk --debug
flutter build apk --debug --split-per-abi
```

Actions 必须真实执行 Swift XCTest。

受保护文件相对 `code_baseline` 必须零差异。

```text
main = origin/main = 9b74b6216e25375ee2e44e8019bfbff9546a5f51
```

工作区最终只允许：

```text
?? docs/test/
```

---

## 23. Actions A/B 与 Gate B

旧 Run 55/56 仅保留为历史证据。

完成全部 M0–M8 与 T 后：

1. 记录 `implementation_code_head`。
2. 推送最终 HEAD。
3. 等自动 Run A 两个 Job、五类 Artifact、checksum 全部完成。
4. Run A 完成前不得触发 Run B。
5. 不再产生任何提交。
6. 同一 HEAD `workflow_dispatch` Run B。
7. Run B 两个 Job、五类 Artifact、checksum 完整。
8. `CFBundleVersion(B) > CFBundleVersion(A)`。
9. A/B 必须验证：

```text
head_sha 完全相同
Bundle ID = com.jsdfhasuh.embyclient
MinimumOSVersion = 13.0
UIDeviceFamily = [2]
全部 Mach-O = arm64
无 .appex
Runner entitlement 精确三个批准键
所有 embedded entitlement 为空
embedded 先签，Runner 最后签
两个锁文件无漂移
```

完成后：

```text
STOP_GATE_B = WAITING_FOR_DEVICE_OWNER
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

然后停止。不得进入 `LEGACY_IOS_PHASE_8`。

---

## 24. 真机 Gate B

### Run A 全新安装

至少验证：

1. 家庭视频和照片媒体库不再空白。
2. 混合库显示视频、图片、文件夹和相册。
3. Home/Library/Search/收藏/目录中的图片路由正确。
4. 图片左右切换、缩放、平移和分页正常。
5. 筛选面板只显示有效组。
6. 图片类型清除不兼容条件。
7. STRM 不滚动自动完成。
8. 进入详情/设置后扫描继续。
9. 扫描完成后位置浮层使用 STRM 结果。
10. 播放全部使用完整筛选结果。
11. iPad 横屏五列且内容首屏可见。
12. 无双 AppBar。
13. 氛围详情双栏和前景海报完整。
14. 播放退出方向恢复。
15. 登录、Session、Keychain、诊断正常。

### Run B 覆盖安装

不退出、不清数据，验证：

```text
Session 连续性
Keychain
设置迁移和保留
媒体库与图片
STRM 缓存和重新扫描
详情布局
播放方向
诊断导出
```

只有设备所有者全部填写真机结果后，才允许：

```text
STOP_GATE_B = PASSED
```

之后另行授权 `LEGACY_IOS_PHASE_8`。

---

## 25. 最终汇报

一次性汇报：

1. 最终分支与 implementation_code_head。
2. 相对本修订计划提交的所有提交。
3. Profile 与 Settings 映射。
4. showPhotos 迁移。
5. 全入口图片路由。
6. raw cursor 和图片序列。
7. 扫描服务所有权、候选、分类、资源上限和重试。
8. 统计与位置规则。
9. 完整播放队列语义。
10. HomeShell 导航所有权。
11. 列表 UI、筛选和 5 列规则。
12. 详情背景与技术信息选择。
13. 新增测试、最终测试数和性能门禁。
14. format/analyze/test/diff-check/bash-n/ShellCheck/Android/Swift 结果。
15. Run A/B URL、run number、同 HEAD、build number。
16. 两次五类 Artifact。
17. IPA 文件名、SHA-256、checksum。
18. Bundle、架构、entitlement、签名顺序和锁文件。
19. 仍需设备所有者执行的真机项。
20. 明确写出：

```text
未进入 LEGACY_IOS_PHASE_8
未修改或合并 main
未提交 docs/test/
未代填真机 PASS
未实现 UDP 发现
未实现投屏协议
未声明 IMPLEMENTATION_COMPLETE
未声明 ACCEPTED
```

完成全部任务前不得只汇报“已完成”。
