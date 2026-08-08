# 媒体库浏览状态最终整改计划

## 0. 文档元数据与权威性

- 文档状态：`FROZEN_FOR_IMPLEMENTATION`
- 计划日期：2026-08-08
- 仓库：`jsdfhasuh/emby_my_client`
- 实施分支：`agent/ios-core-real-device-remediation`
- 实施基线：`49d5681376eea46a19eac543aec32de5091fc92d`
- 上位计划：`docs/plans/2026-08-05-ios-core-real-device-remediation-plan.md`
- 当前 `STOP_GATE_B`：`BLOCKED_BY_IMPLEMENTATION`
- 当前实现状态：`IMPLEMENTATION_IN_PROGRESS`
- 当前真机验收状态：`NOT_ACCEPTED`
- 当前 `evidence_doc_head`：`NOT_CREATED`

本文件取代上位计划第 8.11 节原有的窄幅媒体库补丁方案，是媒体库浏览状态、查询、分页、导航、统计、混合目录卡片和详情 Hero 回归的唯一权威实施依据。上位计划中的登录、Keychain、诊断、签名、打包、Gate B 和阶段 8 约束继续有效。

Run 51/52 只保留为历史候选。两次构建不能作为本计划完成后的最终 Gate B 构建。

## 1. 整改目标

本轮必须以单一、规范化、可测试的状态机替换媒体库页面现有的 `_section`、`LibraryBrowseOptions`、本地 `_filter` 和 `_sort` 并行状态，彻底消除状态重叠，而不是继续增加条件分支。

完成后必须满足：

1. 浏览范围、媒体类型、播放状态、本地媒体类型、排序、字母筛选和 facet 只有一个权威状态；
2. 媒体、目录、分类、标签、收藏和 facet 使用明确且互不混淆的 API 查询；
3. 分页游标按服务端原始项目数推进，显示层按有效 ID 去重；
4. 目录中的 folder 与媒体项目按真实类型导航；
5. 收藏范围在媒体类型、播放状态和本地媒体类型变化后保持收藏语义；
6. 媒体、目录、分类和标签网格都提供语义正确的位置统计；
7. 本地 STRM/普通媒体扫描在结束前不虚构总数、剩余数或百分比；
8. 目录横向卡片不严重裁切竖版 Primary 图片；
9. 详情 Hero 在规定 viewport、文字缩放和图片组合下保持完整前景、无 overflow，并可滚动到简介和演员；
10. 所有本轮新增或修改的错误 UI 只显示固定文案，原异常仅写入现有脱敏 `DiagnosticLog`。

## 2. 单一状态机

新增 `lib/library/library_browse_state.dart`，定义：

```text
LibraryBrowseScope
  media
  directory
  genres
  tags
  favorites
  facet

LibraryMediaType
  all
  movie
  series
  video

LibraryLocalMediaFilter
  all
  strm
  regular

LibraryBrowseState
  scope
  mediaType
  playedFilter
  localFilter
  sortBy
  sortOrder
  alphabetFilter
  facet
```

`LibraryPlayedFilter`、`LibrarySortBy` 和 `LibrarySortOrder` 归入同一媒体库状态模块。facet 使用强类型 `LibraryFacetKind`（genre/tag）和只包含 `id`、`name`、`kind` 的不可变值对象。

新增 sealed 状态事件和纯 reducer。页面上的任何浏览范围、媒体类型、播放状态、本地媒体类型、排序、字母筛选或重置操作都必须 dispatch event；`LibraryBrowseScreen` 不得直接维护第二套等价字段。

最终生产路径必须删除：

```text
LibraryItemType.folder
LibraryBrowseOptions.favoriteOnly
LibraryBrowseOptions
LibraryBrowseMode
normalizeLibraryBrowseOptions
_LibrarySection
_LibraryMediaFilter
_sort
```

若实施过程中需要短暂兼容，只允许在单个提交内部的边界转换，最终代码和提交不得继续保留双重状态。

### 2.1 规范化规则

- media、favorites、facet 允许 mediaType、playedFilter、localFilter、sortBy、sortOrder 和 alphabetFilter；
- alphabetFilter 仅在名称升序时有效，其他排序必须规范化为 all alphabet；
- directory 固定 mediaType=all，清除 playedFilter、localFilter、alphabetFilter 和 facet；目录允许明确的 sortBy/sortOrder；
- genres/tags 固定 mediaType/playedFilter/localFilter/alphabetFilter 为 all，固定名称升序并清除 facet；
- scope=facet 时 facet 必须存在；facet 缺失的非法状态规范化为 media 默认；
- 非 facet scope 必须清除 facet；
- media 与 favorites 互相切换时保留所有兼容筛选；
- 从 directory、genres 或 tags 进入 media 时使用 media 明确默认；进入 favorites 时使用 favorites 明确默认；
- 点击已选单选项必须返回原状态，不触发新请求；
- root reset 固定回到 media/all/all/all/name ascending/all alphabet；
- root 之外不提供会改变页面身份的 reset；facet 只允许逐项清除媒体筛选。

必须用笛卡尔积测试覆盖所有 scope、mediaType、playedFilter、localFilter、sort、alphabet 和 facet 组合，证明 normalize 后不存在非法组合，并验证 reducer 的幂等性和相等性。

## 3. 显式查询模型

`EmbyApi` 新增并由媒体库页面唯一使用：

```text
getLibraryMediaItems
getDirectoryChildren
getLibraryGenres
getLibraryTags
```

这些方法使用明确 named parameters，不接收整个 `LibraryBrowseState`，也不接收旧通用 options。scope 到 API 的映射只在页面请求边界发生一次。

### 3.1 媒体、收藏和 facet

固定请求规则：

- `Recursive=true`；
- `IncludeItemTypes` 只能由 LibraryMediaType 生成：
  - all=`Movie,Series,Video`
  - movie=`Movie`
  - series=`Series`
  - video=`Video`
- favorites 使用 `Filters=IsFavorite`；
- played 使用 `IsPlayed` 或 `IsUnplayed`；
- favorite 与 played 必须合并成一个逗号分隔的 `Filters` 值；
- 不得另外发送 `IsFavorite` 参数；
- 允许 sortBy、sortOrder、alphabetFilter；
- facet 恰好允许 genreId 或 tagId 之一，不得同时发送；
- 媒体列表必须包含当前 STRM 判断所需字段，不扩大到详情播放 payload。

### 3.2 目录

固定请求规则：

- `Recursive=false`；
- `IncludeItemTypes=Folder,CollectionFolder,Movie,Series,Episode,Video`；
- 允许明确的 sortBy、sortOrder；
- 不得包含 `IsFavorite`、`IsPlayed`、`IsUnplayed`、`Filters`、`NameStartsWith`、`NameLessThan`、genreId 或 tagId。

浏览模式不得再由 item type 的 recursive 属性推断。

### 3.3 分类和标签索引

- 继续调用 `/Genres` 和 `/Tags`；
- 固定当前媒体库 parentId、名称升序、`Recursive=true` 和批准的媒体类型；
- 不携带媒体筛选、收藏筛选或 alphabet 参数。

### 3.4 原始数量

四种分页解析都必须在过滤非 Map、空 ID 或其他无效显示项目之前记录：

```text
rawItemCount = rawItems.length
```

`EmbyItemPage.items` 可以只包含有效解析项目，但不得用有效项目数替代 raw cursor。

## 4. 分页和并发

`LibraryBrowseScreen` 使用：

```text
_nextStartIndex
_seenItemIds
_generation
```

每次请求使用 `_nextStartIndex`。成功且 generation 仍有效后：

1. `_nextStartIndex += page.rawItemCount`；
2. 按响应顺序处理有效 items；
3. 仅当 `_seenItemIds.add(item.id)` 成功时允许进入显示结果；
4. 本地筛选启用时，仅将匹配项加入显示列表，但所有首次有效 ID 都进入 seen 集合；
5. page.rawItemCount=0 时 `_hasMore=false`；
6. total 非空时 `_hasMore = _nextStartIndex < total`；
7. total 为空时 `_hasMore = page.rawItemCount == pageSize`。

成功页之后出现的重复或无效项目不能导致游标倒退、重复请求或重复显示。total 后续缺失时保留此前已知 total；新的非空 total 可以更新。

筛选、排序、scope、parent directory 或 facet 变化时必须同步执行：

```text
generation++
nextStartIndex=0
seenIds.clear()
items.clear()
total=null
error=null
position snapshot clear
```

旧 generation 请求完成后不得修改 items、cursor、total、loading、error 或位置状态。

### 4.1 本地 STRM/普通媒体扫描

- 切换 localFilter 视为完整查询变化，从 raw cursor 0 开始；
- 扫描未结束时结果总数未知；
- 显示已匹配数量、已扫描 raw 数量，以及可用时的源 total；
- 首批无匹配时继续扫描，直到有匹配、扫描完成或失败；
- 扫描失败保留已有匹配和 cursor；
- retry 使用失败请求的相同 cursor，不重新从零开始；
- 全部 raw 页面扫描完成后，精确匹配总数等于有效、去重、匹配的显示项目数。

## 5. 页面身份与类型驱动导航

页面只允许三个显式构造器：

```text
LibraryBrowseScreen.root(...)
LibraryBrowseScreen.directory(...)
LibraryBrowseScreen.facet(...)
```

root：

- 显示一次顶层浏览方式栏；
- 在当前媒体库根 parentId 间切换 media/directory/genres/tags/favorites；
- AppBar 使用媒体库名称。

nested directory：

- 隐藏顶层浏览方式栏；
- 只调用 getDirectoryChildren 浏览当前目录；
- AppBar 使用当前目录名称；
- back 返回父路由；
- 不允许切换收藏、分类或标签。

facet：

- 隐藏顶层浏览方式栏；
- AppBar 使用 facet 名称；
- 使用标准媒体类型、播放状态、本地媒体类型、排序和 alphabet；
- 请求固定携带对应 genreId 或 tagId。

新增纯 resolver：

```text
resolveLibraryEntryAction(scope, item)
```

固定规则：

- directory + item.isFolder -> openDirectory；
- directory + 非 folder -> openDetail；
- media/favorites/facet + item.isFolder -> openDirectory；
- media/favorites/facet + 非 folder -> openDetail；
- genres/tags -> openFacet。

目录中的 Movie、Series、Episode 和 Video 绝不能构造 directory 页面。

从详情返回后只调用 UserData 批量接口刷新该 item。收藏范围中取消收藏的项目可以依据新 UserData 从当前结果移除并校正结果数；不得重载整个目录或改变滚动位置。从子目录或 facet 返回依赖现有路由状态和 realtime 机制，不主动全量刷新父列表。

## 6. 混合目录卡片

新增 `lib/ui/widgets/library_directory_entry_card.dart`。卡片按真实类型显示：

| 类型 | 图标 | 副标题 |
| --- | --- | --- |
| Folder/CollectionFolder | folder | 目录 |
| Movie | movie | 年份；缺失时为“电影” |
| Series | tv | 未播放集数；否则年份或“剧集” |
| Episode | play | SxxExx；缺失编号时为“单集” |
| Video | videocam | 年份或“视频” |

点击语义必须区分“打开目录”和“查看媒体”。

横向卡片图片规则：

- 使用同一批准图片作为暗化 `BoxFit.cover` 底层；
- 使用 `BoxFit.contain` 前景；
- 竖版 Primary 不得被严重裁切；
- 无图片时显示类型图标占位；
- 固定 aspect ratio 和文本行数，避免加载、图标或大文字改变卡片尺寸。

genres/tags 使用独立 facet card，不复用目录 entry card。

## 7. 收藏和最终筛选 UI

浏览方式只出现一次：

```text
媒体 / 目录 / 分类 / 标签 / 收藏
```

媒体类型只出现一次：

```text
全部 / 电影 / 剧集 / 视频
```

现有 `LibraryCategorySettings` 继续决定电影、剧集、视频快捷类型是否可见；逻辑状态和 API 仍支持全部四种类型。

高级筛选只包含：

```text
全部 / 未播放 / 已播放
```

本地 STRM/普通媒体筛选、排序、播放全部、随机播放、刷新和 root reset 各保留一个入口。排序只保留一套 sortBy 菜单和一个方向按钮；删除重复 sort preset 状态。

彻底删除重复的文件夹入口、收藏入口、项目类型筛选和 favoriteOnly。

favorites 中选择 all/movie/series/video 时：

- scope 保持 favorites；
- 请求继续包含 IsFavorite；
- playedFilter 可以与 IsFavorite 合并；
- localFilter 可以继续扫描收藏结果；
- 点击已选 mediaType 不产生状态变化或请求；
- 不得切回 media。

所有 `ChoiceChip`/`FilterChip` 的 `onSelected` 必须检查传入 bool，仅 `selected == true` 才 dispatch 单选事件。

## 8. 通用位置统计

新增：

```text
LibraryResultStatistics
LibraryPositionPresentation
```

`LibraryScrollPositionController` 只负责根据实际网格 geometry 计算可见范围；语义文案由 statistics 和 presentation 生成。建立：

```text
mediaGridGeometry
directoryGridGeometry
facetGridGeometry
```

媒体、目录、分类和标签 grid 的 `SliverLayoutBuilder` 都必须将实际 geometry 传给 controller。

查询变化必须立即 clear 旧 snapshot，不能等新请求完成。

显示总数使用：

```text
effectiveTotal = max(totalCount, loadedCount)
```

以避免服务端 total 暂时小于已加载有效项目数时出现负剩余、超过 100% 或范围大于总数。

固定呈现规则：

- 普通媒体：`25–48` / `共 N 项` / 百分比；
- 未播放：`未播放 25–48` / `共 N 项` / `还剩 N 项` / 百分比；
- 已播放：`已播放 25–48` / `共 N 项` / `筛选结果还剩 N 项`；
- 媒体类型筛选：带“电影/剧集/视频”的范围、总数和“筛选结果还剩”；
- 收藏：按 mediaType 显示“收藏/收藏电影/收藏剧集/收藏视频”，并显示总数和“筛选结果还剩”；
- directory：`25–48` / `目录共 N 项` / 百分比，不显示未播放或剩余未看；
- genres：`25–48` / `分类共 N 项` / 百分比；
- tags：`25–48` / `标签共 N 项` / 百分比；
- facet 按标准媒体筛选语义显示，不重复 AppBar 的 facet 名称；
- 本地扫描未完成：`已匹配 N 项` / `已扫描 N 项` 或 `已扫描 N/total 项` / `继续统计中`；
- 本地扫描中断：保留上述数量并显示固定“统计中断，可重试”，不显示虚构总数、剩余或百分比；
- 本地扫描完成：以精确匹配总数生成范围、总数、“筛选结果还剩”和百分比。

total 和结果总数均未知时只能显示可见范围和已加载/扫描事实。

## 9. 详情 Hero 回归

保留：

- `detailHeroHeightForViewport` 响应式高度；
- 暗化 cover 底层；
- Backdrop `BoxFit.contain` 前景；
- 无 Backdrop 时 Primary `BoxFit.contain` 前景；
- 无图标占位。

完整测试矩阵：

```text
1024x768
768x1024
1366x1024
390x844

text scale 1.0
text scale 1.3
text scale 2.0

Backdrop
Primary fallback
无图片
```

每个组合必须验证：

- 前景使用 contain，不裁切主体；
- Hero 尺寸稳定；
- 页面无 RenderFlex 或其他 overflow；
- 标题、元数据和操作区在窄视口/大文字下合理换行或重排；
- 使用真实滚动手势可以到达简介和演员；
- 不得使用 `tester.ensureVisible` 掩盖布局或滚动问题。

390x844 只作为 Flutter 响应式/Android 回归 viewport，不代表新增 iPhone 支持。

## 10. 错误安全

- 媒体库根加载、浏览初始加载、分页、本地扫描、详情返回 UserData 刷新，以及本轮覆盖的详情加载/操作错误都只显示固定用户文案；
- 不得把 `error.toString()`、stack、URL、路径、媒体标题或请求详情放入 SnackBar、错误页或计数文案；
- catch 必须捕获 error 和 stackTrace，并调用现有 `DiagnosticLog.error` 写入完整异常；
- 依赖现有 `DiagnosticLog.redact` 脱敏，不建立新的任意字符串导出通道；
- 记录失败不得改变 retry cursor、页面身份或播放/下载状态。

不得提交设备所有者原始截图、媒体标题、图片、服务器信息、账号、Token、设备 ID 或其他私人媒体库数据。

## 11. 自动测试最低矩阵

必须增加并保持：

1. 状态机所有 scope 的规范化笛卡尔积；
2. reducer 所有事件、无效 facet 和点击已选项幂等；
3. media/favorites/directory/genres/tags/facet 精确 query map；
4. favorite + played 单一 Filters；
5. 四种 API 的 rawItemCount；
6. raw cursor、已知/未知 total、空 raw 页；
7. duplicate、非 Map、空 ID 和无效 item；
8. stale generation 不回写；
9. 本地扫描失败保留匹配并从正确 cursor retry；
10. Folder/CollectionFolder/Movie/Series/Episode/Video resolver 和真实导航；
11. mixed directory card 图标、副标题、语义和图片 fit；
12. 收藏媒体类型、played、local 组合继续保持收藏；
13. 点击已选 scope/media type/played/local chip 不请求；
14. nested directory 和 facet 隐藏顶层浏览栏；
15. 返回详情只刷新 item UserData 并保留滚动位置；
16. media/directory/facet 三种网格位置；
17. 未播放剩余、已播放/收藏筛选结果剩余；
18. effectiveTotal=max(total,loaded)；
19. STRM 扫描中、完成和中断；
20. 查询变化同步清空位置 snapshot；
21. 详情 Hero 完整矩阵；
22. Android target 回归；
23. 横屏、竖屏、紧凑高度、大文字和无 overflow。

不得删除、skip、弱化或用 `ensureVisible` 绕过现有测试。每个生产代码提交必须同时包含与该行为直接对应的测试。

## 12. 提交结构

建议并允许按依赖关系细化为：

```text
docs: freeze final library browse remediation
refactor: introduce normalized library browse state
refactor: separate media and directory API queries
refactor: migrate library browse routes to explicit state
fix: route mixed directory entries by item type
fix: preserve favorites across media filters
fix: unify library pagination and result statistics
fix: show position across all library grids
fix: harden library detail layout and errors
test: complete final library browse state matrix
```

不得把所有生产修改压成一个提交。每个提交只允许显式 `git add <paths>`；禁止 `git add -A`。

## 13. 本地验证

最终必须执行：

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
git diff --check
bash -n scripts/ios/*.sh
shellcheck scripts/ios/*.sh
flutter build apk --debug
flutter build apk --debug --split-per-abi
```

Actions 继续执行现有 Swift XCTest。不得为本计划修改 workflow 或原生测试门禁。

必须以实施基线和 Git 状态确认：

```text
pubspec.yaml 不变
pubspec.lock 不变
ios/Podfile.lock 不变
ios/Runner/Info.plist 不变
所有 entitlement 不变
main 不变
docs/test/ 仍未跟踪且未提交
```

## 14. 最终 Run A / Run B

最终代码和测试 HEAD 推送后：

1. 将该 push 自动生成的工作流作为 Run A；
2. 等待 `Quality and Android` 与 `iPadOS device IPA` 全部成功；
3. 确认 Run A 五类 Artifact 和 checksum 完整；
4. 此后不再提交任何代码；
5. A 完整结束后，对同一分支和同一 HEAD 执行一次 `workflow_dispatch` 生成 Run B；
6. 等待 B 的两个 Job、Swift XCTest、五类 Artifact 和 checksum 全部成功；
7. 确认 B 的 `CFBundleVersion` 高于 A；
8. 核对 A/B 均对应同一代码 HEAD；
9. 分别核对 A/B 的 IPA 文件名、SHA-256 文件 basename 和 `shasum -a 256 -c`；
10. 分别核对 Bundle ID、arm64、最低系统版本、UIDeviceFamily、无 `.appex`、Runner entitlement、embedded entitlement 为空、Runner 最后签名及锁文件；
11. 两个 IPA 因 build number 不同，不要求 SHA-256 相同，但每个 IPA、checksum 和 diagnostics 必须各自一致；
12. 任一代码变更都会废弃已有 A/B，必须从新 HEAD 重新开始。

每个 run 必须生成：

```text
android-debug-apk-<run>
android-debug-split-apks-<run>
ios-core-ipa-<run>
ios-core-dsym-<run>
ios-core-diagnostics-<run>
```

Run A/B 全部核验后，本轮立即停止并汇报，状态变为：

```text
STOP_GATE_B = WAITING_FOR_DEVICE_OWNER
IMPLEMENTATION_IN_PROGRESS
NOT_ACCEPTED
evidence_doc_head = NOT_CREATED
```

## 15. 禁止项

本计划明确禁止：

- 进入阶段 8 或创建证据文档提交；
- 修改、合并或推送 main；
- rebase、force push、`git reset --hard`、`git clean` 或 `git add -A`；
- 读取后提交、修改、暂存、移动、删除或清理用户未跟踪的 `docs/test/`；
- 修改 entitlement、Bundle ID、Info.plist、pubspec.yaml、pubspec.lock、ios/Podfile.lock、依赖或工具链；
- 修改 Keychain、登录诊断、原生安全导出、播放、下载或其他既有业务契约；
- 实现 UDP 自动发现、iOS 画中画、可靠后台下载、iPhone、App Store 或桌面端功能；
- 删除、skip 或弱化既有测试；
- 代填任何真机 PASS；
- 把 Actions、Simulator 或 Artifact 检查写成真实 iPad PASS；
- 声明 `IMPLEMENTATION_COMPLETE` 或 `ACCEPTED`。
