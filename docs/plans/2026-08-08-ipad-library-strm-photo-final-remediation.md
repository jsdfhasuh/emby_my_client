# iPad 媒体库、STRM、混合图片库与详情页最终整改计划

更新日期：2026-08-08

状态：`FROZEN_FOR_IMPLEMENTATION`

实施仓库：`jsdfhasuh/emby_my_client`

实施分支：`agent/ios-core-real-device-remediation`

代码基线：`d7288cb078be8be6b7d6138447585bbce820409c`

当前门禁：

```text
STOP_GATE_B = BLOCKED_BY_IMPLEMENTATION
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

本文件是本轮媒体库列表、STRM/普通媒体扫描、家庭视频和照片混合库、图片查看器及 iPad 横屏详情布局的唯一权威实施依据。旧计划中与本文件冲突的媒体库、筛选、图片或详情页描述，以本文件为准。

---

## 1. 背景与真机事实

设备所有者在 iPadOS/TrollStore 真机验收中确认以下问题：

1. 媒体库列表页顶部同时存在浏览方式、媒体类型、媒体筛选和分散操作栏，媒体内容出现过晚，整体更像查询后台而不是内容浏览页。
2. “媒体类型”长期占用一整行，但在部分媒体库中只有“全部”，没有有效选择价值；该能力仍需保留，且未来要支持“图片”，因此应移入统一的多条件筛选面板。
3. 播放、随机播放、排序、筛选和更多操作分散，存在重复或含义相似的筛选入口。
4. iPad 横屏默认六列海报过密，封面、标题和点击区域偏小。
5. STRM 筛选当前以“已匹配 N 项、继续统计中”为主要反馈，无法明确证明应用正在自动扫描全部分页。
6. STRM/普通媒体统计与列表滚动耦合或至少在用户体验上表现为耦合；设备所有者要求选择后自动扫描完整媒体库，不依赖滚动触发后续分页。
7. STRM 筛选时右侧位置浮层仍可能使用原媒体库总数，例如把 STRM 结果放在 3,768 项原始空间中计算，不能表示当前筛选结果还剩多少项。
8. iPad 横屏详情页虽已避免严重图片裁切，但仍表现为“上方巨幅图片、下方纯黑详情”的纵向移动端布局放大版，横向空间利用不足。
9. 详情页应向 Emby 大屏布局靠拢：Backdrop 作为整页氛围图，前景海报完整展示，右侧承载标题、观看信息和操作。
10. 设备所有者的媒体库类型为“家庭视频和照片”。当前客户端只将 `CollectionType=photos` 识别为纯图片库；`homevideos` 等混合库会进入普通媒体路径，图片可能不查询、不显示或无法进入全屏查看器。
11. 图片查看器本身已有左右翻页、缩放和预取能力，但当前混合库路由、查询和图片序列来源不足，导致 iPadOS 真机进入“家庭视频和照片”后页面空白或图片不可用。

以上均属于本轮必须关闭的真实功能缺口，不得登记为平台预期限制。

---

## 2. 已冻结的产品决策

### 2.1 媒体库顶层浏览方式

根媒体库保留一组清晰、互斥的浏览范围：

```text
媒体 / 目录 / 分类 / 标签 / 收藏
```

含义固定：

- 媒体：当前媒体库中的递归媒体结果。
- 目录：按服务器目录层级浏览直接子项。
- 分类：按 Genre 等分类索引浏览。
- 标签：按 Emby 标签索引浏览。
- 收藏：当前媒体库中的收藏结果。

嵌套目录和具体分类/标签结果页不得重复显示根级浏览范围栏。

### 2.2 媒体类型

“媒体类型”不再作为页面永久第二栏，但能力保留并移入多条件筛选面板。

最终媒体类型至少包括：

```text
全部 / 电影 / 剧集 / 视频 / 图片
```

具体可见项由媒体库内容能力决定。只有一个有效类型时，整组隐藏，不得显示没有选择价值的“媒体类型：全部”。

### 2.3 多条件筛选

页面只保留一个“筛选”入口。筛选面板包含：

```text
媒体类型：全部 / 电影 / 剧集 / 视频 / 图片
媒体来源：全部 / STRM / 普通媒体
播放状态：全部 / 未播放 / 已播放
```

每个维度内部单选，不同维度之间使用 AND 组合。例如：

```text
电影 + STRM + 未播放
收藏范围 + 视频 + 已播放
```

筛选面板使用草稿状态；只有点击“查看结果”才原子提交一次状态，禁止每点一个条件就启动一轮查询或全库扫描。

### 2.4 列表操作栏

媒体库列表页集中为一行：

```text
结果总数 / 播放 / 随机播放 / 排序 / 筛选 / 更多
```

主要操作使用“图标 + 文字”。页面不得存在第二个视觉相似的筛选入口。

### 2.5 网格密度

iPad 横屏 1024×768 逻辑尺寸采用五列标准媒体网格。iPad 竖屏和 Android 手机根据可用宽度响应式计算，禁止所有平台强制固定五列。

### 2.6 精简全局导航

大屏页面采用精简导航语义：

```text
左侧：返回 / 主页 / 当前页面名称
右侧：搜索 / 账号 / 设置
```

仅在仓库已有真实可用投屏能力时显示投屏按钮。本轮不得增加点击无效果的假投屏入口，也不实施投屏协议。

### 2.7 STRM 扫描体验

- 选择 STRM 或普通媒体后自动扫描完整服务端结果，不依赖滚动。
- 扫描时边发现、边展示。
- 在应用内部进入详情、设置、搜索或图片查看器后继续扫描。
- iPadOS 将应用置于系统后台时不承诺持续网络执行；恢复前台后从已记录游标继续。
- 本次登录会话内缓存扫描结果；不做跨进程持久化缓存。
- STRM 与普通媒体共享同一轮源数据扫描和分类结果。
- 切换筛选后可恢复已有进度，不从第 0 页无条件重扫。

### 2.8 位置浮层

所有可滚动结果列表均基于“当前结果空间”显示范围、总数、剩余数量和百分比。目录中的“还剩 N 项”表示还剩多少目录条目，不表示未观看。

扫描未完成前不得虚构本地筛选最终总数、剩余数量或百分比。

### 2.9 iPad 横屏详情页

- iPad 横屏采用完整双栏大屏布局。
- Backdrop 为整页氛围背景，使用暗化、轻微模糊和渐变；允许适度裁切。
- 前景 Primary 海报必须完整展示，不裁切主体。
- 左侧为海报，右侧为标题、年份、时长、分级、评分、可用技术信息和操作。
- 演员尽量进入首屏；标签和简介后置。
- iPad 竖屏和 Android 手机继续使用响应式纵向布局。

---

## 3. 范围与非目标

### 3.1 本轮范围

1. 内容优先的媒体库列表布局。
2. 单一多条件筛选面板。
3. 图片媒体类型与媒体库内容能力模型。
4. `photos`、`homevideos`、电影、剧集和未知混合媒体库的安全识别。
5. 家庭视频和照片混合查询、卡片和类型驱动导航。
6. 目录图片序列和筛选图片序列的全屏查看。
7. 页面外生命周期的 STRM/普通媒体全库扫描服务。
8. 本次登录会话运行期缓存、失效、暂停与恢复。
9. 当前结果空间中的统一统计和位置浮层。
10. iPad 横屏氛围双栏详情页。
11. iPadOS、Android 和既有 Gate B 能力的完整回归。

### 3.2 明确非目标

```text
UDP 服务器发现
投屏协议及设备控制
图片上传、删除、重命名、旋转或编辑
图片幻灯片、背景音乐
Live Photo、RAW、GIF 专用支持
跨重启持久化 STRM 缓存
iPhone 正式适配
桌面端正式适配
依赖或工具链升级
修改或合并 main
```

---

## 4. 受保护边界

本轮禁止修改：

```text
pubspec.yaml
pubspec.lock
ios/Podfile.lock
ios/Runner/Info.plist
所有 entitlement 文件
Bundle ID
最低 iOS 版本
TrollStore 三键身份
Android UDP 发现行为
安全登录诊断 schema
完整调试日志安全边界
```

允许存在且必须保留的用户未跟踪目录：

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
提交用户原始截图或真实媒体名称
在日志中记录服务器地址、用户名、Token、设备 ID 或完整 Item ID
```

---

## 5. 媒体库内容能力模型

新增：

```text
lib/library/library_content_profile.dart
```

建议定义：

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
  final Set<LibraryMediaType> allowedMediaTypes;
  final bool supportsDirectories;
  final bool supportsPhotos;
  final bool supportsPlayedFilter;
  final bool supportsLocalSourceFilter;
  final bool supportsPlayAll;
}
```

### 5.1 识别规则

识别必须基于服务器结构化 `CollectionType` 和实际返回条目类型，不得依赖媒体库中文名称。

至少支持：

```text
movies
tvshows
homevideos
photos
mixed
null / unknown
```

`homevideos` 归一化为“家庭视频和照片”能力，允许视频、图片和目录。

未知或空 `CollectionType` 使用安全混合能力：查询明确支持的视觉媒体类型，根据真实返回项分类；不得简单视为纯影视库，也不得任意把未知类型当文件夹。

### 5.2 媒体类型模型

将 `LibraryMediaType` 改为语义枚举，不再把 `all` 固定绑定到 `Movie,Series,Video`：

```dart
enum LibraryMediaType { all, movie, series, video, photo }
```

`IncludeItemTypes` 由 `LibraryContentProfile + LibraryMediaType` 解析。

示例：

| Profile | 全部范围 |
|---|---|
| movies | `Movie` |
| tvShows | `Series`（目录或详情流程按现有语义取得季/集） |
| homeVideosAndPhotos | `Movie,Video,Photo`，按真实服务器响应兼容 |
| photos | `Photo` |
| mixed/unknown | `Movie,Series,Video,Photo`，不得默认包含任意未知类型 |

真实 Emby 服务器可能返回 `Episode` 或其他明确媒体类型；兼容必须通过测试和显式映射增加，不得用“任何未知非文件夹都可播放”的猜测。

### 5.3 筛选能力归一化

- `photo` 不允许 STRM/普通媒体或播放状态筛选。
- 当用户选择图片时，媒体来源和播放状态自动归一化为全部。
- 在“全部”混合结果中选择 STRM/普通媒体或播放状态时，仅保留适用的可播放视频条目，图片不得被误分类为普通媒体。
- 纯图片库只有一个有效类型时隐藏整个筛选面板或无效分组。
- 收藏范围可与图片类型组合，但播放状态仍只适用于可播放视频。

所有规则必须进入纯 reducer/normalizer，Widget 不得分散修正状态。

---

## 6. 统一根媒体库与查询层

### 6.1 根入口

首页不再仅通过：

```text
isPhotoLibrary ? PhotoLibraryScreen : LibraryBrowseScreen
```

分裂根路径。

所有媒体库首先解析 `LibraryContentProfile`，然后进入统一根浏览容器：

```dart
LibraryBrowseScreen.root(
  profile: resolvedProfile,
  ...
)
```

纯图片库可以复用现有图片网格组件，但必须共享统一的根状态、错误处理、位置统计和全局导航。

### 6.2 明确 API

保留或新增职责明确的方法：

```dart
getLibraryMediaItems(...)
getDirectoryChildren(...)
getPhotoItems(...)
getLibraryGenres(...)
getLibraryTags(...)
```

禁止再次用一个隐含 `itemType.recursive` 的通用方法决定所有浏览模式。

### 6.3 递归媒体查询

根据 profile 和 media type 生成精确的 `IncludeItemTypes`，支持：

```text
media
favorites
facet
played/unplayed
alphabet
sort
```

收藏与播放条件必须正确合并为服务端 Filters。

### 6.4 混合目录查询

家庭视频和照片目录允许明确类型：

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

请求使用：

```text
Recursive=false
```

目录请求不得携带不兼容的播放、收藏、字母或本地来源筛选。

### 6.5 空状态与错误状态

页面必须区分：

```text
正在加载
确实为空
查询失败
媒体库类型暂不兼容
服务器返回项目但全部解析失败
图片缩略图加载失败
```

不得只呈现无说明空白。UI 只显示固定安全文案，原始异常进入现有脱敏诊断日志。

---

## 7. 类型驱动导航与混合卡片

所有入口使用一个纯 resolver：

```dart
resolveLibraryEntryAction(profile, scope, item)
```

固定规则：

```text
Folder / CollectionFolder / PhotoAlbum
→ 打开下一级目录

Photo
→ 打开全屏图片查看器

Movie / Series / Episode / Video
→ 打开对应详情或现有播放流程

Genre / Tag 索引项
→ 打开对应 facet 结果
```

不得根据“当前页面是不是图片页面”推断点击行为。

新增或完善：

```text
lib/ui/widgets/library_directory_entry_card.dart
lib/ui/widgets/library_photo_card.dart
lib/ui/widgets/library_mixed_entry_card.dart
```

显示要求：

- 文件夹显示目录图标和“目录”。
- 相册显示相册图标。
- 图片显示图片图标，不显示播放状态。
- 视频显示播放图标、时长或年份。
- 电影、剧集、单集保留准确类型语义。
- 混合“全部”结果使用统一 4:3 卡片或经过验证的等价方案，不能让所有项目看起来像文件夹。
- 图片专用结果使用正方形或自适应缩略图网格；全屏查看必须完整显示。

返回详情或图片查看器后：

- 保持原浏览状态。
- 保持原滚动位置。
- 只刷新必要的 UserData 或受影响项目。
- 不无条件重载整个目录。

---

## 8. 图片查看序列与 iPadOS 图片浏览

现有查看器手势、沉浸式 UI、相邻预取和缓存能力原则上保留。本轮重点是统一序列来源和混合库路由。

### 8.1 序列来源

新增：

```dart
sealed class PhotoSequenceSource {}

class DirectoryPhotoSource extends PhotoSequenceSource {}
class FilteredLibraryPhotoSource extends PhotoSequenceSource {}
```

查看器不得只硬编码 `parentId + getPhotoChildren`。建议接收：

```dart
Future<EmbyItemPage> Function(int startIndex, int limit) loadPage;
String queryFingerprint;
```

### 8.2 目录图片

从目录点击图片时：

- 使用 `Recursive=false`。
- 左右切换同一目录内的图片。
- 文件夹、相册和视频不进入图片 PageView 序列。

### 8.3 筛选图片

从“媒体类型=图片”或混合媒体筛选结果点击图片时：

- 使用当前媒体库、收藏/facet、排序等状态生成递归图片查询。
- 左右切换当前图片结果序列。
- 继承分页和 query fingerprint。
- 视频不混入图片手势翻页。

### 8.4 真机行为

必须验证：

```text
缩略图显示
点击进入正确首图
左右切图
双击缩放
双指缩放
放大后平移
接近末尾自动加载下一页
加载失败局部重试
退出后系统 UI 恢复
返回后网格位置保持
```

---

## 9. STRM/普通媒体全库扫描服务

新增：

```text
lib/library/library_local_media_scan_service.dart
lib/library/library_local_media_scan_cache.dart
```

服务生命周期属于当前登录 Session/AppController，不属于列表 Widget。

### 9.1 本地媒体分类

新增显式分类：

```dart
enum LibraryLocalMediaKind { strm, regular, unknown }
```

分类依据：

- Item `Path` 的 `.strm`。
- Item `Container` 的 STRM 语义。
- `MediaSources` 中的 path/container。

扫描查询必须请求完成分类所需的最小字段，例如：

```text
Path
Container
MediaSources
```

不得把缺少分类字段的条目静默当成普通媒体。无法判断时进入 `unknown`，扫描完成状态必须报告未知数量；只有未知数量为 0 时，STRM/普通媒体总数才可声明完全精确。

### 9.2 扫描键

```dart
class LibraryScanKey {
  final String serverScopeHash;
  final String userScopeHash;
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

`localFilter` 不进入扫描键，因为一轮扫描同时产生 STRM、普通媒体和未知分类。

### 9.3 扫描快照

```dart
class LibraryLocalScanSnapshot {
  final LibraryScanStatus status;
  final int rawCursor;
  final int scannedRawCount;
  final int? sourceTotalCount;
  final List<EmbyItem> strmItems;
  final List<EmbyItem> regularItems;
  final int unknownCount;
  final bool complete;
  final LibraryScanErrorKind? safeError;
}
```

### 9.4 自动扫描

选择 STRM 或普通媒体后：

1. 立即订阅或创建对应 scan session。
2. 自动请求所有后续分页。
3. 不等待用户滚动。
4. 每页完成后发布快照，列表边扫描边追加。
5. 使用 raw item count 推进 cursor，显示层按 ID 去重。
6. 空 raw page 强制结束，避免无限循环。
7. 旧 generation/旧 scan key 不得污染新结果。

默认串行请求；只有通过测试证明服务器和内存边界安全时才允许小型有界并发，禁止无界并发。

### 9.5 跨页面继续与生命周期

- 进入详情、设置、搜索或图片查看器后继续扫描。
- 列表重新创建后订阅现有快照，不重启扫描。
- App 进入后台时记录 cursor；恢复前台后继续。
- logout、服务器切换、账号切换必须取消并清空对应缓存。
- 实时媒体库新增/删除/更新使相关 scan key 失效或标记需要刷新。

### 9.6 运行期缓存

- 仅本次登录会话有效。
- STRM 与普通媒体共享。
- 相同 scan key 恢复已有进度和结果。
- 手动刷新使当前 key 失效并重新扫描。
- 使用 LRU 限制同时保留的 scan session 和总项目数。
- 不得截断当前活跃扫描结果；内存达到上限时先淘汰最久未使用的已完成 session。

### 9.7 错误与重试

短暂网络错误：

- 保留已有结果。
- 有限次数退避重试。
- 不把失败误标为完成。

超过重试上限：

```text
扫描已暂停
[继续扫描]
```

继续扫描必须从 raw cursor 恢复，不得清空并从 0 开始。

---

## 10. 统一统计与位置浮层

扩展或重构：

```text
lib/library/library_result_statistics.dart
lib/ui/widgets/library_position_overlay.dart
lib/library/library_scroll_position_controller.dart
```

建议统一模型：

```dart
class LibraryResultStatistics {
  final int visibleLoadedCount;
  final int rawScannedCount;
  final int? exactResultTotal;
  final int? sourceTotal;
  final bool scanComplete;
  final int unknownClassificationCount;
  final String contextLabel;
}
```

页面顶部总数、扫描进度、侧边浮层、分页和播放全部必须使用同一个统计对象，禁止多处各自推算。

### 10.1 显示规则

普通媒体结果：

```text
85–102
共 3,768 项
还剩 3,666 项
2%
```

未播放：

```text
未播放 85–102
共 326 项
还剩 224 项
31%
```

收藏电影：

```text
收藏电影 85–102
共 180 项
还剩 78 项
57%
```

目录：

```text
85–102
目录共 300 项
还剩 198 项
34%
```

图片：

```text
85–102
图片共 240 项
还剩 138 项
43%
```

STRM 扫描未完成：

```text
85–102
STRM 统计中
已扫描 1,200 / 3,768
```

此时不得显示最终总数、剩余数或百分比。

STRM 扫描完成且 unknown=0：

```text
85–102
STRM 共 116 项
还剩 14 项
88%
```

如果存在无法分类项目，UI 必须明确显示“有 N 项无法判断”，不得把普通媒体总数声明为完全精确。

### 10.2 计算规则

```dart
remaining = max(0, exactResultTotal - lastVisible);
percentage = exactResultTotal <= 0
    ? null
    : lastVisible / exactResultTotal;
```

所有序号基于当前筛选后的结果顺序。

一屏内全部可见且没有真实滚动时，侧边浮层可以不出现，但顶部准确总数必须保留。

筛选、排序、浏览范围、列数、旋转或 scan key 改变时立即清除旧 snapshot，旧统计不得短暂显示在新结果中。

---

## 11. 内容优先的媒体库 UI

### 11.1 页面结构

最终 iPad 横屏结构：

```text
[返回] [主页] 当前媒体库名称            [搜索] [账号] [设置]

媒体   目录   分类   标签   收藏

共 N 项  [播放] [随机播放] [排序] [筛选摘要] [更多]

[仅扫描期间出现的细进度条]

五列媒体网格
```

要求：

- 不显示“浏览方式”文字标题。
- 不显示永久媒体类型栏。
- 不显示永久媒体来源栏。
- 只有一个筛选按钮。
- 第一排媒体在 1024×768 首屏可见。
- 排序与网格之间无大块空白。
- Chip、按钮和网格在文字缩放 2.0 时无 overflow。

### 11.2 筛选面板

- iPad 横屏：右侧面板或约 400 逻辑像素宽的可访问对话框。
- 手机：底部弹层。
- 包含草稿、重置、取消和“查看结果”。
- 只显示 profile 支持且有选择价值的组。
- Apply 后只提交一次查询/扫描。
- 按钮摘要示例：

```text
筛选
筛选 · STRM
筛选 · 视频 · STRM · 未播放
筛选 3
```

### 11.3 操作语义

纯视频结果：

```text
播放 / 随机播放
```

纯图片结果：隐藏播放和随机播放，本轮不新增幻灯片。

家庭视频和照片“全部”结果：

```text
播放视频 / 随机视频
```

只作用于可播放条目，图片不得传入播放器。

扫描未完成时，播放全部和随机播放默认禁用并提示“统计完成后可用”，禁止只播放已发现的部分结果而不提示。

更多菜单仅放：

```text
刷新
重置浏览状态
清理当前运行期扫描缓存
```

---

## 12. iPad 横屏氛围详情页

主要修改：

```text
lib/ui/item_detail_screen.dart
必要的 detail layout 子组件
```

### 12.1 布局模式

使用可测试的能力函数选择：

```text
PlatformCapabilities = iPad
width > height
shortestSide >= 600
```

满足时启用大屏双栏。不得按具体 iPad 型号或固定物理像素判断。

### 12.2 氛围背景

优先级：

```text
Backdrop
Primary fallback
纯色渐变 fallback
```

处理：

- 服务器请求适合视口的有界尺寸。
- `cover` 作为氛围层。
- 使用 `ImageFiltered` 或等价有界模糊，避免昂贵的全屏实时 BackdropFilter。
- 叠加暗色遮罩、左右渐变和底部渐变。
- 背景允许裁切，不承担完整内容展示职责。

### 12.3 前景海报

- Primary 使用 `contain`。
- 完整显示主体。
- 没有 Primary 时使用明确占位；不得把横向 Backdrop 强行裁成竖版海报。

### 12.4 双栏信息

左侧：

```text
完整海报
必要的次要信息或演员入口
```

右侧：

```text
标题
年份 / 时长 / 分级 / 评分
预计结束时间（仅在 runtime 可计算时）
分辨率 / 视频编码 / 音频格式（仅显示服务器真实字段）
播放 / 下载 / 已播放 / 收藏 / 更多
发布日期
演员
```

下方：

```text
标签
简介
其他信息
```

不制造服务器未返回的技术信息。

### 12.5 响应式回归

- iPad 竖屏：纵向布局，但可复用氛围背景和信息优先级。
- Android 手机：继续纵向布局。
- 长标题、无演员、多人演员、无图片和文字缩放 2.0 均可滚动，无 RenderFlex overflow。

---

## 13. 结构化诊断

新增固定事件：

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

继续使用现有安全诊断和完整调试日志导出；不得降低任何脱敏门禁。

---

## 14. 实施阶段与提交建议

### Phase 0：冻结计划与基线

记录：

```text
branch
HEAD
upstream
status
受保护文件 blob/SHA
当前全量测试数
```

计划提交：

```text
docs: freeze iPad library STRM and mixed photo remediation
```

### Phase 1：内容能力与状态模型

修改/新增：

```text
library_content_profile.dart
library_browse_state.dart
emby_models.dart
对应单元测试
```

完成 profile、图片类型、动态过滤能力和原子筛选草稿。

提交建议：

```text
refactor: model mixed video and photo libraries
```

### Phase 2：统一查询与类型驱动导航

修改：

```text
emby_api.dart
home_screen.dart
library_entry_action.dart
library_screen.dart
混合卡片组件
```

完成混合库查询、统一根入口、目录/图片/视频准确路由和可诊断空状态。

提交建议：

```text
refactor: unify mixed library queries and routing
```

### Phase 3：图片序列与查看器接入

修改：

```text
photo_viewer_controller.dart
photo_viewer_screen.dart
photo_library_screen.dart 或复用组件
```

完成目录图片序列、筛选图片序列、分页和返回位置恢复。

提交建议：

```text
fix: support photos inside mixed Emby libraries
```

### Phase 4：页面外 STRM 扫描服务

新增扫描服务、运行期缓存和 session 生命周期接入。

提交建议：

```text
feat: scan local media sources independently of scrolling
```

### Phase 5：统一统计和位置

完成所有列表当前结果空间、扫描中状态、剩余数量和 unknown 分类语义。

提交建议：

```text
fix: calculate position from the active result set
```

### Phase 6：内容优先列表与多条件筛选

完成精简导航、根 tabs、单行操作栏、筛选面板、五列网格和动态卡片。

提交建议：

```text
feat: add content-first iPad library layout
```

### Phase 7：氛围详情页

完成 iPad 横屏双栏、背景、前景海报、观看信息优先和响应式回归。

提交建议：

```text
feat: add ambient iPad media detail layout
```

### Phase 8：跨阶段测试与缺口修复

只补集成缺口，不新增范围外功能。

提交建议：

```text
test: complete library STRM photo and iPad UX matrix
```

不得将全部生产改动压成一个巨大提交。每个生产提交必须附带对应测试并能独立审查。

---

## 15. 自动测试矩阵

### 15.1 Profile 与状态

覆盖：

```text
photos
homevideos
movies
tvshows
mixed
unknown
null collectionType
```

断言：

- 允许媒体类型正确。
- 只剩一个有效类型时隐藏媒体类型组。
- 图片自动清除 STRM/普通媒体和播放状态。
- 收藏 + 视频 + 已播放保持收藏范围。
- 目录清除不兼容筛选。
- 筛选草稿一次 Apply 只产生一次状态提交。
- 点击已选条件不重复请求。

### 15.2 API 查询

精确覆盖：

```text
纯图片库
家庭视频和照片全部
家庭视频和照片视频
家庭视频和照片图片
混合目录
收藏 + 图片
收藏 + 视频 + 未播放
分类/标签 + 图片
STRM 扫描基线查询字段
```

断言 `Recursive`、`IncludeItemTypes`、`Fields`、`Filters`、排序和分页游标准确。

### 15.3 混合目录导航

同一页返回：

```text
Folder
CollectionFolder
PhotoAlbum
Photo
Movie
Series
Episode
Video
```

逐项断言正确页面；非文件夹不得创建目录页；返回后状态和滚动位置保持。

### 15.4 图片查看器

覆盖：

- 目录图片 source。
- 筛选图片 source。
- 初始图片索引。
- 左右翻页。
- 放大后锁定 PageView。
- 双击、双指缩放和平移。
- 相邻预取。
- 末尾分页。
- 分页失败重试。
- 返回位置。
- iPad 横竖屏和系统 UI 恢复。

### 15.5 STRM 扫描

至少使用 3,768 个虚构源项目、60 项分页模拟：

- 不滚动也自动扫完。
- 每页发布进度。
- STRM/普通媒体共享同一扫描。
- unknown 分类不被当成 regular。
- 切入详情后继续。
- 页面销毁再创建后恢复订阅。
- 应用生命周期暂停/恢复。
- 手动刷新使旧 key 失效。
- 短暂失败保留进度并重试。
- 超限暂停后从 raw cursor 继续。
- logout/server/user/library 切换清理。
- stale generation 不写回。
- 重复 ID、无效 ID、空 raw page。
- LRU 淘汰已完成旧 session，不截断活跃扫描。

### 15.6 统计与位置

覆盖：

```text
全部媒体
未播放
收藏电影
目录
图片
STRM 扫描中
STRM 完成
普通媒体完成
unknown > 0
一屏内全部可见
旋转后列数改变
筛选切换清除旧 snapshot
```

### 15.7 列表 UI

尺寸：

```text
1024×768
768×1024
1366×1024
390×844
文字缩放 1.0 / 1.3 / 2.0
```

验证：

- iPad 横屏五列。
- 第一排媒体首屏可见。
- 只有一个筛选入口。
- 不存在永久媒体类型/来源栏。
- 操作栏集中。
- 筛选面板动态隐藏无效组。
- 无大块空白和 overflow。
- Android 手机布局不回归。

### 15.8 详情页

覆盖：

```text
Backdrop
Primary fallback
无图片
长标题
多人演员
无演员
技术字段齐全/缺失
1024×768 双栏
768×1024 纵向
390×844 手机纵向
文字缩放 2.0
```

验证氛围背景、前景海报完整、主要操作可达、演员和简介可滚动。

### 15.9 既有回归

必须继续通过：

```text
登录与 Keychain 事务
iPad 键盘矩阵
播放退出方向恢复
下载安全降级
安全诊断导出
完整调试日志导出
Android UDP 发现
Android 普通及分 ABI APK
Swift XCTest
```

---

## 16. 本地验证门禁

每个生产阶段至少执行：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
```

涉及脚本时：

```bash
for file in scripts/ios/*.sh; do
  bash -n "$file"
done
shellcheck scripts/ios/*.sh
```

最终还必须执行：

```bash
flutter build apk --debug
flutter build apk --debug --split-per-abi
```

并在 Actions 中实际运行 Swift XCTest。

要求：

- 全量测试数不得少于实施前基线。
- 不得删除、skip 或弱化已有测试。
- 受保护文件相对本计划代码基线必须零差异。
- `main` 和 `origin/main` 不得变化。
- 工作区最终只允许保留用户的 `?? docs/test/`。

---

## 17. Actions 与 Gate B A/B

代码 HEAD 改变后，旧 Run 55/56 仅保留为历史证据，不再作为本轮最终 Gate B 构建。

完成全部代码与测试后：

1. 记录最终 `implementation_code_head`。
2. 推送最终 HEAD，等待自动 Run A 完整结束。
3. Run A 必须两个 Job 成功，五类 Artifact 完整，checksum 成功。
4. Run A 完成前不得触发 Run B，避免 concurrency 取消。
5. 不再产生任何提交，对同一 HEAD 执行一次 `workflow_dispatch` 生成 Run B。
6. Run B 必须两个 Job 成功、五类 Artifact 完整，且 `CFBundleVersion > Run A`。
7. A/B 必须验证：

```text
head_sha 完全相同
IPA basename checksum 成功
Bundle ID = com.jsdfhasuh.embyclient
MinimumOSVersion = 13.0
UIDeviceFamily = [2]
所有 Mach-O = arm64
无 .appex
Runner entitlement 精确三个批准键
所有 embedded entitlement 为空
embedded 先签，Runner 最后签
两个锁文件无漂移
```

完成后状态改回：

```text
STOP_GATE_B = WAITING_FOR_DEVICE_OWNER
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

然后停止，不得进入阶段 8 或代填真机结果。

---

## 18. 真机 Gate B 验收

### 18.1 Run A 全新安装

设备所有者备份必要数据后卸载旧自研应用，全新安装 Run A，验证：

1. 家庭视频和照片媒体库不再空白。
2. 混合库可显示视频、图片、文件夹和相册。
3. 图片点击进入正确全屏查看器。
4. 视频点击进入正确详情/播放流程。
5. 图片左右切换、缩放和平移正常。
6. 筛选面板对该库显示有效的“全部/视频/图片”。
7. 选择图片后隐藏或清除 STRM 和播放状态。
8. 选择 STRM 后无需滚动即可自动完成全库扫描。
9. 进入详情或设置后扫描继续，返回后进度保持。
10. 扫描完成后侧边浮层使用 STRM 总数并显示准确剩余项。
11. iPad 横屏列表为五列且内容首屏可见。
12. iPad 横屏详情为氛围双栏，前景海报完整。
13. 播放退出后方向恢复。
14. 登录、Keychain、Session 恢复与退出清理正常。
15. 安全诊断和完整调试日志导出不泄露敏感信息。

### 18.2 Run B 覆盖安装

不退出登录、不清数据，用 Run B 覆盖 Run A，验证：

```text
Session 连续性
Keychain 读取
设置保留
媒体库和混合图片功能
STRM 扫描
详情布局
播放方向
诊断导出
```

验收结果只能由设备所有者填写 `PASS / FAIL / NOT_TESTED`。

只有硬门禁全部通过后，才允许：

```text
STOP_GATE_B = PASSED
```

之后另行授权阶段 8、最终证据文档和合并流程。

---

## 19. 最终一次性汇报格式

完成实现、验证和新 A/B 后，一次性汇报：

1. 最终分支和 `implementation_code_head`。
2. 相对计划提交的全部新提交 SHA、信息和修改文件。
3. `LibraryContentProfile` 映射和未知 profile 行为。
4. 家庭视频和照片查询及类型驱动导航。
5. 图片目录 source 与筛选 source。
6. STRM/普通媒体扫描服务生命周期、cache key、失效和重试。
7. 统一统计与每种位置浮层示例。
8. 列表页最终结构、筛选面板和五列规则。
9. iPad 横屏详情氛围双栏规则。
10. 新增及修改测试清单、专项数量和全量测试数。
11. format、analyze、test、diff-check、bash-n、ShellCheck、Android 构建结果。
12. Run A/B URL、run number、相同 HEAD 和 build number。
13. 两次五类 Artifact。
14. 两个 IPA 文件名、SHA-256 和 checksum。
15. Bundle、架构、entitlement、签名顺序和锁文件证据。
16. 仍需设备所有者执行的真机项目。
17. 明确写出：

```text
未进入阶段 8
未修改或合并 main
未提交 docs/test/
未代填真机 PASS
未实现 UDP 发现
未实现投屏协议
未声明 IMPLEMENTATION_COMPLETE
未声明 ACCEPTED
```

完成全部任务前不要只汇报“已完成”，也不得要求设备所有者提前合并。
