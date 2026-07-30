# 投屏设计计划

更新日期：2026-07-30

## 1. 用户场景

- 用户发现同一网络中的可投屏设备并选择目标。
- 将当前媒体和位置交接到目标设备。
- 在手机上播放、暂停、跳转、停止并查看目标状态。
- 断线重连后恢复同一个远端会话，或明确回到本机播放。
- 支持 Emby 远程会话，随后评估 Google Cast、DLNA 和 AirPlay。

## 2. 首版范围和非目标

推荐首版只实现 Emby 已登录会话间的 Play To，因为其身份、能力和远程命令可由
Emby 服务器管理。

后续提供：

- Google Cast 原生 Sender SDK。
- DLNA/UPnP AVTransport。
- Android 上经过可行性验证的 AirPlay 控制。

非目标：

- 不把所有协议伪装成相同能力。
- 不在局域网广播中泄露 Emby Token。
- 不自行实现 Google Cast 加密传输栈。
- 不承诺 Android 上 AirPlay 与 Apple 平台能力等价。
- 不将手机本地解码画面录屏后转发。

## 3. Provider 架构

```text
lib/cast/cast_target.dart
lib/cast/cast_session.dart
lib/cast/cast_provider.dart
lib/cast/cast_service.dart
lib/cast/emby_remote_provider.dart
lib/cast/google_cast_provider.dart
lib/cast/dlna_provider.dart
lib/cast/airplay_provider.dart
lib/cast/cast_transport_controller.dart
lib/ui/cast/cast_target_sheet.dart
lib/ui/cast/cast_mini_controller.dart
```

接口应表达能力差异：

```text
CastProvider
  discover()
  connect(target)
  load(media, position)
  play/pause/seek/stop
  disconnect()
  capabilities
  sessionStream
```

- `CastService` 是当前目标和当前会话的唯一所有者。
- Provider 负责协议和原生桥接，不直接操作页面。
- `CastTransportController` 根据 capability 决定可用命令。
- 本地 `PlaybackController` 负责交接前停止和接管后的本机恢复。

## 4. 目标和会话模型

- `CastTarget`：稳定 ID、名称、Provider 类型、地址摘要和能力。
- `CastCapabilities`：播放、暂停、seek、音量、轨道、队列、状态回传。
- `CastMediaDescriptor`：Scope、Item ID、MediaSource ID、媒体类型和位置。
- `CastSessionState`：discovering、connecting、loading、playing、paused、failed、
  disconnected。

目标 ID 必须带 Provider 命名空间。IP 地址变化不应制造重复设备，无法获取稳定 ID
时才使用规范化端点作为后备。

## 5. 协议和安全

Emby 远程会话：

- 使用服务器返回的 Sessions 和可控能力。
- 所有命令携带明确目标 Session ID。
- 处理目标消失、用户权限不足和 Item 不可访问。
- 不让远程命令误控制本地播放会话。

Google Cast：

- 使用官方 Android Cast Sender SDK 和 Flutter 原生桥接或维护良好的插件。
- Receiver 类型、应用 ID 和媒体认证方式先做技术验证。
- 只有 Receiver 能安全访问媒体时才加载，不把长期 Token 写入日志或持久化状态。

DLNA：

- 使用 SSDP 发现和设备描述，媒体控制仅暴露目标声明支持的命令。
- 需要评估 Android MulticastLock、局域网限制和明文 HTTP 风险。
- DLNA 目标无法发送认证头时，必须由 Emby 提供可安全访问的 URL；不得静默暴露
  长期 Token。

AirPlay：

- Android 没有等价的官方 Sender SDK。先做协议、许可证和设备兼容性验证。
- 验证未通过时 Provider 保持不可用，UI 不显示占位入口。

## 6. Android 平台工作

- Google Cast 需要 Gradle 依赖、OptionsProvider、应用清单元数据和生命周期桥接。
- DLNA 可能需要 `CHANGE_WIFI_MULTICAST_STATE` 和 MulticastLock；只有实际实现时添加。
- Android 13+ 局域网权限行为需按目标 SDK 和设备实测。
- 原生回调必须转换为可取消的 Dart 状态流，Activity 重建后可重新绑定。
- 后台通知和系统媒体会话作为第二阶段，避免首版同时扩大原生范围。

## 7. 播放交接

本机到远端：

1. 保存本机 Item、媒体源、轨道、位置和播放状态。
2. 连接目标并确认 load 成功。
3. 远端开始后再停止本机会话。
4. Emby 上报归属按协议确定，不重复上报两个播放端。

远端到本机：

1. 获取可信的远端位置。
2. 停止或断开远端会话。
3. 使用现有 resolver 在本机重新协商。
4. ready 后恢复位置。

交接失败时保留原播放端，不能出现两端都停止且无法恢复的状态。

## 8. 测试与验收

自动测试：

- 多 Provider 目标去重、能力映射和状态转换。
- 连接超时、load 失败、目标消失和重复回调。
- 本机到远端及远端到本机的停止/开始顺序。
- 不支持 seek/音量/轨道时对应命令不可发送。
- URL、Token、设备端点和异常日志脱敏。
- Activity 重建和网络切换后的会话恢复。

真实设备验收按 Provider 单独记录：

- Emby 另一个客户端会话。
- Google Cast 设备或 Android TV Cast Receiver。
- 至少两种 DLNA 设备。
- AirPlay 仅在技术验证通过后进入矩阵。
- 退出、断网、锁屏、来电和应用被系统回收。

## 9. 发布步骤

1. Provider 接口和模拟 Provider。
2. Emby Remote Session。
3. Google Cast 技术验证和最小加载。
4. Google Cast 会话恢复与控制。
5. DLNA 发现和受限播放。
6. AirPlay 可行性结论，未通过则明确不实现。

每个 Provider 使用独立功能开关和验收记录。

## 10. GPL 边界

借鉴 Moonfin 的 Provider、Target、Session 和 Transport Controls 分层，不复制其
Dart Provider、Android/iOS 原生通道或 Receiver Profile 实现。
