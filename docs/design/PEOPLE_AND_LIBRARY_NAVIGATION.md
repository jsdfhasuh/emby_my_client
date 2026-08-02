# 人物作品与大型媒体库导航落地计划

更新日期：2026-08-02

状态：里程碑 A、B、C 已实施（自动化测试与构建通过，真实服务器/Android 验收
待执行）

项目基线：`main` 分支提交
`20b1636021463b81c184ccb3e6193d378daa3104`

参考基线：Moonfin-Core `main` 分支提交
`18e344005901511a7f3214651836e143a36e4154`

## 1. 目标

在现有 Android Emby 客户端中增加两个互相独立、可以分别交付的能力：

1. 在电影和电视剧详情页展示演员；点击演员后进入人物详情页，查看该人物在当前
   Emby 服务器中可访问的电影和电视剧。
2. 在包含上百或上千个项目的媒体库中，用户滚动时能够看到当前可见项目范围、
   总数和大致进度；按名称升序浏览时，后续增加 `# / A-Z` 服务端快速导航。

本轮目标是改善本地 Emby 内容的可发现性和大型媒体库的可导航性，不引入外部人物
资料源，也不重构为能够任意跳转到服务端某个绝对索引的虚拟列表。

## 2. 固定决策

以下决策在首版中冻结，实施时不再扩大范围：

- 人物数据只来自当前 Emby 服务器。
- 详情页“演员”区域只展示 `Actor` 和 `GuestStar`。
- 人物作品首版只查询 `Movie` 和 `Series`，不把每一集 `Episode` 混入作品网格。
- 演员条目没有有效 `Id` 时仍可展示姓名和角色，但不可点击。
- 人物作品使用服务端分页，每页默认 60 项。
- 人物作品默认按 `PremiereDate` 降序排列。
- 侧边位置提示显示“首个可见序号—最后可见序号 / 总数”和百分比。
- 用户主动滚动时显示位置提示，停止滚动约 700 毫秒后淡出。
- 首版位置提示不可拖动，不能假装成能够直接跳到第 900 部影片的滚动条。
- `# / A-Z` 是独立的第三个里程碑，只在名称升序排序时启用。
- `A-Z` 使用服务端 `NameStartsWith`；`#` 使用 `NameLessThan=A`。
- 不为演员、电影卡片或全部媒体项目创建逐项 `GlobalKey`。
- 不一次性把整个媒体库加载到手机后再进行本地字母过滤。

## 3. 当前基线与缺口

当前项目已经具备：

- 类型化 `EmbyItem`、电影和电视剧详情页。
- 服务端媒体库分页、排序、筛选和 `TotalRecordCount`。
- 通用媒体卡片、详情页跳转、用户数据和图片认证请求。
- 基于 `ServerScope` 的图片缓存键和认证头。
- `ChangeNotifier` 控制器模式、请求错误状态和自动化测试基础。

当前缺口：

- 详情请求字段没有把 `People` 作为人物功能的稳定输入。
- `EmbyItem` 没有类型化演员模型。
- 电影和电视剧详情页没有演员区域和人物页面路由。
- 没有按 `PersonIds` 查询当前人物作品的 API。
- 现有图片请求主要接收完整 `EmbyItem`，人物列表需要按人物 ID 和图片 Tag 构造
  认证图片请求。
- 媒体库虽然知道总数，但滚动期间没有当前可见范围提示。
- 普通 Flutter `Scrollbar` 只能感知已经加载的分页，不能代表服务端完整总数。
- 现有媒体库请求没有 `NameStartsWith` 和 `NameLessThan` 参数。

## 4. Moonfin 参考结论

Moonfin-Core 中可以借鉴的行为：

- 把人物作为 `Person` 类型项目打开。
- 人物详情加载后，使用 `PersonIds` 查询相关作品。
- 人物作品使用服务端排序和递归查询，而不是扫描客户端已加载内容。
- 媒体库继续采用分页加载。
- 按字母浏览通过服务端 `NameStartsWith` 和 `NameLessThan` 实现。

本项目不直接照搬的部分：

- Moonfin 的人物作品包含 `Episode` 和 `MusicVideo`；本项目首版只展示电影和
  电视剧，避免同一电视剧因大量单集而重复出现。
- Moonfin 人物逻辑还包含 TMDB/Seerr 等外部数据合并；本项目首版只使用 Emby
  本地人物数据。
- Moonfin 的固定 100 项人物作品读取不适合作为本项目分页边界；本项目复用现有
  `EmbyItemPage`，每页 60 项并持续加载。
- 本项目不复制 Moonfin 的代码、测试夹具或工程结构，只参考公开 API 行为、状态
  所有权和失败处理思路。

## 5. 首版范围

首版包含：

- `EmbyPerson` 类型化模型和 `People` 解析。
- 电影、电视剧详情页演员横向列表。
- 演员姓名、角色、头像和缺省占位。
- 点击有效演员进入人物详情页。
- 人物简介、人物头像和作品数量。
- 人物作品“全部、电影、电视剧”筛选。
- 人物作品服务端分页、去重、错误重试和空状态。
- 大型媒体库滚动位置提示。
- 位置提示与分页、排序、筛选、刷新和屏幕方向变化的一致性。
- 名称升序时的 `# / A-Z` 服务端导航，作为第三里程碑交付。
- 自动化测试和真实 Emby/Android 设备验收。

首版非目标：

- 从 TMDB、IMDb、Seerr 或其他外部服务补人物简介、头像或全网作品。
- 人物搜索、人物收藏、人物下载或人物时间线。
- 导演、编剧、制片人等独立人物页面入口。
- 在人物作品页展示每一集电视剧。
- 显示当前服务器没有收录的作品。
- 演员关系、共同出演、热门程度或推荐算法。
- 可拖动到任意百分比并从服务端中间索引双向加载的虚拟媒体库。
- 修改照片库、媒体库根目录、类型/标签/流派分组页面的滚动语义。

## 6. 人物数据模型

新增不可变模型：

```dart
class EmbyPerson {
  const EmbyPerson({
    required this.name,
    required this.type,
    this.id,
    this.role,
    this.primaryImageTag,
  });

  final String? id;
  final String name;
  final String type;
  final String? role;
  final String? primaryImageTag;

  bool get isCast {
    final normalizedType = type.trim().toLowerCase();
    return normalizedType == 'actor' || normalizedType == 'gueststar';
  }
  bool get isNavigable => id != null && id!.isNotEmpty;
}
```

`EmbyItem` 增加：

```dart
final List<EmbyPerson> people;
```

解析规则：

- `Name` 为空的记录丢弃。
- `Id`、`Role`、`PrimaryImageTag` 均允许为空。
- `People` 不是 List、条目不是 Map 或字段类型异常时安全忽略。
- 保留服务器原始顺序。
- 详情页演员列表只筛选 `Actor` 和 `GuestStar`。
- 优先按有效 `Id` 去重；没有 ID 时按标准化后的 `type + name + role` 去重。
- 不把 `People` 加入普通媒体库列表字段，避免上千部影片分页携带大量人物数据。
- 只把 `People` 加入详情请求字段。

## 7. 演员区域

电影、电视剧和单集详情页可以展示演员区域；季页面首版不单独展示演员。

推荐布局：

```text
演员
[头像] [头像] [头像] [头像] ...
姓名   姓名   姓名   姓名
角色   角色   角色   角色
```

交互规则：

- 使用横向惰性 `ListView`，不一次构建全部头像。
- 姓名最多两行，角色最多两行。
- 有头像 Tag 时请求适合卡片尺寸的 Primary 图片。
- 没有头像时显示人物轮廓占位。
- 有有效人物 ID 的卡片显示可点击反馈。
- 没有 ID 的卡片保持展示，但禁用点击和无障碍“按钮”语义。
- 点击后只传人物 ID，不把整份电影详情 Map 传入人物页。
- 返回电影详情后保持原页面滚动位置。
- 演员区域加载失败不应阻止电影详情其余内容显示。

首版不设置人工“前 10 位”硬截断。横向列表惰性构建，服务器返回多少演员就允许
用户横向查看多少；必须先去重，避免同一人物重复出现。

## 8. 人物图片请求

提取或新增底层图片请求方法，避免为了人物头像伪造 `EmbyItem`：

```dart
EmbyImageRequest? imageRequestForTag({
  required String itemId,
  required String type,
  required String? tag,
  required int maxWidth,
  int? maxHeight,
  int quality = 90,
});
```

约束：

- Tag 为空时返回 null，由 UI 使用占位图。
- Token 和授权信息只进入请求头，不进入 URL、日志或缓存键。
- 缓存键继续包含 `ServerScope`、人物 ID、图片类型、Tag 和尺寸档位。
- 演员横向列表只请求可见项附近的图片，不预取全部演员头像。
- 人物详情页可以请求更大的竖版 Primary 图片，但仍使用固定尺寸档位。
- 图片 401/403 继续触发现有会话过期处理。

现有 `imageRequest(EmbyItem)` 可以改为调用这个底层方法，避免出现两套缓存和认证
规则。

## 9. 人物作品 API

新增筛选枚举：

```dart
enum PersonMediaFilter { all, movie, series }
```

新增 API：

```dart
Future<EmbyItemPage> getPersonItems({
  required String personId,
  int startIndex = 0,
  int limit = 60,
  PersonMediaFilter filter = PersonMediaFilter.all,
});
```

请求语义：

```text
GET /Users/{userId}/Items
PersonIds={personId}
IncludeItemTypes=Movie,Series
Recursive=true
SortBy=PremiereDate
SortOrder=Descending
StartIndex={startIndex}
Limit={limit}
Fields=<现有列表字段>
EnableUserData=true
EnableImages=true
EnableTotalRecordCount=true
```

筛选映射：

- `all`：`Movie,Series`
- `movie`：`Movie`
- `series`：`Series`

约束：

- `personId` 必须先做 URI/query 参数编码，不拼接到路径中。
- 返回结果继续解析为 `EmbyItemPage`。
- 按 Item ID 去重。
- 不查询 `Episode`，避免同一电视剧产生大量单集结果。
- 不查询 `Person`、`Season`、`BoxSet` 或 `MusicVideo`。
- 401/403 复用现有会话失效处理。
- 其他错误显示人物作品局部错误，不退出当前登录会话。
- 不在人物页启动全库本地扫描。

人物详情本身复用现有 `getItem(personId)`；若服务器不能返回 Person 详情，页面仍可
使用演员列表已知的姓名和头像作为最小回退，但作品查询必须继续依赖有效人物 ID。

## 10. 人物详情状态所有权

新增独立控制器，不把分页和筛选继续塞进 `ItemDetailScreen`：

```text
lib/people/person_detail_controller.dart
lib/ui/person_detail_screen.dart
```

建议状态：

```dart
class PersonDetailState {
  final EmbyItem? person;
  final List<EmbyItem> items;
  final PersonMediaFilter filter;
  final int? totalRecordCount;
  final bool loadingPerson;
  final bool loadingFirstPage;
  final bool loadingMore;
  final Object? personError;
  final Object? itemsError;
  final bool hasMore;
}
```

控制器职责：

- 加载人物详情和第一页作品。
- 切换全部/电影/电视剧筛选。
- 分页和去重。
- 防止同时发起重复下一页请求。
- 使用递增请求代次忽略旧筛选或旧页面的晚到结果。
- 页面销毁后不再通知监听器。
- 第一页失败和下一页失败分开呈现。
- 重试下一页时不清空已经加载的作品。

人物详情页只订阅状态并发送用户意图，不自行拼接 API 请求。

## 11. 人物详情页面

推荐结构：

```text
← 人物姓名

人物头像    人物姓名
            可选简介

[全部] [电影] [电视剧]          共 N 部

作品海报网格
```

行为：

- 人物详情和作品可以并行加载。
- 简介为空时隐藏简介区域，不显示空白占位。
- 切换筛选后滚动回作品网格顶部。
- 筛选切换期间显示第一页加载状态，旧筛选结果不混入新结果。
- 接近底部时继续请求下一页。
- 点击电影或电视剧复用现有 `ItemDetailScreen`。
- 从作品详情返回后保持人物页当前筛选和滚动位置。
- 作品为空时显示“当前服务器没有收录此人物的电影或电视剧”。
- 下一页失败时保留现有作品并提供局部重试按钮。

## 12. 媒体库位置提示

位置提示只在实际的媒体项目网格中启用。以下页面首版不启用：

- 媒体库根目录卡片。
- 文件夹、类型、流派、标签等分组网格。
- 图片库和图片查看器。
- 搜索结果页。

推荐显示：

```text
┌──────────────┐
│ 421–440      │
│ 共 1,286 部  │
│ 33%          │
└──────────────┘
```

规则：

- 序号为 1 基数。
- 第一行显示当前视口内首个和最后一个可见媒体项目。
- 第二行使用当前筛选结果的 `TotalRecordCount`。
- 百分比使用当前可见范围中点除以总数，四舍五入到整数。
- 总数未知时只显示已知可见范围，不显示错误的百分比。
- 总数不足一屏时默认隐藏位置提示。
- 用户拖动、触摸滚动或惯性滚动时保持显示。
- `ScrollEndNotification` 后启动约 700 毫秒隐藏计时器。
- 新滚动开始时取消隐藏计时器并立即显示。
- 使用淡入淡出，不阻塞网格点击和纵向滚动手势。
- 浮层固定在右侧安全区内，不覆盖系统手势区域。

## 13. 可见范围计算

新增纯逻辑控制器和快照：

```dart
class LibraryPositionSnapshot {
  const LibraryPositionSnapshot({
    required this.firstVisible,
    required this.lastVisible,
    required this.loadedCount,
    this.totalCount,
  });

  final int firstVisible;
  final int lastVisible;
  final int loadedCount;
  final int? totalCount;
}
```

```text
lib/library/library_scroll_position_controller.dart
lib/ui/widgets/library_position_overlay.dart
```

计算原则：

- 网格实际布局和位置计算必须共享同一份列数、卡片宽高比、行间距和纵向
  padding 计算，禁止复制两套略有差异的公式。
- 优先使用网格 Sliver 自身的局部滚动约束，不使用包含顶部工具栏的全局偏移猜测。
- 可以通过 `SliverLayoutBuilder` 获得网格局部 `scrollOffset` 和
  `remainingPaintExtent`，再结合固定网格几何计算首尾可见行。
- 首项：`firstRow * crossAxisCount + 1`。
- 尾项：最后可见行末项，限制在 `loadedCount` 内。
- 最后一行未铺满时必须显示真实最后项序号。
- 屏幕旋转、窗口尺寸变化或列数变化后重新计算。
- 位置快照只在首项、尾项、总数或加载数量变化时通知 UI，不在每个像素变化时
  重建整个页面。
- 不给每张海报创建 `GlobalKey`，不遍历全部 RenderObject。

若实际网格未来允许不等高卡片，则必须改用 Sliver 可见 child 索引报告，不得继续
沿用固定行高公式。首版媒体海报网格保持等高，因此可以使用共享网格几何。

## 14. 与服务端分页的一致性

当前媒体库从索引 0 开始顺序追加分页，因此当前位置可以使用完整结果的绝对序号。

必须满足：

- 已加载 60/1286 项并滚动到底部时，提示应显示接近 `60 / 1286`，不能显示 100%。
- 下一页加入后，当前可见序号不能倒退或跳回 1。
- 分页加载指示器不计入媒体项目序号。
- `TotalRecordCount` 发生变化时更新分母。
- 排序、媒体类型、收藏、观看状态、流派、标签或文件夹变化后：
  - 递增请求代次；
  - 清空旧项目；
  - 重置分页索引；
  - 滚动回顶部；
  - 清空旧位置快照；
  - 等新第一页返回后显示新总数。
- 下拉刷新应保留当前筛选条件，但重建位置状态。
- 下一页失败时保留当前范围和总数，不把错误组件计入项目序号。

## 15. 为什么首版不是可拖动滚动条

普通 Flutter `Scrollbar` 只知道当前已经构建和加载的内容长度。服务端有 1286 部
影片而客户端只加载 60 部时，普通滚动条会错误地把第 60 部当作末尾；加载下一页
后滚动比例又会突变。

真正支持“拖到 70% 直接跳到第 900 部”需要：

- 从任意 `StartIndex` 加载。
- 前后双向分页。
- 未加载区域占位。
- 页缓存和淘汰。
- 绝对索引与过滤结果一致性。
- 跳转失败恢复和快速连续跳转取消。

这属于独立的虚拟媒体库项目，不进入本轮。首版位置提示只负责准确表达位置，不能
提供无法兑现的拖动语义。

## 16. `# / A-Z` 服务端快速导航

该功能作为第三里程碑，在人物页和位置提示稳定后实施。

启用条件：

- 当前为媒体项目网格。
- 排序字段为名称。
- 排序方向为升序。
- 当前不是流派、标签或文件夹分组页面。

新增状态：

```dart
sealed class LibraryAlphabetFilter {
  const LibraryAlphabetFilter();
}

class AllItems extends LibraryAlphabetFilter {}
class SymbolsItems extends LibraryAlphabetFilter {}
class LetterItems extends LibraryAlphabetFilter {
  const LetterItems(this.letter);
  final String letter;
}
```

请求映射：

- 全部：不发送 `NameStartsWith` 或 `NameLessThan`。
- `A-Z`：发送 `NameStartsWith=<大写字母>`。
- `#`：发送 `NameLessThan=A`。

交互：

- 右侧提供收起状态的 `A-Z` 小按钮。
- 点击或按住后展开 `全部、#、A-Z` 字母栏。
- 手指经过字母时显示中央大号字母预览。
- 松开后提交筛选并收起字母栏。
- 顶部显示可关闭筛选标签，例如“首字母：M”。
- 选择字母后清空旧分页、滚动回顶部并请求新结果。
- 快速经过多个字母时使用请求代次，只接受最后一次选择的结果。
- 排序离开名称升序时自动清除字母筛选并隐藏字母栏。

中文、日文或自定义 `SortName` 如何进入 `# / A-Z` 由 Emby 服务端排序名决定。
因此数字位置提示始终保留，字母栏只是增强功能，不能成为唯一导航方式。

## 17. API 与筛选参数扩展

为媒体库请求增加可空参数：

```dart
Future<EmbyItemPage> getLibraryItems({
  // 现有参数
  String? nameStartsWith,
  String? nameLessThan,
});
```

约束：

- 两个参数不能同时发送。
- 字母统一转为单个大写 ASCII 字母。
- 非法字母在调用前拒绝，不把任意文本作为服务端查询参数。
- 字母筛选必须进入请求签名、状态 equality 和请求代次判断。
- 服务端不支持参数或返回兼容错误时，页面显示局部错误，不静默退回本地扫描。
- 不缓存跨不同字母筛选的分页结果到同一列表。

## 18. 推荐文件改动

```text
lib/models/emby_models.dart
  - 增加 EmbyPerson
  - EmbyItem 增加 people
  - 解析 People

lib/data/emby_api.dart
  - 详情字段增加 People
  - 增加 getPersonItems
  - getLibraryItems 支持 NameStartsWith / NameLessThan
  - 提取 imageRequestForTag

lib/people/person_detail_controller.dart
  - 人物详情、筛选、分页和请求代次

lib/library/library_scroll_position_controller.dart
  - 可见范围计算和位置快照

lib/ui/item_detail_screen.dart
  - 接入演员区域和人物路由

lib/ui/person_detail_screen.dart
  - 人物资料和作品网格

lib/ui/widgets/person_widgets.dart
  - PersonAvatar、CastCard、CastRow

lib/ui/widgets/library_position_overlay.dart
  - 位置浮层和后续字母栏入口

lib/ui/library_screen.dart
  - 接入网格局部布局报告、滚动通知和字母筛选
```

不要继续把全部新增状态直接放入已经较大的 `library_screen.dart` 和
`item_detail_screen.dart`。页面负责组合，控制器负责异步状态和计算。

## 19. 自动化测试

### 19.1 人物模型

- 正常解析 Actor、GuestStar、Role、Id 和 PrimaryImageTag。
- `People` 缺失、为空或类型错误。
- 人物 ID、角色或头像 Tag 为空。
- 无名称人物被忽略。
- 按 ID 去重。
- 无 ID 时按标准化字段去重。
- 导演和编剧不进入演员区域。

### 19.2 人物 API

- 详情请求包含 `People` 字段。
- 全部筛选发送 `IncludeItemTypes=Movie,Series`。
- 电影和电视剧筛选分别发送单一类型。
- `PersonIds`、`StartIndex`、`Limit`、排序和总数参数正确。
- 不发送 `Episode`。
- 401/403 触发会话失效。
- 服务器空结果和缺失 `TotalRecordCount`。

### 19.3 人物控制器和 UI

- 点击有 ID 演员进入正确人物页。
- 无 ID 演员不可点击。
- 无头像时显示占位。
- 人物简介为空时不保留空白区域。
- 超过 60 部作品时继续分页。
- 切换筛选后旧请求不能覆盖新结果。
- 下一页失败保留已有作品并允许重试。
- 页面销毁后晚到请求不通知 UI。
- 点击作品进入现有详情页。

### 19.4 位置计算

- 1、2、3、4 列网格的首尾可见范围。
- 顶部、列表中部和底部。
- 最后一行未铺满。
- `loadedCount < totalCount` 时百分比不错误显示 100%。
- 顶部工具栏高度不影响网格局部序号。
- 方向变化和列数变化后重新计算。
- 分页加载指示器和错误组件不计入序号。
- 总数未知时隐藏百分比。
- 不足一屏时默认隐藏。

### 19.5 位置浮层

- 用户滚动时出现。
- 惯性滚动期间保持显示。
- 结束 700 毫秒后淡出。
- 新滚动取消旧隐藏计时器。
- 浮层不拦截海报点击和滚动手势。
- 排序、筛选、刷新后旧位置被清空。

### 19.6 字母导航

- 全部不发送字母参数。
- `M` 发送 `NameStartsWith=M`。
- `#` 发送 `NameLessThan=A`。
- 不同时发送两个参数。
- 非名称升序时字母栏隐藏并清除筛选。
- 快速选择多个字母时只接受最后请求结果。
- 选择字母后分页和位置从头开始。

## 20. 真实服务器与设备验收

至少使用一个包含 1000 个以上电影/电视剧条目的真实媒体库，记录：

- 电影详情演员姓名、角色、头像和点击行为。
- 电视剧和单集人物数据是否符合服务器实际返回。
- 同一人物的电影和电视剧作品是否完整且无 Episode 重复。
- 人物没有本地作品、没有头像、没有简介时的表现。
- 人物拥有超过一页作品时的分页。
- 媒体库从顶部连续滚动到底部时序号是否单调且准确。
- 加载下一页前后位置提示是否连续。
- 不同列数、横竖屏和字体缩放下的位置计算。
- 排序、筛选、刷新后总数和序号是否重置。
- `# / A-Z` 在当前服务器版本中的返回语义。
- 中文和自定义 SortName 项目在字母筛选中的实际归类。
- 位置提示是否影响滑动流畅度、海报点击和系统返回手势。
- 日志、图片 URL 和缓存键中不存在 Token。

## 21. 交付顺序

### 里程碑 A：演员与人物作品

实施状态：代码、自动化测试与分 ABI Debug APK 构建已完成；真实 Emby 服务器和
Android 设备验收待执行。

- 完成数据模型、详情字段和演员横向列表。
- 完成人物详情、作品筛选和分页。
- 完成图片认证、错误状态和自动化测试。
- 通过真实 Emby 人物数据验收。

### 里程碑 B：媒体库位置提示

实施状态：代码、自动化测试与分 ABI Debug APK 构建已完成；1000 项以上真实媒体库
和 Android 设备验收待执行。

- 提取共享网格几何。
- 完成可见范围控制器和浮层。
- 覆盖分页、筛选、方向变化和隐藏计时器测试。
- 在 1000 项以上媒体库真机滚动验收。

### 里程碑 C：`# / A-Z` 快速导航

实施状态：代码、自动化测试与分 ABI Debug APK 构建已完成；真实 Emby 服务器和
Android 设备验收待执行。

- 扩展媒体库 API 和筛选状态。
- 完成字母栏、中央字母预览和筛选标签。
- 完成服务端兼容与快速切换竞态测试。
- 在中文和英文媒体名样本中记录实际行为。

三个里程碑按顺序实施。A 与 B 可以在代码层保持独立，但同一时间只合并一个里程碑，
避免人物分页和媒体库滚动状态同时扩大 `library_screen.dart` 的改动面。

## 22. 完成定义

每个里程碑均需满足：

- 页面只订阅状态和发送用户意图，异步状态有单一所有者。
- 新请求参数、分页、错误和取消路径有自动化测试。
- 不加载整个媒体库，不创建逐项 GlobalKey，不产生滚动时全页高频重建。
- 图片认证继续只通过请求头发送。
- `dart format lib test` 通过。
- `flutter analyze` 通过。
- `flutter test` 全部通过。
- 分 ABI Debug APK 构建通过。
- 真实 Emby 服务器和 Android 设备验收完成并记录。
- 阶段完成后同步 README 和本设计文档状态。

## 23. 许可边界

Moonfin-Core 使用 GPL v2。本功能只参考其公开 Emby API 使用方式、人物作品查询思路、
服务端字母过滤和状态职责划分。所有 Dart 模型、控制器、UI、测试和交互均在本项目中
独立实现，不复制 Moonfin 源文件或测试夹具。

## 24. 里程碑 A 实施记录

2026-08-01 完成：

- 新增类型化 `EmbyPerson`、详情 `People` 字段解析、演员过滤与去重。
- 新增按人物 ID 查询电影/电视剧作品的服务端分页 API，以及按人物 ID/图片 Tag
  构造的认证图片请求。
- 新增独立人物详情控制器，覆盖详情/作品并行加载、筛选、分页、去重、请求代次、
  首屏与下一页错误重试和销毁保护。
- 在电影、电视剧和单集详情接入演员横向惰性列表；无 ID 演员保留展示但不可点击。
- 新增人物资料、作品数量、全部/电影/电视剧筛选、作品网格与详情跳转。
- `dart format lib test`、`flutter analyze`、全量 `flutter test` 通过。
- `flutter build apk --debug --split-per-abi` 通过，生成 armeabi-v7a、arm64-v8a 和
  x86_64 Debug APK。

待验收：

- 当前开发环境未检测到 Android 设备，也未提供可用于验收的真实 Emby 会话；第
  20 节的真实服务器与设备项目尚未执行。

范围确认：

- 未修改 `library_screen.dart`。
- 未增加媒体库位置提示、可见范围计算、`NameStartsWith`、`NameLessThan` 或
  `# / A-Z` 导航状态。

2026-08-01 审查修正：

- 人物页接收类型化 `EmbyPerson` 初始资料；人物详情请求失败时继续显示演员卡片的
  姓名和头像，作品查询与人物资料重试互不阻塞。
- 同 ID 人物记录在首次出现位置合并，演员/客串演员类型优先；演员 Role 只允许从
  演员/客串演员记录补齐，头像 Tag 仍可从同 ID 任意类型记录补齐。
- 从作品详情返回后只刷新该作品的 `UserData`，不重置人物页筛选、分页或滚动位置；
  旧筛选发起的刷新结果不能写入新列表。
- 补充人物回退与重试、第一页作品重试、跨角色去重、作品状态刷新，以及电影、
  电视剧、单集演员区域条件的自动化测试。

2026-08-02 最终审查修正：

- 演员类型判断统一使用 `trim + lowercase`，兼容大小写或首尾空白不规范的
  `Actor` / `GuestStar` 数据。
- 同 ID 合并先确定 preferred/fallback；最终为演员时拒绝使用导演、编剧等非演员
  Role，同时继续允许跨类型补齐 `PrimaryImageTag`。
- `UserData` 刷新请求代次按作品 ID 隔离，不同作品可并发乱序返回；筛选代次继续
  阻止旧列表刷新结果写入新列表。
- 补充 Role 来源约束、小写演员解析/展示/合并，以及不同作品并发刷新测试。

## 25. 里程碑 B 实施记录

2026-08-02 完成：

- 提取共享 `LibraryMediaGridGeometry`，由媒体网格布局和位置计算共同使用列数、
  海报宽高比、横纵间距与 padding。
- 新增独立 `LibraryScrollPositionController` 和不可变位置快照，使用网格 Sliver 的
  局部 `scrollOffset`、`remainingPaintExtent` 与固定等高几何计算可见首尾序号。
- 位置提示显示 1 基数首尾范围、服务端 `TotalRecordCount` 和可见范围中点百分比；
  总数未知时不显示错误的总数或百分比，最后一行按真实加载数量截断。
- 新增右侧安全区内的只读浮层；拖动、触摸和惯性滚动期间显示，
  `ScrollEndNotification` 后约 700 毫秒淡出，并通过 `IgnorePointer` 保持网格手势透传。
- 分页追加保持当前位置连续；排序、服务端筛选、分组切换和刷新清空旧快照并按需
  回到顶部；屏幕尺寸或列数变化后使用新约束重新计算。
- 本地 STRM/普通媒体筛选尚未加载完整分页时把总数视为未知，不为局部结果伪造
  服务端总数或百分比。
- 补充 1 至 4 列、顶部/中部/底部、最后一行、分页、筛选、排序、刷新、横竖屏、
  未知总数、单屏隐藏、通知去重、700 毫秒隐藏和手势透传测试。
- `dart format lib test`、`flutter analyze`、245 项全量 `flutter test` 通过。
- `flutter build apk --debug --split-per-abi` 通过，生成 armeabi-v7a、arm64-v8a 和
  x86_64 Debug APK。

待验收：

- 当前开发环境未提供包含 1000 项以上媒体的真实 Emby 会话或 Android 设备；第
  20 节的连续滚动、性能和系统手势现场验收尚未执行。

范围确认：

- 位置提示只接入实际媒体项目网格，未接入媒体库根目录、分组网格、图片库或搜索页。
- 未创建逐项 `GlobalKey`，未加载完整媒体库，未实现可拖动滚动条。
- 未增加 `NameStartsWith`、`NameLessThan` 或 `# / A-Z` 导航状态。

2026-08-02 审查修正：

- 媒体网格和 `SliverChildBuilderDelegate` 在 `_buildMediaGrid` 的布局回调外创建；
  `SliverLayoutBuilder` 只报告约束并复用同一个网格实例，连续滚动不再替换 delegate
  或重建同一批可见海报卡片。
- 本地媒体筛选完成后的总数直接使用传入网格的 `items.length`；位置布局回调不再读取
  `_displayedItems`，两千项本地数据下每次位置计算保持 O(1)。
- 实时刷新恢复 `jumpTo` 期间抑制位置通知，并在恢复完成后清空位置状态；程序化恢复
  不显示浮层，下一次用户主动滚动才重新显示。
- 补充连续小幅滚动的网格/delegate/卡片复用测试、两千项本地筛选的常量时间布局测试，
  以及实时刷新保留滚动位置且浮层保持隐藏的测试；既有位置、分页、旋转和 700 毫秒
  淡出测试继续覆盖。
- `dart format lib test`、`flutter analyze`、248 项全量 `flutter test` 和
  `git diff --check` 通过；分 ABI Debug APK 构建生成 armeabi-v7a、arm64-v8a 和
  x86_64 三个产物。

## 26. 里程碑 C 实施记录

2026-08-02 完成：

- 新增不可变 `LibraryAlphabetFilter` 状态及 `AllItems`、`SymbolsItems`、
  `LetterItems` 实现；字母统一规范为单个大写 ASCII 字母，并进入
  `LibraryBrowseOptions` equality、hash 和筛选计数。
- `getLibraryItems` 支持互斥的 `NameStartsWith` / `NameLessThan` 参数；普通请求不发送
  字母参数，字母项发送 `NameStartsWith=<A-Z>`，`#` 发送 `NameLessThan=A`，非法值在
  网络请求前拒绝。
- 新增右侧可点击或长按展开的 `全部、#、A-Z` 字母栏；触摸拖动经过字母时显示中央
  预览，松开提交筛选并收起，顶部显示可关闭的“首字母”筛选标签。
- 字母导航只在名称升序的实际媒体项目网格启用；名称降序、其他排序、文件夹项目和
  文件夹/流派/标签分组网格自动隐藏并清除字母筛选。
- 选择或清除字母复用媒体库请求代次和分页重置：清空旧项目、从 `StartIndex=0`
  请求、滚动回顶部并清空旧位置快照；下一页保留相同字母参数，快速选择时只接受
  最后一次请求结果。
- 服务端不支持字母参数时显示当前筛选的局部错误和重试入口，不回退到无筛选请求，
  也不启动客户端全库扫描。
- 补充筛选规范化/equality、API 参数互斥、字母与 `#` 映射、拖动预览、筛选标签、
  分页、排序/分组禁用、紧凑横屏、服务端错误和晚到响应竞态测试。
- `dart format lib test`、`flutter analyze`、258 项全量 `flutter test` 和
  `git diff --check` 通过；`flutter build apk --debug --split-per-abi` 生成
  armeabi-v7a、arm64-v8a 和 x86_64 Debug APK。

待验收：

- 当前开发环境未提供真实 Emby 会话或 Android 设备；第 20 节的服务器参数兼容性、
  中文/自定义 `SortName` 归类、触摸滑动和系统手势现场验收尚未执行。

范围确认：

- 未进行本地全库扫描，未实现可拖拽百分比跳转或任意 `StartIndex` 双向虚拟列表。
- 未在媒体库根目录、分组网格、图片库或搜索页启用字母导航。
- 未改变里程碑 A 的人物语义或里程碑 B 的位置计算、700 毫秒淡出和程序化恢复语义。
