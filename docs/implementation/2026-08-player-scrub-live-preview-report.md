# 播放器横滑预览实现报告

日期：2026-08-17
实现分支：`agent/player-scrub-live-preview`
实现基线：`69128cf3c8100a51741c187d28cbb622e008ccb0`
计划提交：`550d550c1ea5e554481decac503d8c767d702907`

## 阶段结论

- Phase 0 / Gate A：**C**。
- Gate B：通过。设置、映射、边界和既有播放器相关定向测试通过。
- Gate C：通过代码与 Widget/纯 Dart 自动化验证。横滑期间不调用主播放器 seek；正常结束沿用 `SeekSource.horizontalDrag` 单次提交路径；取消使会话失效且不提交 seek。
- Phase 3 及之后的客户端解码 Provider：不实施。Gate A=C 时按计划停止客户端抽帧正式接入。

## Phase 0 证据

Probe 使用锁定版本 `media_kit 1.2.6`、`media_kit_video 2.0.1`、`media_kit_libs_video 1.0.7` 的公开 `Player.screenshot()` API，独立创建预览播放器和不可见视频输出，不创建 `PlaybackController`、Emby 播放会话或 reporter。

Android API 37 x86_64 模拟器上，本地 MP4 和 Progressive HTTP MP4 的 JPEG/BGRA 截图结果为空或超时。当前主机没有 Android 真机，Windows 环境没有 Xcode、iPhone 或 iPad，因此不能据此启用客户端抽帧。详细记录见 `2026-08-player-scrub-live-preview-phase0-report.md`。

## Gate C 实现

- `PlaybackSettings` 新增 `horizontalSwipeSeekSpanSeconds` 和 `SeekPreviewMode`，允许值为 `30/60/120/300/600`，默认 `120`；JSON、`copyWith`、Patch 和账户级存储均做白名单规范化。
- `HorizontalScrubSession` 和纯映射函数统一处理线性换算、无效 viewport、左右边界和末尾 `duration - 1ms` 取样。
- 横滑预览卡片位于只读 `PlaybackTimeline` 上方，按目标时间比例定位并限制左右越界；卡片显示目标时间、总时长和前进/后退偏移。
- 有效 Trickplay 时优先使用服务器雪碧图；没有 Trickplay、模式为 `off` 或图片加载失败时显示中性时间卡片，不显示破损图片图标。
- 预览层复用现有缓存轨道，三个 Slider 回调均为 `null`，不会在拖动过程中 seek。

## 未启用能力

客户端解码抽帧没有支持的传输类型：`SUPPORTED_TRANSPORTS=none`。离线、本地 Progressive HTTP、带认证 Header 的 DirectPlay、HLS/segmentedHttp、转码和直播均不启用客户端抽帧；它们按 Trickplay 或时间预览降级。直播仍不执行抽帧。

## 自动化验证

定向覆盖：

- `test/media_kit_frame_probe_test.dart`
- `test/playback_settings_test.dart`
- `test/playback_settings_repository_test.dart`
- `test/horizontal_scrub_mapping_test.dart`
- `test/horizontal_seek_preview_overlay_test.dart`
- `test/playback_timeline_test.dart`
- `test/emby_models_test.dart`
- `test/emby_api_playback_test.dart`

最终验证：`flutter test` 全量通过，共 934 个测试；`flutter analyze` 通过；`dart format --set-exit-if-changed .` 通过；`git diff --check` 通过；`flutter build apk --debug` 通过。

`flutter build ios --debug --no-codesign` 未执行成功：当前 Windows 版 Flutter 不提供 `ios` build 子命令/对应选项，不能替代 macOS Xcode 构建。

## 真机缺口

Android 真机、iPhone 真机和 iPad 真机矩阵均为 `NOT_TESTED`。100 次随机抽帧、100 次快速目标、20 次进出页面、网络断开、PiP、后台恢复、下一集切换、HEVC 和资源释放的真机证据均为 `NOT_TESTED`，留给 Draft PR 的设备验收。
