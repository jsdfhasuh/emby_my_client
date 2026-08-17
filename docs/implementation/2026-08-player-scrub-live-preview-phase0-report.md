# 横滑实时预览 Phase 0 报告

日期：2026-08-17
实现分支：`agent/player-scrub-live-preview`
实现基线：`69128cf3c8100a51741c187d28cbb622e008ccb0`
锁定依赖：`media_kit 1.2.6`、`media_kit_video 2.0.1`、`media_kit_libs_video 1.0.7`

## 结论

Gate A：**C**。

当前版本公开提供 `Player.screenshot({format, includeLibassSubtitles})`，但在可用的 Android API 37 x86_64 模拟器上，独立预览播放器对本地 MP4 和网络 MP4 均未取得有效画面。JPEG 编码和 `format: null` 的 BGRA 原始帧都返回空结果。当前环境没有 Android 真机、iPhone 或 iPad，因此没有足够证据在本轮启用客户端抽帧。

后续实现不接入客户端解码 Provider，不引入新的 FFmpeg 依赖，也不升级 media_kit。自动模式固定降级为：Trickplay 优先，Trickplay 不可用时显示时间和进度条。

## API 与隔离验证

- `Player.screenshot` 在当前锁定版本的公开导出中可用。
- `Player` 默认使用 `--vid=no`；Probe 使用独立的 `VideoController` 和不可见的 1×1 `Video` 输出以满足截图 API 的视频输出前提。该输出不挂载到正式播放器页面。
- Probe 使用 `open(play: false)`，设置音量为 0，调用 `AudioTrack.no()` 和 `SubtitleTrack.no()`，seek 到目标时间后只做一次短暂解码脉冲，截图后立即暂停。
- Probe 不创建 `PlaybackController`、Emby 播放会话、reporter 或进度上报器，不调用播放解析器。
- `VideoController.setSize` 在 Android 的当前实现会抛出 `UnsupportedError`，Probe 将其作为平台能力差异处理；正式代码不能假定该方法跨平台可用。
- Probe 的安全结果只包含阶段、稳定错误类型、耗时和字节数，不包含 URI、Header、AccessToken、路径或媒体名称。

## 执行结果

| 平台/场景 | 结果 | 证据 |
| --- | --- | --- |
| Android API 37 模拟器，本地 MP4 | 未取得画面 | 视频输出创建、视频尺寸回报、seek、截图和 dispose 均执行；JPEG 与 BGRA 均为 0 字节 |
| Android API 37 模拟器，Progressive HTTP MP4 | 未取得画面 | 一个样本可读元数据但截图为空；另一个样本在元数据阶段超时 |
| Android 真机 | `NOT_TESTED` | 当前主机无 Android 真机 |
| iPhone 真机 | `NOT_TESTED` | 当前主机为 Windows，无 Xcode 或 iOS 设备 |
| iPad 真机 | `NOT_TESTED` | 当前主机为 Windows，无 Xcode 或 iOS 设备 |
| 带认证 Header 的 DirectPlay | `NOT_TESTED` | 没有可用的安全测试媒体与设备矩阵 |
| HLS、转码、直播 | `NOT_TESTED` / 不启用 | Gate A=C；本轮不执行直播抽帧 |

模拟器运行命令为：

```text
flutter build apk --debug -t tool/media_kit_frame_probe_app.dart
adb install -r -d build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.example.embyclient/com.example.emby_my_client.MainActivity
```

独立 Probe 代码位于 `lib/playback/preview/media_kit_frame_probe.dart`，测试位于 `test/media_kit_frame_probe_test.dart`，临时入口位于 `tool/media_kit_frame_probe_app.dart`。

## 未执行项目

计划要求的三台真机矩阵、100 个随机时间点、100 个快速目标、20 次进出页面、网络断开、下一集切换、PiP、后台恢复和高码率 HEVC 均为 `NOT_TESTED`。不能用模拟器结果替代这些证据。

## Gate A 后续决策

- `SUPPORTED_TRANSPORTS=none`。
- 客户端抽帧在当前播放资源 generation 内不启用。
- Gate C 继续实现账户级横滑跨度、进度条上方 Trickplay、时间降级、单次正常结束 seek 和取消不 seek。
