# Player Scrub Preview Remediation Plan

## 基线与范围

- 最新 `origin/main` HEAD：`fc187a410c1f9a63fae33d1ef7baffa994338af8`
- 实施分支：`agent/player-scrub-preview-remediation`
- 工作树：基线确认时干净；本计划提交后开始本轮变更。
- 本轮只整改服务器 Trickplay 横滑预览；不改变横滑跨度映射、`SeekSource.horizontalDrag`、分类导航、主播放器 seek、DirectPlay/DirectStream/Transcode 规则、依赖版本或客户端解码抽帧。

## 已验收不变量

以下能力来自设备所有者的既有验收结论，本轮视为冻结：

- 分类跳转、分类页返回路径和状态保持；
- 横滑距离设置及 30/60/120/300/600 秒跨度映射；
- 横滑结束后跳转；
- 拖动期间不连续 seek；
- 取消横滑不 seek；
- 正常结束只进行一次正式 seek。

## 当前失败事实

设备所有者已明确反馈“横滑时的预览画面”失败。最新 `main` 中没有独立的 `horizontal_seek_preview_overlay.dart`、`horizontal_scrub_mapping.dart` 或 `seek_preview_mode.dart`；实际预览计算和展示内联于 `lib/ui/player_screen.dart`，使用 `NetworkImage` 加认证 Header。当前自动化没有覆盖 Trickplay 真实雪碧图像素、跨雪碧图切换或异步图片竞态。

## 诊断结论与待验证假设

已由代码审计确认：

1. `EmbyTrickplay.resolutionFor` 在找不到当前 `PlaybackPlan.mediaSourceId` 时使用第一个 source 的分辨率，但 URL 仍使用当前计划的 source ID，存在网格参数与图片来源串配。
2. `EmbyTrickplayResolution` 没有解析服务端 `ThumbnailCount`，帧计算只依赖完整网格，可能访问最后一张雪碧图的空单元格。
3. 列表/播放全部/跨季队列项目通常不含 `Trickplay`；切集时没有为当前项目补充详情，因此自动下一集和播放全部无法稳定获得预览元数据。
4. 当前图片展示没有显式的 item/sheet/session generation；Flutter 默认图片更新行为不能作为跨雪碧图和切集竞态的契约。

暂未确认且必须由失败测试区分的假设：当前实现未显式设置 `gaplessPlayback`，且 URL 与坐标在一次同步 build 中产生，因此不能仅凭代码断言一定发生“旧雪碧图 + 新坐标”。本轮测试会直接断言雪碧图身份、裁剪格子和跨 sheet 的原子展示状态。

## 实施设计

- `TrickplaySelection`：精确 source 匹配；无精确匹配时仅允许单 source 兜底；多 source 歧义返回空结果。URL 使用选择结果中的实际 source ID。
- `TrickplayFrameResolver`：纯 Dart 计算 sheet、tile、column、row 和采样位置；使用有效 `ThumbnailCount` 限制最后一页，缺失时保持网格兼容。
- `TrickplayPreviewController`：绑定 item generation、source、resolution、sheet 和 scrub session；同 sheet 只更新格子，跨 sheet 先进入时间降级或保留上一张完整成功帧；所有旧请求在新手势、切集、切源、后台关闭预览、dispose 后失效。
- Trickplay 图片只复用现有认证 Header，不把 Token 放入 URL；失败统一时间降级，不显示 broken image。日志只记录脱敏固定字段。
- 当前项目若缺少 Trickplay，则在播放器会话内按 item ID 最多请求一次详情；详情请求不阻塞主视频，且以 item session/generation 绑定结果。失败只关闭预览。
- 不新增客户端视频解码抽帧；旧设置 JSON 兼容性保持不变。最新基线没有独立预览模式枚举，因此不新增误导性的“自动抽帧”选项。

## Stop Gates

1. 计划门：确认基线、分支、冻结不变量和当前失败事实；不修改 `main`。
2. 复现门：先加入并运行 source 串配、ThumbnailCount 边界、真实雪碧图裁剪和跨 sheet 竞态失败测试。
3. 数据门：source 选择、ThumbnailCount 限制、URL source ID 和队列详情补全测试通过。
4. 展示门：同 sheet 格子切换、跨 sheet 原子替换、旧请求/旧项目/退出后的结果失效测试通过。
5. 回归门：横滑期间不 seek、结束单次 seek、取消不 seek及既有导航测试不回退。
6. 构建门：格式化、分析、定向/全量测试、diff 检查和可用的 Android 构建通过；无法在 Windows 执行的 iOS/真机项目只记录未执行。
7. 真机门：自动化和 CI 不能代填设备验收；最终状态必须保留 `DEVICE_ACCEPTANCE_PENDING`，由设备所有者分别验收 Android 与 iPad。

## 测试矩阵

- 纯 Dart：有效/无效网格、0 点、Interval 边界、同 sheet 首尾、跨 sheet、视频末尾、超大时间、ThumbnailCount 小于理论数量和未填满末页。
- source：精确匹配、唯一 source 兜底、多 source 无匹配失败、URL 使用实际 source ID、不同 source 网格参数不串配。
- 图片：2x2 确定像素裁剪、跨 sheet 旧图不配新坐标、旧请求晚到、第二次手势、切集、退出/dispose、401/403/404/500/非图片/空响应/损坏图片降级。
- 队列：详情页单项、自动下一集、电视剧跨季、分类播放全部、媒体库播放全部；每个项目最多一次详情请求，旧项目不得回填。
- 回归：横滑距离和 seek 次数矩阵、分类返回位置、播放器资源释放。

## 真机责任边界

本分支只能报告实现和自动化结果。服务器是否提供有效 Trickplay、目标时间与画面是否相符、Android/iPad 网络断开恢复、跨雪碧图实际画面以及退出后的设备资源状态，必须由设备所有者验收。未收到反馈前不写 `ACCEPTED`，最终使用 `IMPLEMENTATION_COMPLETE` / `DEVICE_ACCEPTANCE_PENDING`。

## 基线缺口记录

专项说明要求阅读的若干旧分支文件和历史文档在最新 `main` 中不存在；本轮以当前实际代码为准，并不会把旧分支整体合并进来。现存的 `docs/evidence/2026-08-19-media-detail-genre-navigation-delivery.md` 仅用于确认分类导航回归边界，其记录也明确 Windows 跳过真实 media_kit 测试、iOS 未运行。

## 本轮验证记录

- 定向测试：63 passed。
- 全量 `flutter test`：981 passed，3 skipped，exit code 0。
- `flutter analyze`：passed。
- `dart format --output=none --set-exit-if-changed .`：passed，241 files unchanged。
- `git diff --check`：passed。
- 14 个 Android/iOS shell 脚本：Git Bash `bash -n` passed；ShellCheck 使用显式脚本路径并在内存中去除 CRLF 后 passed，源码换行未改动。
- `flutter build apk --debug`：passed，生成 `build/app/outputs/flutter-apk/app-debug.apk`。
- `flutter build apk --debug --split-per-abi`：passed，生成 `app-armeabi-v7a-debug.apk`、`app-arm64-v8a-debug.apk`、`app-x86_64-debug.apk`。
- Windows 未运行 iOS 构建和真机 media_kit 路径；设备所有者仍需分别完成 Android/iPad 预览验收。
