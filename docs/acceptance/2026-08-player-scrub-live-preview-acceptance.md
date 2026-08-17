# 播放器横滑预览验收矩阵

日期：2026-08-17
分支：`agent/player-scrub-live-preview`
Gate A：`C`

## 结果

| 验收项 | Android 真机 | iPhone 真机 | iPad 真机 | 结论 |
| --- | --- | --- | --- | --- |
| 独立客户端抽帧 | `NOT_TESTED` | `NOT_TESTED` | `NOT_TESTED` | Gate A=C，不启用 |
| 有 Trickplay 的远程视频 | `NOT_TESTED` | `NOT_TESTED` | `NOT_TESTED` | 代码路径已覆盖，设备证据缺失 |
| 无 Trickplay 的普通视频 | `NOT_TESTED` | `NOT_TESTED` | `NOT_TESTED` | 时间预览代码路径已覆盖 |
| 带认证 Header 的 DirectPlay | `NOT_TESTED` | `NOT_TESTED` | `NOT_TESTED` | 客户端抽帧未启用 |
| 离线下载视频 | `NOT_TESTED` | `NOT_TESTED` | `NOT_TESTED` | 客户端抽帧未启用 |
| 30/60/120/300/600 秒跨度 | `NOT_TESTED` | `NOT_TESTED` | `NOT_TESTED` | 设置与纯映射测试通过 |
| 拖动取消 | `NOT_TESTED` | `NOT_TESTED` | `NOT_TESTED` | 会话取消单元测试通过 |
| 网络中断、切集、PiP、后台 | `NOT_TESTED` | `NOT_TESTED` | `NOT_TESTED` | 待真机验收 |

## 已验证的非真机证据

- `HorizontalScrubSession`：更新阶段只改变目标，正常结束只返回一次目标，取消后不会再返回结束目标。
- `HorizontalSeekPreviewOverlay`：目标时间/偏移显示、卡片左右边界、预览在进度条上方、只读时间轴和无画面降级。
- 现有 `SeekSource.horizontalDrag` 控制器测试仍通过。
- Phase 0 Android API 37 x86_64 模拟器 Probe：截图为空/超时，结果为 Gate A=C；模拟器不能替代三台真机。

## 设备验收时必须记录

每个平台补充：预览来源、首帧耗时、旧帧串台、主播放音频/画面影响、正常结束 seek 次数、取消 seek 次数、页面退出后的资源释放，以及 HLS/转码/直播的时间降级结果。
